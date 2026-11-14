import Foundation

public struct ReplyMessageInput: Sendable {
    public let accountId: String
    public let messageId: String
    public let to: [String]
    public let cc: [String]
    public let bcc: [String]
    public let replyAll: Bool
    public let textBody: String?
    public let htmlBody: String?
    public let attachmentPaths: [String]

    public init(
        accountId: String,
        messageId: String,
        to: [String] = [],
        cc: [String] = [],
        bcc: [String] = [],
        replyAll: Bool = false,
        textBody: String? = nil,
        htmlBody: String? = nil,
        attachmentPaths: [String] = []
    ) {
        self.accountId = accountId
        self.messageId = messageId
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyAll = replyAll
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.attachmentPaths = attachmentPaths
    }
}

public struct ForwardMessageInput: Sendable {
    public let accountId: String
    public let messageId: String
    public let to: [String]
    public let cc: [String]
    public let bcc: [String]
    public let textBody: String?
    public let htmlBody: String?
    public let includeAttachments: Bool
    public let attachmentPaths: [String]

    public init(
        accountId: String,
        messageId: String,
        to: [String],
        cc: [String] = [],
        bcc: [String] = [],
        textBody: String? = nil,
        htmlBody: String? = nil,
        includeAttachments: Bool = true,
        attachmentPaths: [String] = []
    ) {
        self.accountId = accountId
        self.messageId = messageId
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.includeAttachments = includeAttachments
        self.attachmentPaths = attachmentPaths
    }
}

extension GmailGatewayWriteService {
    public func replyMessage(input: ReplyMessageInput, mode: GmailGatewayWriteMode) throws -> [String: Any] {
        let (account, credential) = try requireWritableAccount(accountId: input.accountId, mode: mode)
        let original = try providerAdapter.getMessage(
            account: account,
            credential: credential,
            messageId: input.messageId
        )
        let outbound = plannedReplyMail(input: input, original: original, accountEmail: account.emailAddress)
        return try sendMessage(input: outbound, mode: mode)
    }

    public func forwardMessage(input: ForwardMessageInput, mode: GmailGatewayWriteMode) throws -> [String: Any] {
        let (account, credential) = try requireWritableAccount(accountId: input.accountId, mode: mode)
        let original = try providerAdapter.getMessage(
            account: account,
            credential: credential,
            messageId: input.messageId
        )
        let bodyFiles = try providerAdapter.getMessageBodyFiles(
            credential: credential,
            messageId: input.messageId
        )
        let inlineAttachments = input.includeAttachments
            ? try forwardableInlineAttachments(original: original, credential: credential)
            : []
        let outbound = plannedForwardMail(
            input: input,
            original: original,
            bodyFiles: bodyFiles,
            inlineAttachments: inlineAttachments
        )
        return try sendMessage(input: outbound, mode: mode)
    }

    private func forwardableInlineAttachments(
        original: MailMessage,
        credential: CredentialConfig
    ) throws -> [OutboundInlineAttachment] {
        try original.attachments.compactMap { attachment in
            guard let attachmentId = attachment.providerMetadata?.gmail?.attachmentId else {
                return nil
            }
            return OutboundInlineAttachment(
                filename: attachment.filename ?? "attachment",
                mimeType: attachment.mimeType,
                data: try providerAdapter.getAttachmentPayload(
                    credential: credential,
                    messageId: original.id,
                    attachmentId: attachmentId
                )
            )
        }
    }
}

func plannedReplyMail(input: ReplyMessageInput, original: MailMessage, accountEmail: String) -> OutboundMailInput {
    let replyTargets = original.replyTo.isEmpty ? original.from : original.replyTo
    let to = input.to.isEmpty ? replyTargets.map(\.raw) : input.to
    var cc = input.cc
    if input.replyAll && input.cc.isEmpty {
        var excluded = Set(to.map(normalizedAddressSpec))
        excluded.insert(normalizedAddressSpec(accountEmail))
        cc = uniqueAddresses((original.to + original.cc).map(\.raw).filter { raw in
            !excluded.contains(normalizedAddressSpec(raw))
        })
    }
    return OutboundMailInput(
        accountId: input.accountId,
        to: uniqueAddresses(to),
        cc: cc,
        bcc: input.bcc,
        subject: prefixedSubject(original.subject, prefix: "Re:"),
        textBody: input.textBody,
        htmlBody: input.htmlBody,
        attachmentPaths: input.attachmentPaths,
        threadId: nonBlank(original.threadId),
        inReplyTo: original.rfc822MessageId,
        references: joinedReferences(original.referencesHeader, original.rfc822MessageId)
    )
}

