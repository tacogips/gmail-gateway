import Foundation

/// Input for `updateDraft`.
///
/// Header and body fields use retain-on-omit semantics: a field left out keeps the value already
/// stored on the provider draft. Body replacement is all-or-nothing so an update cannot leave a
/// stale alternative part behind: supplying `textBody` and/or `htmlBody` replaces the whole body
/// with exactly what was supplied, and omitting both retains the existing text and HTML parts.
///
/// Attachments are controlled by `keepAttachmentIds`:
/// - omitted: every attachment already on the draft is retained
/// - provided: only the listed provider attachment ids are retained (an empty list drops all)
///
/// `attachmentPaths` adds local files on top of whatever is retained, so
/// `keepAttachmentIds: []` combined with `attachmentPaths` performs a full attachment replacement.
public struct UpdateDraftInput: Sendable {
    public let accountId: String
    public let draftId: String
    public let to: [String]?
    public let cc: [String]?
    public let bcc: [String]?
    public let replyTo: String?
    public let subject: String?
    public let textBody: String?
    public let htmlBody: String?
    public let attachmentPaths: [String]
    public let keepAttachmentIds: [String]?

    public init(
        accountId: String,
        draftId: String,
        to: [String]? = nil,
        cc: [String]? = nil,
        bcc: [String]? = nil,
        replyTo: String? = nil,
        subject: String? = nil,
        textBody: String? = nil,
        htmlBody: String? = nil,
        attachmentPaths: [String] = [],
        keepAttachmentIds: [String]? = nil
    ) {
        self.accountId = accountId
        self.draftId = draftId
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.subject = subject
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.attachmentPaths = attachmentPaths
        self.keepAttachmentIds = keepAttachmentIds
    }

    var replacesBody: Bool {
        textBody != nil || htmlBody != nil
    }
}

extension GmailGatewayWriteService {
    public func listDrafts(
        accountId: String,
        first: Int = 20,
        after: String? = nil,
        includeEdges: Bool = true,
        includeNodeDetails: Bool = true
    ) throws -> [String: Any] {
        let (account, credential) = try requireWritableAccount(accountId: accountId, operation: .readDraft)
        return try providerAdapter.listDrafts(
            account: account,
            credential: credential,
            first: try validateDraftListFirst(first),
            after: try validateDraftListAfter(after),
            includeEdges: includeEdges,
            includeNodeDetails: includeNodeDetails
        ).graphQLObject()
    }

    public func getDraft(accountId: String, draftId: String) throws -> [String: Any] {
        let (account, credential) = try requireWritableAccount(accountId: accountId, operation: .readDraft)
        return try providerAdapter.getDraft(
            account: account,
            credential: credential,
            draftId: try requireDraftId(draftId)
        ).graphQLObject()
    }

    public func updateDraft(input: UpdateDraftInput) throws -> [String: Any] {
        let (account, credential) = try requireWritableAccount(accountId: input.accountId, operation: .updateDraft)
        let draftId = try requireDraftId(input.draftId)
        let existing = try providerAdapter.getDraft(
            account: account,
            credential: credential,
            draftId: draftId
        )
        guard let existingMessage = existing.message else {
            throw GmailGatewayError(
                "Gmail draft \(draftId) did not include a message to update",
                code: .draftNotFound,
                exitCode: .graphqlExecutionError,
                details: ["accountId": account.id, "draftId": draftId]
            )
        }
        // Validate the merged draft before downloading any retained attachment payload so a
        // rejected update never pays for provider attachment transfers.
        let merged = try mergedDraftMailInput(
            input: input,
            existing: existingMessage,
            credential: credential,
            retainedAttachments: []
        )
        try validateOutboundInput(merged, account: account, operation: .updateDraft)
        let outbound = merged.replacingInlineAttachments(try retainedDraftAttachments(
            message: existingMessage,
            keepAttachmentIds: input.keepAttachmentIds,
            credential: credential
        ))
        let attachments = validateOutboundAttachmentPaths(input.attachmentPaths, readerService: readerService)
        return try providerAdapter.updateDraft(
            account: account,
            credential: credential,
            draftId: draftId,
            input: outbound,
            validatedAttachmentPaths: attachments.acceptedPaths,
            rejectedAttachments: attachments.rejectedAttachments
        ).graphQLObject()
    }

