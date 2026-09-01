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
    func listLabels(account: AccountConfig, credential: CredentialConfig) throws -> [MailLabel]
    func getProfile(account: AccountConfig, credential: CredentialConfig) throws -> MailProfile
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
    func listDrafts(
        account: AccountConfig,
        credential: CredentialConfig,
        first: Int,
        after: String?,
        includeEdges: Bool,
        includeNodeDetails: Bool
    ) throws -> MailDraftConnection
    func getDraft(
        account: AccountConfig,
        credential: CredentialConfig,
        draftId: String
    ) throws -> MailDraft
    func updateDraft(
        account: AccountConfig,
        credential: CredentialConfig,
        draftId: String,
        input: OutboundMailInput,
        validatedAttachmentPaths: [String],
        rejectedAttachments: [MailRejectedAttachment]
    ) throws -> MailWriteResult
    func deleteDraft(
        account: AccountConfig,
        credential: CredentialConfig,
        draftId: String
    ) throws -> MailWriteResult
    func sendDraft(
        account: AccountConfig,
        credential: CredentialConfig,
        draftId: String
    ) throws -> MailWriteResult
}

struct GmailProviderAdapter: MailProviderAdapter {
    private let reader = GmailLiveReader()
    private let writer = GmailLiveWriter()
    private let drafts = GmailLiveDrafts()

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

    func listLabels(account: AccountConfig, credential: CredentialConfig) throws -> [MailLabel] {
        try reader.listLabels(account: account, credential: credential)
    }

    func getProfile(account: AccountConfig, credential: CredentialConfig) throws -> MailProfile {
        try reader.getProfile(account: account, credential: credential)
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

    func listDrafts(
        account: AccountConfig,
        credential: CredentialConfig,
        first: Int,
        after: String?,
        includeEdges: Bool,
        includeNodeDetails: Bool
    ) throws -> MailDraftConnection {
        try drafts.listDrafts(
            account: account,
            credential: credential,
            first: first,
            after: after,
            includeEdges: includeEdges,
            includeNodeDetails: includeNodeDetails
        )
    }

    func getDraft(
        account: AccountConfig,
        credential: CredentialConfig,
        draftId: String
    ) throws -> MailDraft {
        try drafts.getDraft(account: account, credential: credential, draftId: draftId)
    }

    func updateDraft(
        account: AccountConfig,
        credential: CredentialConfig,
        draftId: String,
        input: OutboundMailInput,
        validatedAttachmentPaths: [String],
        rejectedAttachments: [MailRejectedAttachment]
    ) throws -> MailWriteResult {
        try drafts.updateDraft(
            account: account,
            credential: credential,
            draftId: draftId,
            input: input,
            validatedAttachmentPaths: validatedAttachmentPaths,
            rejectedAttachments: rejectedAttachments
        )
    }

    func deleteDraft(
        account: AccountConfig,
        credential: CredentialConfig,
        draftId: String
    ) throws -> MailWriteResult {
        try drafts.deleteDraft(account: account, credential: credential, draftId: draftId)
    }

    func sendDraft(
        account: AccountConfig,
        credential: CredentialConfig,
        draftId: String
    ) throws -> MailWriteResult {
        try writer.sendDraft(account: account, credential: credential, draftId: draftId)
    }
}