func plannedForwardMail(
    input: ForwardMessageInput,
    original: MailMessage,
    bodyFiles: [GmailMessageBodyFile],
    inlineAttachments: [OutboundInlineAttachment]
) -> OutboundMailInput {
    let originalText = bodyFileText(bodyFiles, kind: .bodyText)
    let originalHTML = bodyFileText(bodyFiles, kind: .bodyHTML)
    let headerBlockLines = forwardedHeaderLines(original: original)

    var textSections: [String] = []
    if let note = nonBlank(input.textBody) {
        textSections.append(note)
    }
    var textQuote = headerBlockLines.joined(separator: "\n")
    if let originalText = nonBlank(originalText) {
        textQuote += "\n\n" + originalText
    }
    textSections.append(textQuote)
    let textBody = textSections.joined(separator: "\n\n")

    var htmlBody: String?
    if nonBlank(input.htmlBody) != nil || nonBlank(originalHTML) != nil {
        var htmlSections: [String] = []
        if let noteHTML = nonBlank(input.htmlBody) {
            htmlSections.append(noteHTML)
        } else if let note = nonBlank(input.textBody) {
            htmlSections.append("<div>\(escapedHTMLText(note).replacingOccurrences(of: "\n", with: "<br>"))</div>")
        }
        let headerHTML = headerBlockLines.map { escapedHTMLText($0) }.joined(separator: "<br>")
        htmlSections.append("<div>\(headerHTML)</div>")
        let quotedHTML = nonBlank(originalHTML)
            ?? nonBlank(originalText).map { text in
                "<div style=\"white-space:pre-wrap\">\(escapedHTMLText(text))</div>"
            }
        if let quotedHTML {
            htmlSections.append(
                "<blockquote style=\"margin:0 0 0 .8ex;border-left:1px solid #ccc;padding-left:1ex\">"
                    + quotedHTML + "</blockquote>"
            )
        }
        htmlBody = htmlSections.joined(separator: "<br>")
    }

    return OutboundMailInput(
        accountId: input.accountId,
        to: input.to,
        cc: input.cc,
        bcc: input.bcc,
        subject: prefixedSubject(original.subject, prefix: "Fwd:"),
        textBody: textBody,
        htmlBody: htmlBody,
        attachmentPaths: input.attachmentPaths,
        threadId: nonBlank(original.threadId),
        references: joinedReferences(original.referencesHeader, original.rfc822MessageId),
        inlineAttachments: inlineAttachments
    )
}

func prefixedSubject(_ subject: String?, prefix: String) -> String {
    guard let subject = nonBlank(subject) else {
        return prefix
    }
    let normalizedPrefix = prefix.lowercased()
    guard !subject.lowercased().hasPrefix(normalizedPrefix) else {
        return subject
    }
    return "\(prefix) \(subject)"
}

func joinedReferences(_ references: String?, _ messageId: String?) -> String? {
    let parts = [nonBlank(references), nonBlank(messageId)].compactMap { $0 }
    guard !parts.isEmpty else {
        return nil
    }
    return parts.joined(separator: " ")
}

func normalizedAddressSpec(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let openIndex = trimmed.lastIndex(of: "<"),
          let closeIndex = trimmed.lastIndex(of: ">"),
          openIndex < closeIndex else {
        return trimmed.lowercased()
    }
    return String(trimmed[trimmed.index(after: openIndex)..<closeIndex])
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}

private func uniqueAddresses(_ addresses: [String]) -> [String] {
    var seen = Set<String>()
    var output: [String] = []
    for address in addresses {
        let key = normalizedAddressSpec(address)
        guard !seen.contains(key) else {
            continue
        }
        seen.insert(key)
        output.append(address)
    }
    return output
}

private func bodyFileText(_ bodyFiles: [GmailMessageBodyFile], kind: MessageMaterializedFileKind) -> String? {
    guard let file = bodyFiles.first(where: { $0.kind == kind }) else {
        return nil
    }
    return String(data: file.data, encoding: .utf8)
}

private func forwardedHeaderLines(original: MailMessage) -> [String] {
    var lines = ["---------- Forwarded message ----------"]
    if !original.from.isEmpty {
        lines.append("From: \(original.from.map(\.raw).joined(separator: ", "))")
    }
    if let sentAt = nonBlank(original.sentAt) {
        lines.append("Date: \(sentAt)")
    }
    lines.append("Subject: \(original.subject ?? "")")
    if !original.to.isEmpty {
        lines.append("To: \(original.to.map(\.raw).joined(separator: ", "))")
    }
    if !original.cc.isEmpty {
        lines.append("Cc: \(original.cc.map(\.raw).joined(separator: ", "))")
    }
    return lines
}

private func escapedHTMLText(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
