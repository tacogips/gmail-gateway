import Foundation

public enum MailGatewayWriteMode: Sendable {
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

    public init(
        accountId: String,
        to: [String],
        cc: [String] = [],
        bcc: [String] = [],
        replyTo: String? = nil,
        subject: String? = nil,
        textBody: String? = nil,
        htmlBody: String? = nil,
        attachmentPaths: [String] = []
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
    }
}

public struct MailGatewayWriteService {
    private let readerService: MailGatewayService
    private let providerAdapter: MailProviderAdapter

    public init(config: MailGatewayConfig) {
        self.init(config: config, providerAdapter: GmailProviderAdapter())
    }

    init(config: MailGatewayConfig, providerAdapter: MailProviderAdapter) {
        self.readerService = MailGatewayService(config: config, providerAdapter: providerAdapter)
        self.providerAdapter = providerAdapter
    }

    public func sendMessage(input: OutboundMailInput, mode: MailGatewayWriteMode) throws -> [String: Any] {
        let account = try readerService.requireAccount(input.accountId)
        let credential = try readerService.requireCredential(account.credentialId)
        guard !account.isFallback else {
            throw MailGatewayError(
                "Fallback account cannot send mail; create a config file with an explicit email_address",
                code: .configInvalid,
                exitCode: .graphqlExecutionError
            )
        }
        guard credential.accessMode == .readSend else {
            throw MailGatewayError(
                "Credential \(credential.id) must use read_send access mode before \(mode.authContext)",
                code: .sendNotSupported,
                exitCode: .graphqlExecutionError
            )
        }
        try validateAuthenticatedSenderIdentity(account: account, credential: credential)
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
    readerService: MailGatewayService
) -> OutboundAttachmentValidation {
    var acceptedPaths: [String] = []
    var rejectedAttachments: [MailRejectedAttachment] = []
    for path in paths {
        do {
            let validatedPath = try readerService.validateSendAttachmentPath(path)
            guard FileManager.default.isReadableFile(atPath: validatedPath) else {
                rejectedAttachments.append(MailRejectedAttachment(
                    path: path,
                    code: MailGatewayErrorCode.attachmentNotFound.rawValue,
                    reason: "Attachment path is not readable"
                ))
                continue
            }
            acceptedPaths.append(validatedPath)
        } catch let error as MailGatewayError {
            rejectedAttachments.append(MailRejectedAttachment(
                path: path,
                code: error.code.rawValue,
                reason: error.message
            ))
        } catch {
            rejectedAttachments.append(MailRejectedAttachment(
                path: path,
                code: MailGatewayErrorCode.invalidArgument.rawValue,
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
        throw MailGatewayError(
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
        throw MailGatewayError(
            "sendMessage requires at least one to, cc, or bcc recipient",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    if recipients.contains(where: { nonBlank($0) == nil }) {
        throw MailGatewayError(
            "sendMessage recipient values must not be blank",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    if nonBlank(input.textBody) == nil && nonBlank(input.htmlBody) == nil {
        throw MailGatewayError(
            "sendMessage requires textBody or htmlBody",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    let headerValues = [account.emailAddress] + recipients + [input.subject, input.replyTo].compactMap { $0 }
    try headerValues.forEach { value in
        if value.contains("\r") || value.contains("\n") {
            throw MailGatewayError(
                "sendMessage header values must not contain line breaks",
                code: .invalidArgument,
                exitCode: .graphqlExecutionError
            )
        }
    }
}
