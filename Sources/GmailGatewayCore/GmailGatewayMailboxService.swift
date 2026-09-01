import Foundation

/// Fields accepted when creating or updating a label. Nil fields are left untouched by
/// `updateLabel`, which patches rather than replaces.
public struct LabelWriteInput: Sendable {
    public let name: String?
    public let messageListVisibility: String?
    public let labelListVisibility: String?

    public init(
        name: String? = nil,
        messageListVisibility: String? = nil,
        labelListVisibility: String? = nil
    ) {
        self.name = name
        self.messageListVisibility = messageListVisibility
        self.labelListVisibility = labelListVisibility
    }

    var isEmpty: Bool {
        name == nil && messageListVisibility == nil && labelListVisibility == nil
    }

    func providerBody() -> [String: Any] {
        var body: [String: Any] = [:]
        if let name {
            body["name"] = name
        }
        if let messageListVisibility {
            body["messageListVisibility"] = messageListVisibility
        }
        if let labelListVisibility {
            body["labelListVisibility"] = labelListVisibility
        }
        return body
    }
}

/// A resolved ingestion request. The caller names a local RFC 822 file; the service validates
/// that path against the configured attachment roots and reads it before the provider call.
struct MailIngestInput: Sendable {
    let rawMessage: String
    let labelIds: [String]
    let internalDateSource: String?
    let neverMarkSpam: Bool?
    let processForCalendar: Bool?
    let deleted: Bool?

    func queryItems(for operation: GmailGatewayWriteOperation) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let internalDateSource {
            items.append(URLQueryItem(name: "internalDateSource", value: internalDateSource))
        }
        if let deleted {
            items.append(URLQueryItem(name: "deleted", value: deleted ? "true" : "false"))
        }
        // neverMarkSpam and processForCalendar exist only on import.
        guard operation == .importMessage else {
            return items
        }
        if let neverMarkSpam {
            items.append(URLQueryItem(name: "neverMarkSpam", value: neverMarkSpam ? "true" : "false"))
        }
        if let processForCalendar {
            items.append(URLQueryItem(name: "processForCalendar", value: processForCalendar ? "true" : "false"))
        }
        return items
    }
}

/// GraphQL-facing ingestion input. `rfc822Path` must resolve under a configured
/// `storage.allowed_send_attachment_roots` entry, the same rule outbound attachments follow.
public struct MailboxIngestInput: Sendable {
    public let accountId: String
    public let rfc822Path: String
    public let labelIds: [String]
    public let internalDateSource: String?
    public let neverMarkSpam: Bool?
    public let processForCalendar: Bool?
    public let deleted: Bool?

    public init(
        accountId: String,
        rfc822Path: String,
        labelIds: [String] = [],
        internalDateSource: String? = nil,
        neverMarkSpam: Bool? = nil,
        processForCalendar: Bool? = nil,
        deleted: Bool? = nil
    ) {
        self.accountId = accountId
        self.rfc822Path = rfc822Path
        self.labelIds = labelIds
        self.internalDateSource = internalDateSource
        self.neverMarkSpam = neverMarkSpam
        self.processForCalendar = processForCalendar
        self.deleted = deleted
    }
}

/// Label changes, trash/untrash, permanent delete, label management, and mail ingestion.
/// `GmailGatewayWriteService` owns the credential checks; the GraphQL layer decides which
/// binary may reach which of these.
extension GmailGatewayWriteService {
    // MARK: - Label changes on stored mail

    public func modifyThreadLabels(
        accountId: String,
        threadId: String,
        addLabelIds: [String],
        removeLabelIds: [String]
    ) throws -> [String: Any] {
        let (account, credential) = try requireWritableAccount(accountId: accountId, operation: .modifyThreadLabels)
        try requireLabelChange(addLabelIds: addLabelIds, removeLabelIds: removeLabelIds, mutation: "modifyThreadLabels")
        return try providerAdapter.modifyThreadLabels(
            account: account,
            credential: credential,
            threadId: try requireIdentifier(threadId, field: "threadId"),
            addLabelIds: addLabelIds,
            removeLabelIds: removeLabelIds
        ).graphQLObject()
    }

    public func modifyMessageLabels(
        accountId: String,
        messageId: String,
        addLabelIds: [String],
        removeLabelIds: [String]
    ) throws -> [String: Any] {
        let (account, credential) = try requireWritableAccount(accountId: accountId, operation: .modifyMessageLabels)
        try requireLabelChange(addLabelIds: addLabelIds, removeLabelIds: removeLabelIds, mutation: "modifyMessageLabels")
        return try providerAdapter.modifyMessageLabels(
            account: account,
            credential: credential,
            messageId: try requireIdentifier(messageId, field: "messageId"),
            addLabelIds: addLabelIds,
            removeLabelIds: removeLabelIds
        ).graphQLObject()
    }

