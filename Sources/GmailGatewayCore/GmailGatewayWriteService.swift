import Foundation

public enum GmailGatewayWriteOperation: String, Sendable {
    case createDraft = "CREATE_DRAFT"
    case updateDraft = "UPDATE_DRAFT"
    case deleteDraft = "DELETE_DRAFT"
    case readDraft = "READ_DRAFT"
    case sendDraft = "SEND_DRAFT"
    case send = "SEND"
    case modifyThreadLabels = "MODIFY_THREAD_LABELS"
    case modifyMessageLabels = "MODIFY_MESSAGE_LABELS"
    case batchModifyMessageLabels = "BATCH_MODIFY_MESSAGE_LABELS"
    case trashThread = "TRASH_THREAD"
    case untrashThread = "UNTRASH_THREAD"
    case trashMessage = "TRASH_MESSAGE"
    case untrashMessage = "UNTRASH_MESSAGE"
    case deleteThread = "DELETE_THREAD"
    case deleteMessage = "DELETE_MESSAGE"
    case batchDeleteMessages = "BATCH_DELETE_MESSAGES"
    case createLabel = "CREATE_LABEL"
    case updateLabel = "UPDATE_LABEL"
    case deleteLabel = "DELETE_LABEL"
    case importMessage = "IMPORT_MESSAGE"
    case insertMessage = "INSERT_MESSAGE"

    /// The mailbox capability a credential must hold for this operation.
    var requiredCapability: MailboxCapability {
        switch self {
        case .createDraft, .updateDraft, .deleteDraft, .readDraft, .sendDraft, .send:
            return .send
        case .modifyThreadLabels, .modifyMessageLabels, .batchModifyMessageLabels,
             .trashThread, .untrashThread, .trashMessage, .untrashMessage,
             .createLabel, .updateLabel, .deleteLabel:
            return .modify
        case .deleteThread, .deleteMessage, .batchDeleteMessages:
            return .permanentDelete
        case .importMessage, .insertMessage:
            return .insert
        }
    }

    /// Whether the payload for this operation names the draft it acted on.
    var reportsDraftId: Bool {
        switch self {
        case .createDraft, .updateDraft, .deleteDraft, .readDraft, .sendDraft:
            return true
        default:
            return false
        }
    }

    var mutationName: String {
        switch self {
        case .createDraft:
            return "createDraft"
        case .updateDraft:
            return "updateDraft"
        case .deleteDraft:
            return "deleteDraft"
        case .readDraft:
            return "draft"
        case .sendDraft:
            return "sendDraft"
        case .send:
            return "sendMessage"
        case .modifyThreadLabels:
            return "modifyThreadLabels"
        case .modifyMessageLabels:
            return "modifyMessageLabels"
        case .batchModifyMessageLabels:
            return "batchModifyMessageLabels"
        case .trashThread:
            return "trashThread"
        case .untrashThread:
            return "untrashThread"
        case .trashMessage:
            return "trashMessage"
        case .untrashMessage:
            return "untrashMessage"
        case .deleteThread:
            return "deleteThread"
        case .deleteMessage:
            return "deleteMessage"
        case .batchDeleteMessages:
            return "batchDeleteMessages"
        case .createLabel:
            return "createLabel"
        case .updateLabel:
            return "updateLabel"
        case .deleteLabel:
            return "deleteLabel"
        case .importMessage:
            return "importMessage"
        case .insertMessage:
            return "insertMessage"
        }
    }

    var authContext: String {
        switch self {
        case .createDraft:
            return "creating Gmail drafts"
        case .updateDraft:
            return "updating Gmail drafts"
        case .deleteDraft:
            return "deleting Gmail drafts"
        case .readDraft:
            return "reading Gmail drafts"
        case .sendDraft:
            return "sending Gmail drafts"
        case .send:
            return "sending Gmail messages"
        case .modifyThreadLabels, .modifyMessageLabels, .batchModifyMessageLabels:
            return "modifying Gmail labels on stored mail"
        case .trashThread, .trashMessage:
            return "trashing Gmail mail"
        case .untrashThread, .untrashMessage:
            return "restoring Gmail mail from trash"
        case .deleteThread, .deleteMessage, .batchDeleteMessages:
            return "permanently deleting Gmail mail"
        case .createLabel, .updateLabel, .deleteLabel:
            return "managing Gmail labels"
        case .importMessage:
            return "importing Gmail messages"
        case .insertMessage:
            return "inserting Gmail messages"
        }
    }
}

