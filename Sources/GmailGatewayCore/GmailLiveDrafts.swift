import Foundation

private let gmailDraftsPath = "/gmail/v1/users/me/drafts"

struct GmailLiveDrafts {
    func listDrafts(
        account: AccountConfig,
        credential: CredentialConfig,
        first: Int,
        after: String?,
        includeEdges: Bool,
        includeNodeDetails: Bool
    ) throws -> MailDraftConnection {
        let accessToken = try validGmailAccessToken(credential: credential, use: .draftRead)
        var components = gmailURLComponents(path: gmailDraftsPath)
        var queryItems = [URLQueryItem(name: "maxResults", value: String(first))]
        if let pageToken = nonBlank(after) {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components.queryItems = queryItems
        let response = try getGmailObject(
            components: components,
            accessToken: accessToken,
            context: "Gmail draft list failed",
            as: GmailDraftListResponse.self
        )
        let listed = response.drafts ?? []
        let pageInfo = MailPageInfo(
            hasNextPage: response.nextPageToken != nil,
            endCursor: response.nextPageToken
        )
        guard includeEdges else {
            return MailDraftConnection(
                edges: [],
                pageInfo: pageInfo,
                totalCount: response.resultSizeEstimate ?? listed.count
            )
        }
        var edges: [MailDraftEdge] = []
        for item in listed {
            guard let draftId = nonBlank(item.id) else {
                continue
            }
            let node: MailDraft?
            if includeNodeDetails {
                node = try getDraft(account: account, accessToken: accessToken, draftId: draftId)
            } else {
                node = nil
            }
            edges.append(MailDraftEdge(cursor: draftId, node: node))
        }
        return MailDraftConnection(
            edges: edges,
            pageInfo: pageInfo,
            totalCount: response.resultSizeEstimate ?? edges.count
        )
    }

    func getDraft(
        account: AccountConfig,
        credential: CredentialConfig,
        draftId: String
    ) throws -> MailDraft {
        let accessToken = try validGmailAccessToken(credential: credential, use: .draftRead)
        return try getDraft(account: account, accessToken: accessToken, draftId: draftId)
    }

    func updateDraft(
        account: AccountConfig,
        credential: CredentialConfig,
        draftId: String,
        input: OutboundMailInput,
        validatedAttachmentPaths: [String],
        rejectedAttachments: [MailRejectedAttachment]
    ) throws -> MailWriteResult {
        let accessToken = try validGmailAccessToken(credential: credential, use: .draftUpdate)
        let rawMessage = try buildRawMessage(
            from: account.emailAddress,
            input: input,
            attachmentPaths: validatedAttachmentPaths
        )
        var draftMessage: [String: Any] = ["raw": rawMessage]
        if let threadId = nonBlank(input.threadId) {
            draftMessage["threadId"] = threadId
        }
        let object = try putGmailJSONObject(
            path: "\(gmailDraftsPath)/\(urlPathEncode(draftId))",
            accessToken: accessToken,
            body: ["id": draftId, "message": draftMessage],
            context: "Gmail draft update failed"
        )
        let message = object["message"] as? [String: Any] ?? [:]
        return MailWriteResult(
            operation: GmailGatewayWriteOperation.updateDraft.rawValue,
            accountId: account.id,
            provider: account.provider.graphQLValue,
            draftId: object["id"] as? String ?? draftId,
            messageId: message["id"] as? String,
            threadId: message["threadId"] as? String,
            status: "DRAFT_UPDATED",
            rejectedAttachments: rejectedAttachments
        )
    }

    func deleteDraft(
        account: AccountConfig,
        credential: CredentialConfig,
        draftId: String
    ) throws -> MailWriteResult {
        let accessToken = try validGmailAccessToken(credential: credential, use: .draftDelete)
        try deleteGmailResource(
            path: "\(gmailDraftsPath)/\(urlPathEncode(draftId))",
            accessToken: accessToken,
            context: "Gmail draft deletion failed"
        )
        return MailWriteResult(
            operation: GmailGatewayWriteOperation.deleteDraft.rawValue,
            accountId: account.id,
            provider: account.provider.graphQLValue,
            draftId: draftId,
            messageId: nil,
            threadId: nil,
            status: "DRAFT_DELETED",
            rejectedAttachments: []
        )
    }

    private func getDraft(
        account: AccountConfig,
        accessToken: String,
        draftId: String
    ) throws -> MailDraft {
        var components = gmailURLComponents(path: "\(gmailDraftsPath)/\(urlPathEncode(draftId))")
        components.queryItems = fullQueryItems()
        let object = try getGmailObject(
            components: components,
            accessToken: accessToken,
            context: "Gmail draft retrieval failed",
            as: GmailAPIDraft.self
        )
        return MailDraft(
            id: object.id ?? draftId,
            accountId: account.id,
            message: object.message.map { buildMailMessage(account: account, object: $0) }
        )
    }
}
