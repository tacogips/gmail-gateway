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
    func modifyThreadLabels(
        account: AccountConfig,
        credential: CredentialConfig,
        threadId: String,
        addLabelIds: [String],
        removeLabelIds: [String]
    ) throws -> MailboxMutationResult
    func modifyMessageLabels(
        account: AccountConfig,
        credential: CredentialConfig,
        messageId: String,
        addLabelIds: [String],
        removeLabelIds: [String]
    ) throws -> MailboxMutationResult
    func batchModifyMessageLabels(
        account: AccountConfig,
        credential: CredentialConfig,
        messageIds: [String],
        addLabelIds: [String],
        removeLabelIds: [String]
    ) throws -> MailboxMutationResult
    func setThreadTrashed(
        account: AccountConfig,
        credential: CredentialConfig,
        threadId: String,
        trashed: Bool
    ) throws -> MailboxMutationResult
    func setMessageTrashed(
        account: AccountConfig,
        credential: CredentialConfig,
        messageId: String,
        trashed: Bool
    ) throws -> MailboxMutationResult
    func deleteThread(
        account: AccountConfig,
        credential: CredentialConfig,
        threadId: String
    ) throws -> MailboxMutationResult
    func deleteMessage(
        account: AccountConfig,
        credential: CredentialConfig,
        messageId: String
    ) throws -> MailboxMutationResult
    func batchDeleteMessages(
        account: AccountConfig,
        credential: CredentialConfig,
        messageIds: [String]
    ) throws -> MailboxMutationResult
    func createLabel(
        account: AccountConfig,
        credential: CredentialConfig,
        input: LabelWriteInput
    ) throws -> MailboxMutationResult
    func updateLabel(
        account: AccountConfig,
        credential: CredentialConfig,
        labelId: String,
        input: LabelWriteInput
    ) throws -> MailboxMutationResult
    func deleteLabel(
        account: AccountConfig,
        credential: CredentialConfig,
        labelId: String
    ) throws -> MailboxMutationResult
    func importMessage(
        account: AccountConfig,
        credential: CredentialConfig,
        input: MailIngestInput
    ) throws -> MailboxMutationResult
    func insertMessage(
        account: AccountConfig,
        credential: CredentialConfig,
        input: MailIngestInput
    ) throws -> MailboxMutationResult
}

struct GmailProviderAdapter: MailProviderAdapter {
    private let reader = GmailLiveReader()
    private let writer = GmailLiveWriter()
    private let drafts = GmailLiveDrafts()
    private let mailbox = GmailLiveMailbox()
    private let ingest = GmailLiveIngest()

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

    func modifyThreadLabels(
        account: AccountConfig,
        credential: CredentialConfig,
        threadId: String,
        addLabelIds: [String],
        removeLabelIds: [String]
    ) throws -> MailboxMutationResult {
        try mailbox.modifyThreadLabels(
            account: account,
            credential: credential,
            threadId: threadId,
            addLabelIds: addLabelIds,
            removeLabelIds: removeLabelIds
        )
    }

    func modifyMessageLabels(
        account: AccountConfig,
        credential: CredentialConfig,
        messageId: String,
        addLabelIds: [String],
        removeLabelIds: [String]
    ) throws -> MailboxMutationResult {
        try mailbox.modifyMessageLabels(
            account: account,
            credential: credential,
            messageId: messageId,
            addLabelIds: addLabelIds,
            removeLabelIds: removeLabelIds
        )
    }

    func batchModifyMessageLabels(
        account: AccountConfig,
        credential: CredentialConfig,
        messageIds: [String],
        addLabelIds: [String],
        removeLabelIds: [String]
    ) throws -> MailboxMutationResult {
        try mailbox.batchModifyMessageLabels(
            account: account,
            credential: credential,
            messageIds: messageIds,
            addLabelIds: addLabelIds,
            removeLabelIds: removeLabelIds
        )
    }

    func setThreadTrashed(
        account: AccountConfig,
        credential: CredentialConfig,
        threadId: String,
        trashed: Bool
    ) throws -> MailboxMutationResult {
        try mailbox.setThreadTrashed(
            account: account,
            credential: credential,
            threadId: threadId,
            trashed: trashed
        )
    }

    func setMessageTrashed(
        account: AccountConfig,
        credential: CredentialConfig,
        messageId: String,
        trashed: Bool
    ) throws -> MailboxMutationResult {
        try mailbox.setMessageTrashed(
            account: account,
            credential: credential,
            messageId: messageId,
            trashed: trashed
        )
    }

    func deleteThread(
        account: AccountConfig,
        credential: CredentialConfig,
        threadId: String
    ) throws -> MailboxMutationResult {
        try mailbox.deleteThread(account: account, credential: credential, threadId: threadId)
    }

    func deleteMessage(
        account: AccountConfig,
        credential: CredentialConfig,
        messageId: String
    ) throws -> MailboxMutationResult {
        try mailbox.deleteMessage(account: account, credential: credential, messageId: messageId)
    }

    func batchDeleteMessages(
        account: AccountConfig,
        credential: CredentialConfig,
        messageIds: [String]
    ) throws -> MailboxMutationResult {
        try mailbox.batchDeleteMessages(account: account, credential: credential, messageIds: messageIds)
    }

    func createLabel(
        account: AccountConfig,
        credential: CredentialConfig,
        input: LabelWriteInput
    ) throws -> MailboxMutationResult {
        try mailbox.createLabel(account: account, credential: credential, input: input)
    }

    func updateLabel(
        account: AccountConfig,
        credential: CredentialConfig,
        labelId: String,
        input: LabelWriteInput
    ) throws -> MailboxMutationResult {
        try mailbox.updateLabel(account: account, credential: credential, labelId: labelId, input: input)
    }

    func deleteLabel(
        account: AccountConfig,
        credential: CredentialConfig,
        labelId: String
    ) throws -> MailboxMutationResult {
        try mailbox.deleteLabel(account: account, credential: credential, labelId: labelId)
    }

    func importMessage(
        account: AccountConfig,
        credential: CredentialConfig,
        input: MailIngestInput
    ) throws -> MailboxMutationResult {
        try ingest.importMessage(account: account, credential: credential, input: input)
    }

    func insertMessage(
        account: AccountConfig,
        credential: CredentialConfig,
        input: MailIngestInput
    ) throws -> MailboxMutationResult {
        try ingest.insertMessage(account: account, credential: credential, input: input)
    }
}