public enum GmailGatewayWriteMode: Sendable {
    case draftDefault
    case directSend

    var operation: GmailGatewayWriteOperation {
        switch self {
        case .draftDefault:
            return .createDraft
        case .directSend:
            return .send
        }
    }

    var operationValue: String {
        operation.rawValue
    }
}

public struct OutboundInlineAttachment: Sendable {
    public let filename: String
    public let mimeType: String
    public let data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

public struct OutboundMailInput: Sendable {
    public let accountId: String
    public let to: [String]
    public let cc: [String]
    public let bcc: [String]
    public let replyTo: String?
    public let subject: String?
    public let textBody: String?
    public let htmlBody: String?
    public let attachmentPaths: [String]
    public let threadId: String?
    public let inReplyTo: String?
    public let references: String?
    public let inlineAttachments: [OutboundInlineAttachment]

    public init(
        accountId: String,
        to: [String],
        cc: [String] = [],
        bcc: [String] = [],
        replyTo: String? = nil,
        subject: String? = nil,
        textBody: String? = nil,
        htmlBody: String? = nil,
        attachmentPaths: [String] = [],
        threadId: String? = nil,
        inReplyTo: String? = nil,
        references: String? = nil,
        inlineAttachments: [OutboundInlineAttachment] = []
    ) {
        self.accountId = accountId
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.subject = subject
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.attachmentPaths = attachmentPaths
        self.threadId = threadId
        self.inReplyTo = inReplyTo
        self.references = references
        self.inlineAttachments = inlineAttachments
    }

    func replacingInlineAttachments(_ inlineAttachments: [OutboundInlineAttachment]) -> OutboundMailInput {
        OutboundMailInput(
            accountId: accountId,
            to: to,
            cc: cc,
            bcc: bcc,
            replyTo: replyTo,
            subject: subject,
            textBody: textBody,
            htmlBody: htmlBody,
            attachmentPaths: attachmentPaths,
            threadId: threadId,
            inReplyTo: inReplyTo,
            references: references,
            inlineAttachments: inlineAttachments
        )
    }
}

public struct GmailGatewayWriteService {
    let readerService: GmailGatewayService
    let providerAdapter: MailProviderAdapter

    public init(config: GmailGatewayConfig) {
        self.init(config: config, providerAdapter: GmailProviderAdapter())
    }

    init(config: GmailGatewayConfig, providerAdapter: MailProviderAdapter) {
        self.readerService = GmailGatewayService(config: config, providerAdapter: providerAdapter)
        self.providerAdapter = providerAdapter
    }

    func requireWritableAccount(
        accountId: String,
        operation: GmailGatewayWriteOperation
    ) throws -> (account: AccountConfig, credential: CredentialConfig) {
        let account = try readerService.requireAccount(accountId)
        let credential = try readerService.requireCredential(account.credentialId)
        guard !account.isFallback else {
            throw GmailGatewayError(
                "Fallback account cannot mutate mail; create a config file with an explicit email_address",
                code: .configInvalid,
                exitCode: .graphqlExecutionError
            )
        }
        let capability = operation.requiredCapability
        guard credential.accessMode.grants(capability) else {
            let accepted = AccessMode.modesGranting(capability).map(\.rawValue).joined(separator: " or ")
            throw GmailGatewayError(
                "Credential \(credential.id) must use \(accepted) access mode before \(operation.authContext)",
                code: capability == .send ? .sendNotSupported : .accessModeInsufficient,
                exitCode: .graphqlExecutionError,
                details: [
                    "credentialId": credential.id,
                    "configuredAccessMode": credential.accessMode.rawValue,
                    "requiredCapability": capability.rawValue
                ]
            )
        }
        try validateAuthenticatedSenderIdentity(account: account, credential: credential)
        return (account, credential)
    }

