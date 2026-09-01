import Foundation

private let gmailMessagesPath = "/gmail/v1/users/me/messages"
private let gmailThreadsPath = "/gmail/v1/users/me/threads"
private let gmailLabelsPath = "/gmail/v1/users/me/labels"

/// Mailbox mutation transport: label changes, trash/untrash, permanent delete, and label
/// management. These change stored mail rather than composing or sending it, so they are
/// reachable only through `gmail-gateway-threads`.
struct GmailLiveMailbox {
    // MARK: - Label changes on stored mail

    func modifyThreadLabels(
        account: AccountConfig,
        credential: CredentialConfig,
        threadId: String,
        addLabelIds: [String],
        removeLabelIds: [String]
    ) throws -> MailboxMutationResult {
        let object = try postGmailJSONObject(
            path: "\(gmailThreadsPath)/\(urlPathEncode(threadId))/modify",
            accessToken: try validGmailAccessToken(credential: credential, use: .mailboxModify),
            body: labelChangeBody(addLabelIds: addLabelIds, removeLabelIds: removeLabelIds),
            context: "Gmail thread label modification failed"
        )
        return MailboxMutationResult(
            operation: GmailGatewayWriteOperation.modifyThreadLabels.rawValue,
            accountId: account.id,
            provider: account.provider.graphQLValue,
            status: "LABELS_MODIFIED",
            threadId: object["id"] as? String ?? threadId,
            labelIds: threadLabelIds(from: object)
        )
    }

    func modifyMessageLabels(
        account: AccountConfig,
        credential: CredentialConfig,
        messageId: String,
        addLabelIds: [String],
        removeLabelIds: [String]
    ) throws -> MailboxMutationResult {
        let object = try postGmailJSONObject(
            path: "\(gmailMessagesPath)/\(urlPathEncode(messageId))/modify",
            accessToken: try validGmailAccessToken(credential: credential, use: .mailboxModify),
            body: labelChangeBody(addLabelIds: addLabelIds, removeLabelIds: removeLabelIds),
            context: "Gmail message label modification failed"
        )
        return messageMutationResult(
            operation: .modifyMessageLabels,
            status: "LABELS_MODIFIED",
            account: account,
            fallbackMessageId: messageId,
            object: object
        )
    }

    func batchModifyMessageLabels(
        account: AccountConfig,
        credential: CredentialConfig,
        messageIds: [String],
        addLabelIds: [String],
        removeLabelIds: [String]
    ) throws -> MailboxMutationResult {
        var body = labelChangeBody(addLabelIds: addLabelIds, removeLabelIds: removeLabelIds)
        body["ids"] = messageIds
        try postGmailJSONNoContent(
            path: "\(gmailMessagesPath)/batchModify",
            accessToken: try validGmailAccessToken(credential: credential, use: .mailboxModify),
            body: body,
            context: "Gmail batch label modification failed"
        )
        return MailboxMutationResult(
            operation: GmailGatewayWriteOperation.batchModifyMessageLabels.rawValue,
            accountId: account.id,
            provider: account.provider.graphQLValue,
            status: "LABELS_MODIFIED",
            messageIds: messageIds
        )
    }

    // MARK: - Trash and untrash

    func setThreadTrashed(
        account: AccountConfig,
        credential: CredentialConfig,
        threadId: String,
        trashed: Bool
    ) throws -> MailboxMutationResult {
        let object = try postGmailJSONObject(
            path: "\(gmailThreadsPath)/\(urlPathEncode(threadId))/\(trashed ? "trash" : "untrash")",
            accessToken: try validGmailAccessToken(credential: credential, use: .mailboxModify),
            body: [:],
            context: trashed ? "Gmail thread trash failed" : "Gmail thread untrash failed"
        )
        return MailboxMutationResult(
            operation: (trashed ? GmailGatewayWriteOperation.trashThread : .untrashThread).rawValue,
            accountId: account.id,
            provider: account.provider.graphQLValue,
            status: trashed ? "TRASHED" : "UNTRASHED",
            threadId: object["id"] as? String ?? threadId,
            labelIds: threadLabelIds(from: object)
        )
    }

    func setMessageTrashed(
        account: AccountConfig,
        credential: CredentialConfig,
        messageId: String,
        trashed: Bool
    ) throws -> MailboxMutationResult {
        let object = try postGmailJSONObject(
            path: "\(gmailMessagesPath)/\(urlPathEncode(messageId))/\(trashed ? "trash" : "untrash")",
            accessToken: try validGmailAccessToken(credential: credential, use: .mailboxModify),
            body: [:],
            context: trashed ? "Gmail message trash failed" : "Gmail message untrash failed"
        )
        return messageMutationResult(
            operation: trashed ? .trashMessage : .untrashMessage,
            status: trashed ? "TRASHED" : "UNTRASHED",
            account: account,
            fallbackMessageId: messageId,
            object: object
        )
    }

    // MARK: - Permanent delete

    func deleteThread(
        account: AccountConfig,
        credential: CredentialConfig,
        threadId: String
    ) throws -> MailboxMutationResult {
        try deleteGmailResource(
            path: "\(gmailThreadsPath)/\(urlPathEncode(threadId))",
            accessToken: try validGmailAccessToken(credential: credential, use: .mailboxDelete),
            context: "Gmail thread deletion failed"
        )
        return MailboxMutationResult(
            operation: GmailGatewayWriteOperation.deleteThread.rawValue,
            accountId: account.id,
            provider: account.provider.graphQLValue,
            status: "PERMANENTLY_DELETED",
            threadId: threadId
        )
    }