    public func deleteDraft(accountId: String, draftId: String) throws -> [String: Any] {
        let (account, credential) = try requireWritableAccount(accountId: accountId, operation: .deleteDraft)
        return try providerAdapter.deleteDraft(
            account: account,
            credential: credential,
            draftId: try requireDraftId(draftId)
        ).graphQLObject()
    }

    private func mergedDraftMailInput(
        input: UpdateDraftInput,
        existing: MailMessage,
        credential: CredentialConfig,
        retainedAttachments: [OutboundInlineAttachment]
    ) throws -> OutboundMailInput {
        let body = try mergedDraftBody(input: input, existing: existing, credential: credential)
        return OutboundMailInput(
            accountId: input.accountId,
            to: input.to ?? existing.to.map(\.raw),
            cc: input.cc ?? existing.cc.map(\.raw),
            bcc: input.bcc ?? existing.bcc.map(\.raw),
            replyTo: input.replyTo ?? existing.replyTo.first?.raw,
            subject: input.subject ?? existing.subject,
            textBody: body.textBody,
            htmlBody: body.htmlBody,
            attachmentPaths: input.attachmentPaths,
            threadId: nonBlank(existing.threadId),
            inReplyTo: existing.inReplyToHeader,
            references: existing.referencesHeader,
            inlineAttachments: retainedAttachments
        )
    }

    private func mergedDraftBody(
        input: UpdateDraftInput,
        existing: MailMessage,
        credential: CredentialConfig
    ) throws -> (textBody: String?, htmlBody: String?) {
        guard !input.replacesBody else {
            return (input.textBody, input.htmlBody)
        }
        let bodyFiles = try providerAdapter.getMessageBodyFiles(
            credential: credential,
            messageId: existing.id
        )
        return (
            draftBodyText(bodyFiles, kind: .bodyText),
            draftBodyText(bodyFiles, kind: .bodyHTML)
        )
    }

    private func retainedDraftAttachments(
        message: MailMessage,
        keepAttachmentIds: [String]?,
        credential: CredentialConfig
    ) throws -> [OutboundInlineAttachment] {
        guard keepAttachmentIds.map({ !$0.isEmpty }) ?? true else {
            return []
        }
        let requestedIds = keepAttachmentIds.map(Set.init)
        var retained: [OutboundInlineAttachment] = []
        var matchedIds: Set<String> = []
        for attachment in message.attachments {
            guard let attachmentId = attachment.providerMetadata?.gmail?.attachmentId else {
                continue
            }
            if let requestedIds {
                guard requestedIds.contains(attachmentId) || requestedIds.contains(attachment.id) else {
                    continue
                }
                matchedIds.insert(attachmentId)
                matchedIds.insert(attachment.id)
            }
            retained.append(OutboundInlineAttachment(
                filename: attachment.filename ?? "attachment",
                mimeType: attachment.mimeType,
                data: try providerAdapter.getAttachmentPayload(
                    credential: credential,
                    messageId: message.id,
                    attachmentId: attachmentId
                )
            ))
        }
        if let requestedIds {
            let unknownIds = requestedIds.subtracting(matchedIds).sorted()
            guard unknownIds.isEmpty else {
                throw GmailGatewayError(
                    "updateDraft keepAttachmentIds referenced attachments that are not on the draft",
                    code: .attachmentNotFound,
                    exitCode: .graphqlExecutionError,
                    details: ["keepAttachmentIds": unknownIds.joined(separator: ", ")]
                )
            }
        }
        return retained
    }
}

private func draftBodyText(_ bodyFiles: [GmailMessageBodyFile], kind: MessageMaterializedFileKind) -> String? {
    guard let file = bodyFiles.first(where: { $0.kind == kind }) else {
        return nil
    }
    return String(data: file.data, encoding: .utf8)
}

private func requireDraftId(_ draftId: String) throws -> String {
    guard let value = nonBlank(draftId) else {
        throw GmailGatewayError(
            "Draft mutations require a non-blank draftId",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    return value
}

private func validateDraftListFirst(_ first: Int) throws -> Int {
    guard (1...500).contains(first) else {
        throw GmailGatewayError(
            "drafts.first must be an integer from 1 through 500",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    return first
}

private func validateDraftListAfter(_ after: String?) throws -> String? {
    guard let after else {
        return nil
    }
    guard let pageToken = nonBlank(after) else {
        throw GmailGatewayError(
            "drafts.after must not be blank",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    return pageToken
}