    public func sendMessage(input: OutboundMailInput, mode: GmailGatewayWriteMode) throws -> [String: Any] {
        let (account, credential) = try requireWritableAccount(accountId: input.accountId, operation: mode.operation)
        try validateOutboundInput(input, account: account, operation: mode.operation)
        let attachments = validateOutboundAttachmentPaths(input.attachmentPaths, readerService: readerService)

        switch mode {
        case .draftDefault:
            return try providerAdapter.createDraft(
                account: account,
                credential: credential,
                input: input,
                validatedAttachmentPaths: attachments.acceptedPaths,
                rejectedAttachments: attachments.rejectedAttachments
            ).graphQLObject()
        case .directSend:
            return try providerAdapter.sendMessage(
                account: account,
                credential: credential,
                input: input,
                validatedAttachmentPaths: attachments.acceptedPaths,
                rejectedAttachments: attachments.rejectedAttachments
            ).graphQLObject()
        }
    }
}

struct OutboundAttachmentValidation {
    let acceptedPaths: [String]
    let rejectedAttachments: [MailRejectedAttachment]
}

func validateOutboundAttachmentPaths(
    _ paths: [String],
    readerService: GmailGatewayService
) -> OutboundAttachmentValidation {
    var acceptedPaths: [String] = []
    var rejectedAttachments: [MailRejectedAttachment] = []
    for path in paths {
        do {
            let validatedPath = try readerService.validateSendAttachmentPath(path)
            guard FileManager.default.isReadableFile(atPath: validatedPath) else {
                rejectedAttachments.append(MailRejectedAttachment(
                    path: path,
                    code: GmailGatewayErrorCode.attachmentNotFound.rawValue,
                    reason: "Attachment path is not readable"
                ))
                continue
            }
            acceptedPaths.append(validatedPath)
        } catch let error as GmailGatewayError {
            rejectedAttachments.append(MailRejectedAttachment(
                path: path,
                code: error.code.rawValue,
                reason: error.message
            ))
        } catch {
            rejectedAttachments.append(MailRejectedAttachment(
                path: path,
                code: GmailGatewayErrorCode.invalidArgument.rawValue,
                reason: error.localizedDescription
            ))
        }
    }
    return OutboundAttachmentValidation(acceptedPaths: acceptedPaths, rejectedAttachments: rejectedAttachments)
}

private func validateAuthenticatedSenderIdentity(account: AccountConfig, credential: CredentialConfig) throws {
    let tokenState = inspectTokenStore(credential: credential)
    guard let authenticatedEmail = tokenState.emailAddress else {
        return
    }
    guard authenticatedEmail.caseInsensitiveCompare(account.emailAddress) == .orderedSame else {
        throw GmailGatewayError(
            "Configured account email does not match authenticated Gmail identity",
            code: .configInvalid,
            exitCode: .graphqlExecutionError,
            details: [
                "accountId": account.id,
                "credentialId": credential.id,
                "configuredEmail": account.emailAddress,
                "authenticatedEmail": authenticatedEmail
            ]
        )
    }
}

func validateOutboundInput(
    _ input: OutboundMailInput,
    account: AccountConfig,
    operation: GmailGatewayWriteOperation
) throws {
    let recipients = input.to + input.cc + input.bcc
    if recipients.isEmpty {
        throw GmailGatewayError(
            "\(operation.mutationName) requires at least one to, cc, or bcc recipient",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    if recipients.contains(where: { nonBlank($0) == nil }) {
        throw GmailGatewayError(
            "\(operation.mutationName) recipient values must not be blank",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    if nonBlank(input.textBody) == nil && nonBlank(input.htmlBody) == nil {
        throw GmailGatewayError(
            "\(operation.mutationName) requires textBody or htmlBody",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    let headerValues = [account.emailAddress] + recipients
        + [input.subject, input.replyTo, input.inReplyTo, input.references].compactMap { $0 }
    try headerValues.forEach { value in
        if value.contains("\r") || value.contains("\n") {
            throw GmailGatewayError(
                "\(operation.mutationName) header values must not contain line breaks",
                code: .invalidArgument,
                exitCode: .graphqlExecutionError
            )
        }
    }
}