    func deleteMessage(
        account: AccountConfig,
        credential: CredentialConfig,
        messageId: String
    ) throws -> MailboxMutationResult {
        try deleteGmailResource(
            path: "\(gmailMessagesPath)/\(urlPathEncode(messageId))",
            accessToken: try validGmailAccessToken(credential: credential, use: .mailboxDelete),
            context: "Gmail message deletion failed"
        )
        return MailboxMutationResult(
            operation: GmailGatewayWriteOperation.deleteMessage.rawValue,
            accountId: account.id,
            provider: account.provider.graphQLValue,
            status: "PERMANENTLY_DELETED",
            messageId: messageId
        )
    }

    func batchDeleteMessages(
        account: AccountConfig,
        credential: CredentialConfig,
        messageIds: [String]
    ) throws -> MailboxMutationResult {
        try postGmailJSONNoContent(
            path: "\(gmailMessagesPath)/batchDelete",
            accessToken: try validGmailAccessToken(credential: credential, use: .mailboxDelete),
            body: ["ids": messageIds],
            context: "Gmail batch message deletion failed"
        )
        return MailboxMutationResult(
            operation: GmailGatewayWriteOperation.batchDeleteMessages.rawValue,
            accountId: account.id,
            provider: account.provider.graphQLValue,
            status: "PERMANENTLY_DELETED",
            messageIds: messageIds
        )
    }

    // MARK: - Label management

    func createLabel(
        account: AccountConfig,
        credential: CredentialConfig,
        input: LabelWriteInput
    ) throws -> MailboxMutationResult {
        let object = try postGmailJSONObject(
            path: gmailLabelsPath,
            accessToken: try validGmailAccessToken(credential: credential, use: .mailboxModify),
            body: input.providerBody(),
            context: "Gmail label creation failed"
        )
        return labelMutationResult(operation: .createLabel, status: "LABEL_CREATED", account: account, object: object)
    }

    func updateLabel(
        account: AccountConfig,
        credential: CredentialConfig,
        labelId: String,
        input: LabelWriteInput
    ) throws -> MailboxMutationResult {
        // PATCH rather than PUT so an update that names only one field does not clear the rest.
        let object = try patchGmailJSONObject(
            path: "\(gmailLabelsPath)/\(urlPathEncode(labelId))",
            accessToken: try validGmailAccessToken(credential: credential, use: .mailboxModify),
            body: input.providerBody(),
            context: "Gmail label update failed"
        )
        return labelMutationResult(
            operation: .updateLabel,
            status: "LABEL_UPDATED",
            account: account,
            object: object,
            fallbackLabelId: labelId
        )
    }

    func deleteLabel(
        account: AccountConfig,
        credential: CredentialConfig,
        labelId: String
    ) throws -> MailboxMutationResult {
        try deleteGmailResource(
            path: "\(gmailLabelsPath)/\(urlPathEncode(labelId))",
            accessToken: try validGmailAccessToken(credential: credential, use: .mailboxModify),
            context: "Gmail label deletion failed"
        )
        return MailboxMutationResult(
            operation: GmailGatewayWriteOperation.deleteLabel.rawValue,
            accountId: account.id,
            provider: account.provider.graphQLValue,
            status: "LABEL_DELETED",
            labelId: labelId
        )
    }

    // MARK: - Result shaping

    private func messageMutationResult(
        operation: GmailGatewayWriteOperation,
        status: String,
        account: AccountConfig,
        fallbackMessageId: String,
        object: [String: Any]
    ) -> MailboxMutationResult {
        MailboxMutationResult(
            operation: operation.rawValue,
            accountId: account.id,
            provider: account.provider.graphQLValue,
            status: status,
            threadId: object["threadId"] as? String,
            messageId: object["id"] as? String ?? fallbackMessageId,
            labelIds: object["labelIds"] as? [String]
        )
    }

    private func labelMutationResult(
        operation: GmailGatewayWriteOperation,
        status: String,
        account: AccountConfig,
        object: [String: Any],
        fallbackLabelId: String? = nil
    ) -> MailboxMutationResult {
        let labelId = object["id"] as? String ?? fallbackLabelId
        return MailboxMutationResult(
            operation: operation.rawValue,
            accountId: account.id,
            provider: account.provider.graphQLValue,
            status: status,
            labelId: labelId,
            label: labelId.map { id in
                MailLabel(
                    id: id,
                    accountId: account.id,
                    name: object["name"] as? String,
                    type: object["type"] as? String,
                    messageListVisibility: object["messageListVisibility"] as? String,
                    labelListVisibility: object["labelListVisibility"] as? String
                )
            }
        )
    }
}

private func labelChangeBody(addLabelIds: [String], removeLabelIds: [String]) -> [String: Any] {
    var body: [String: Any] = [:]
    if !addLabelIds.isEmpty {
        body["addLabelIds"] = addLabelIds
    }
    if !removeLabelIds.isEmpty {
        body["removeLabelIds"] = removeLabelIds
    }
    return body
}

/// Gmail returns the modified thread with its messages, not a thread-level label list, so the
/// resulting labels are the union across the thread's messages.
private func threadLabelIds(from object: [String: Any]) -> [String]? {
    guard let messages = object["messages"] as? [[String: Any]] else {
        return nil
    }
    var seen: Set<String> = []
    var output: [String] = []
    for labelId in messages.flatMap({ $0["labelIds"] as? [String] ?? [] }) where !seen.contains(labelId) {
        seen.insert(labelId)
        output.append(labelId)
    }
    return output
}
