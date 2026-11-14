import Foundation

/// Mail ingestion transport (Gmail `messages.import` and `messages.insert`). These add existing
/// RFC 822 mail to the mailbox without sending it, so they are reachable only through
/// `gmail-gateway-message-box`.
struct GmailLiveIngest {
    func importMessage(
        account: AccountConfig,
        credential: CredentialConfig,
        input: MailIngestInput
    ) throws -> MailboxMutationResult {
        try ingest(
            account: account,
            credential: credential,
            input: input,
            operation: .importMessage,
            path: "/gmail/v1/users/me/messages/import",
            status: "MESSAGE_IMPORTED",
            context: "Gmail message import failed"
        )
    }

    func insertMessage(
        account: AccountConfig,
        credential: CredentialConfig,
        input: MailIngestInput
    ) throws -> MailboxMutationResult {
        try ingest(
            account: account,
            credential: credential,
            input: input,
            operation: .insertMessage,
            path: "/gmail/v1/users/me/messages",
            status: "MESSAGE_INSERTED",
            context: "Gmail message insert failed"
        )
    }

    private func ingest(
        account: AccountConfig,
        credential: CredentialConfig,
        input: MailIngestInput,
        operation: GmailGatewayWriteOperation,
        path: String,
        status: String,
        context: String
    ) throws -> MailboxMutationResult {
        let accessToken = try validGmailAccessToken(credential: credential, use: .mailIngest)
        var body: [String: Any] = ["raw": input.rawMessage]
        if !input.labelIds.isEmpty {
            body["labelIds"] = input.labelIds
        }
        let object = try postGmailJSONObject(
            path: path,
            accessToken: accessToken,
            body: body,
            context: context,
            queryItems: input.queryItems(for: operation)
        )
        return MailboxMutationResult(
            operation: operation.rawValue,
            accountId: account.id,
            provider: account.provider.graphQLValue,
            status: status,
            threadId: object["threadId"] as? String,
            messageId: object["id"] as? String,
            labelIds: object["labelIds"] as? [String]
        )
    }
}
