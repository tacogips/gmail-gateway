import Foundation

public enum GmailGatewayWriteMode: Sendable {
    case draftDefault
    case directSend

    var operationValue: String {
        switch self {
        case .draftDefault:
            return "CREATE_DRAFT"
        case .directSend:
            return "SEND"
        }
    }

    var authContext: String {
        switch self {
        case .draftDefault:
            return "creating Gmail drafts"
        case .directSend:
            return "sending Gmail messages"
        }
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
        mode: GmailGatewayWriteMode
    ) throws -> (account: AccountConfig, credential: CredentialConfig) {
        let account = try readerService.requireAccount(accountId)
        let credential = try readerService.requireCredential(account.credentialId)
        guard !account.isFallback else {
            throw GmailGatewayError(
                "Fallback account cannot send mail; create a config file with an explicit email_address",
                code: .configInvalid,
                exitCode: .graphqlExecutionError
            )
        }
        guard credential.accessMode == .readSend else {
            throw GmailGatewayError(
                "Credential \(credential.id) must use read_send access mode before \(mode.authContext)",
                code: .sendNotSupported,
                exitCode: .graphqlExecutionError
            )
        }
        try validateAuthenticatedSenderIdentity(account: account, credential: credential)
        return (account, credential)
    }

    public func sendMessage(input: OutboundMailInput, mode: GmailGatewayWriteMode) throws -> [String: Any] {
        let (account, credential) = try requireWritableAccount(accountId: input.accountId, mode: mode)
        try validateOutboundInput(input, account: account)
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

private struct OutboundAttachmentValidation {
    let acceptedPaths: [String]
    let rejectedAttachments: [MailRejectedAttachment]
}

private func validateOutboundAttachmentPaths(
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

private func validateOutboundInput(_ input: OutboundMailInput, account: AccountConfig) throws {
    let recipients = input.to + input.cc + input.bcc
    if recipients.isEmpty {
        throw GmailGatewayError(
            "sendMessage requires at least one to, cc, or bcc recipient",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    if recipients.contains(where: { nonBlank($0) == nil }) {
        throw GmailGatewayError(
            "sendMessage recipient values must not be blank",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    if nonBlank(input.textBody) == nil && nonBlank(input.htmlBody) == nil {
        throw GmailGatewayError(
            "sendMessage requires textBody or htmlBody",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    let headerValues = [account.emailAddress] + recipients
        + [input.subject, input.replyTo, input.inReplyTo, input.references].compactMap { $0 }
    try headerValues.forEach { value in
        if value.contains("\r") || value.contains("\n") {
            throw GmailGatewayError(
                "sendMessage header values must not contain line breaks",
                code: .invalidArgument,
                exitCode: .graphqlExecutionError
            )
        }
    }
}