    public func batchModifyMessageLabels(
        accountId: String,
        messageIds: [String],
        addLabelIds: [String],
        removeLabelIds: [String]
    ) throws -> [String: Any] {
        let (account, credential) = try requireWritableAccount(
            accountId: accountId,
            operation: .batchModifyMessageLabels
        )
        try requireLabelChange(
            addLabelIds: addLabelIds,
            removeLabelIds: removeLabelIds,
            mutation: "batchModifyMessageLabels"
        )
        return try providerAdapter.batchModifyMessageLabels(
            account: account,
            credential: credential,
            messageIds: try requireIdentifiers(messageIds, field: "messageIds"),
            addLabelIds: addLabelIds,
            removeLabelIds: removeLabelIds
        ).graphQLObject()
    }

    // MARK: - Trash and untrash

    public func setThreadTrashed(accountId: String, threadId: String, trashed: Bool) throws -> [String: Any] {
        let (account, credential) = try requireWritableAccount(
            accountId: accountId,
            operation: trashed ? .trashThread : .untrashThread
        )
        return try providerAdapter.setThreadTrashed(
            account: account,
            credential: credential,
            threadId: try requireIdentifier(threadId, field: "threadId"),
            trashed: trashed
        ).graphQLObject()
    }

    public func setMessageTrashed(accountId: String, messageId: String, trashed: Bool) throws -> [String: Any] {
        let (account, credential) = try requireWritableAccount(
            accountId: accountId,
            operation: trashed ? .trashMessage : .untrashMessage
        )
        return try providerAdapter.setMessageTrashed(
            account: account,
            credential: credential,
            messageId: try requireIdentifier(messageId, field: "messageId"),
            trashed: trashed
        ).graphQLObject()
    }

    // MARK: - Permanent delete

    public func deleteThread(accountId: String, threadId: String) throws -> [String: Any] {
        let (account, credential) = try requireWritableAccount(accountId: accountId, operation: .deleteThread)
        return try providerAdapter.deleteThread(
            account: account,
            credential: credential,
            threadId: try requireIdentifier(threadId, field: "threadId")
        ).graphQLObject()
    }

    public func deleteMessage(accountId: String, messageId: String) throws -> [String: Any] {
        let (account, credential) = try requireWritableAccount(accountId: accountId, operation: .deleteMessage)
        return try providerAdapter.deleteMessage(
            account: account,
            credential: credential,
            messageId: try requireIdentifier(messageId, field: "messageId")
        ).graphQLObject()
    }

    public func batchDeleteMessages(accountId: String, messageIds: [String]) throws -> [String: Any] {
        let (account, credential) = try requireWritableAccount(accountId: accountId, operation: .batchDeleteMessages)
        return try providerAdapter.batchDeleteMessages(
            account: account,
            credential: credential,
            messageIds: try requireIdentifiers(messageIds, field: "messageIds")
        ).graphQLObject()
    }

    // MARK: - Label management

    public func createLabel(accountId: String, input: LabelWriteInput) throws -> [String: Any] {
        let (account, credential) = try requireWritableAccount(accountId: accountId, operation: .createLabel)
        guard nonBlank(input.name) != nil else {
            throw GmailGatewayError(
                "createLabel requires a non-blank name",
                code: .invalidArgument,
                exitCode: .graphqlExecutionError
            )
        }
        try validateLabelVisibility(input)
        return try providerAdapter.createLabel(
            account: account,
            credential: credential,
            input: input
        ).graphQLObject()
    }

    public func updateLabel(accountId: String, labelId: String, input: LabelWriteInput) throws -> [String: Any] {
        let (account, credential) = try requireWritableAccount(accountId: accountId, operation: .updateLabel)
        guard !input.isEmpty else {
            throw GmailGatewayError(
                "updateLabel requires at least one of name, messageListVisibility, or labelListVisibility",
                code: .invalidArgument,
                exitCode: .graphqlExecutionError
            )
        }
        try validateLabelVisibility(input)
        return try providerAdapter.updateLabel(
            account: account,
            credential: credential,
            labelId: try requireIdentifier(labelId, field: "labelId"),
            input: input
        ).graphQLObject()
    }

    public func deleteLabel(accountId: String, labelId: String) throws -> [String: Any] {
        let (account, credential) = try requireWritableAccount(accountId: accountId, operation: .deleteLabel)
        return try providerAdapter.deleteLabel(
            account: account,
            credential: credential,
            labelId: try requireIdentifier(labelId, field: "labelId")
        ).graphQLObject()
    }

