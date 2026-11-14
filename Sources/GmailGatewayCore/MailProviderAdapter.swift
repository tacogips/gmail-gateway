import Foundation

protocol MailProviderAdapter {
    func searchThreads(_ request: GmailThreadSearchRequest) throws -> MailThreadConnection
    func getThread(account: AccountConfig, credential: CredentialConfig, threadId: String) throws -> MailThread
    func getMessage(account: AccountConfig, credential: CredentialConfig, messageId: String) throws -> MailMessage
    func getMessageBodyFiles(credential: CredentialConfig, messageId: String) throws -> [GmailMessageBodyFile]
    func getAttachment(
        account: AccountConfig,
        credential: CredentialConfig,
        messageId: String,
        attachmentId: String
    ) throws -> MailAttachment
    func getAttachmentPayload(credential: CredentialConfig, messageId: String, attachmentId: String) throws -> Data
    func createDraft(
        account: AccountConfig,
        credential: CredentialConfig,
        input: OutboundMailInput,
        validatedAttachmentPaths: [String],
        rejectedAttachments: [MailRejectedAttachment]
    ) throws -> MailWriteResult
    func sendMessage(
        account: AccountConfig,
        credential: CredentialConfig,
        input: OutboundMailInput,
        validatedAttachmentPaths: [String],
        rejectedAttachments: [MailRejectedAttachment]
    ) throws -> MailWriteResult
}

struct GmailProviderAdapter: MailProviderAdapter {
    private let reader = GmailLiveReader()
    private let writer = GmailLiveWriter()

    func searchThreads(_ request: GmailThreadSearchRequest) throws -> MailThreadConnection {
        try reader.searchThreads(request)
    }

    func getThread(account: AccountConfig, credential: CredentialConfig, threadId: String) throws -> MailThread {
        try reader.getThread(account: account, credential: credential, threadId: threadId)
    }

    func getMessage(account: AccountConfig, credential: CredentialConfig, messageId: String) throws -> MailMessage {
        try reader.getMessage(account: account, credential: credential, messageId: messageId)
    }

    func getMessageBodyFiles(credential: CredentialConfig, messageId: String) throws -> [GmailMessageBodyFile] {
        try reader.getMessageBodyFiles(credential: credential, messageId: messageId)
    }

    func getAttachment(
        account: AccountConfig,
        credential: CredentialConfig,
        messageId: String,
        attachmentId: String
    ) throws -> MailAttachment {
        try reader.getAttachment(
            account: account,
            credential: credential,
            messageId: messageId,
            attachmentId: attachmentId
        )
    }

    func getAttachmentPayload(credential: CredentialConfig, messageId: String, attachmentId: String) throws -> Data {
        try reader.getAttachmentPayload(credential: credential, messageId: messageId, attachmentId: attachmentId)
    }

    func createDraft(
        account: AccountConfig,
        credential: CredentialConfig,
        input: OutboundMailInput,
        validatedAttachmentPaths: [String],
        rejectedAttachments: [MailRejectedAttachment]
    ) throws -> MailWriteResult {
        try writer.createDraft(
            account: account,
            credential: credential,
            input: input,
            validatedAttachmentPaths: validatedAttachmentPaths,
            rejectedAttachments: rejectedAttachments
        )
    }

    func sendMessage(
        account: AccountConfig,
        credential: CredentialConfig,
        input: OutboundMailInput,
        validatedAttachmentPaths: [String],
        rejectedAttachments: [MailRejectedAttachment]
    ) throws -> MailWriteResult {
        try writer.sendMessage(
            account: account,
            credential: credential,
            input: input,
            validatedAttachmentPaths: validatedAttachmentPaths,
            rejectedAttachments: rejectedAttachments
        )
    }
}
