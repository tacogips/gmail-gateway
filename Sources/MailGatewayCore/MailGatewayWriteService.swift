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
    private let readerService: MailGatewayReaderService

    public init(config: MailGatewayConfig) {
        self.readerService = MailGatewayReaderService(config: config)
    }

    public func sendMessage(input: OutboundMailInput, mode: MailGatewayWriteMode) throws -> [String: Any] {
        let account = try readerService.requireAccount(input.accountId)
        let credential = try readerService.requireCredential(account.credentialId)
        guard credential.accessMode == .readSend else {
            throw MailGatewayError(
                "Credential \(credential.id) must use read_send access mode before \(mode.authContext)",
                code: .sendNotSupported,
                exitCode: .graphqlExecutionError
            )
        }
        try validateOutboundInput(input, account: account)
        let validatedAttachments = try input.attachmentPaths.map(readerService.validateSendAttachmentPath)

        switch mode {
        case .draftDefault:
            return try GmailLiveWriter().createDraft(
                account: account,
                credential: credential,
                input: input,
                validatedAttachmentPaths: validatedAttachments
            )
        case .directSend:
            return try GmailLiveWriter().sendMessage(
                account: account,
                credential: credential,
                input: input,
                validatedAttachmentPaths: validatedAttachments
            )
        }
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