    // MARK: - Mail ingestion

    public func importMessage(input: MailboxIngestInput) throws -> [String: Any] {
        try ingestMessage(input: input, operation: .importMessage)
    }

    public func insertMessage(input: MailboxIngestInput) throws -> [String: Any] {
        try ingestMessage(input: input, operation: .insertMessage)
    }

    private func ingestMessage(
        input: MailboxIngestInput,
        operation: GmailGatewayWriteOperation
    ) throws -> [String: Any] {
        let (account, credential) = try requireWritableAccount(accountId: input.accountId, operation: operation)
        let resolved = MailIngestInput(
            rawMessage: try readIngestSource(input.rfc822Path, mutation: operation.mutationName),
            labelIds: input.labelIds,
            internalDateSource: try validatedInternalDateSource(input.internalDateSource),
            neverMarkSpam: input.neverMarkSpam,
            processForCalendar: input.processForCalendar,
            deleted: input.deleted
        )
        switch operation {
        case .importMessage:
            return try providerAdapter.importMessage(
                account: account,
                credential: credential,
                input: resolved
            ).graphQLObject()
        default:
            return try providerAdapter.insertMessage(
                account: account,
                credential: credential,
                input: resolved
            ).graphQLObject()
        }
    }

    private func readIngestSource(_ path: String, mutation: String) throws -> String {
        guard let requestedPath = nonBlank(path) else {
            throw GmailGatewayError(
                "\(mutation) requires a non-blank rfc822Path",
                code: .invalidArgument,
                exitCode: .graphqlExecutionError
            )
        }
        let validatedPath = try readerService.validateSendAttachmentPath(requestedPath)
        guard FileManager.default.isReadableFile(atPath: validatedPath) else {
            throw GmailGatewayError(
                "\(mutation) source file is not readable",
                code: .attachmentNotFound,
                exitCode: .graphqlExecutionError,
                details: ["rfc822Path": requestedPath]
            )
        }
        do {
            return base64URLString(try Data(contentsOf: URL(fileURLWithPath: validatedPath)))
        } catch {
            throw GmailGatewayError(
                "\(mutation) could not read the source file",
                code: .fileOperationFailed,
                exitCode: .graphqlExecutionError,
                details: ["rfc822Path": requestedPath, "cause": error.localizedDescription]
            )
        }
    }
}

private let supportedInternalDateSources: Set<String> = ["RECEIVED_TIME", "DATE_HEADER"]

private func validatedInternalDateSource(_ value: String?) throws -> String? {
    guard let value = nonBlank(value) else {
        return nil
    }
    let normalized = value.uppercased()
    guard supportedInternalDateSources.contains(normalized) else {
        throw GmailGatewayError(
            "internalDateSource must be RECEIVED_TIME or DATE_HEADER",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    return normalized
}

private let supportedMessageListVisibility: Set<String> = ["show", "hide"]
private let supportedLabelListVisibility: Set<String> = ["labelShow", "labelShowIfUnread", "labelHide"]

private func validateLabelVisibility(_ input: LabelWriteInput) throws {
    if let value = input.messageListVisibility,
       !supportedMessageListVisibility.contains(value) {
        throw GmailGatewayError(
            "messageListVisibility must be show or hide",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    if let value = input.labelListVisibility,
       !supportedLabelListVisibility.contains(value) {
        throw GmailGatewayError(
            "labelListVisibility must be labelShow, labelShowIfUnread, or labelHide",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
}

private func requireLabelChange(addLabelIds: [String], removeLabelIds: [String], mutation: String) throws {
    guard !addLabelIds.isEmpty || !removeLabelIds.isEmpty else {
        throw GmailGatewayError(
            "\(mutation) requires at least one addLabelIds or removeLabelIds value",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    guard (addLabelIds + removeLabelIds).allSatisfy({ nonBlank($0) != nil }) else {
        throw GmailGatewayError(
            "\(mutation) label ids must not be blank",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
}

private func requireIdentifier(_ value: String, field: String) throws -> String {
    guard let identifier = nonBlank(value) else {
        throw GmailGatewayError(
            "Mailbox mutations require a non-blank \(field)",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    return identifier
}

private func requireIdentifiers(_ values: [String], field: String) throws -> [String] {
    guard !values.isEmpty else {
        throw GmailGatewayError(
            "Mailbox batch mutations require at least one \(field) value",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    return try values.map { try requireIdentifier($0, field: field) }
}
