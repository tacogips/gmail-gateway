import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let gmailRawMessageSizeLimitBytes = 25 * 1_024 * 1_024

struct GmailLiveWriter {
    func createDraft(
        account: AccountConfig,
        credential: CredentialConfig,
        input: OutboundMailInput,
        validatedAttachmentPaths: [String],
        rejectedAttachments: [MailRejectedAttachment]
    ) throws -> MailWriteResult {
        let accessToken = try validGmailAccessToken(credential: credential, use: .draftCreation)
        let rawMessage = try buildRawMessage(
            from: account.emailAddress,
            input: input,
            attachmentPaths: validatedAttachmentPaths
        )
        let object = try postGmailJSONObject(
            path: "/gmail/v1/users/me/drafts",
            accessToken: accessToken,
            body: ["message": ["raw": rawMessage]],
            context: "Gmail draft creation failed"
        )
        let message = object["message"] as? [String: Any] ?? [:]
        return MailWriteResult(
            operation: MailGatewayWriteMode.draftDefault.operationValue,
            accountId: account.id,
            provider: account.provider.graphQLValue,
            draftId: object["id"] as? String,
            messageId: message["id"] as? String,
            threadId: message["threadId"] as? String,
            status: "DRAFT_CREATED",
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
        let accessToken = try validGmailAccessToken(credential: credential, use: .directSend)
        let rawMessage = try buildRawMessage(
            from: account.emailAddress,
            input: input,
            attachmentPaths: validatedAttachmentPaths
        )
        let object = try postGmailJSONObject(
            path: "/gmail/v1/users/me/messages/send",
            accessToken: accessToken,
            body: ["raw": rawMessage],
            context: "Gmail message send failed"
        )
        return MailWriteResult(
            operation: MailGatewayWriteMode.directSend.operationValue,
            accountId: account.id,
            provider: account.provider.graphQLValue,
            draftId: nil,
            messageId: object["id"] as? String,
            threadId: object["threadId"] as? String,
            status: "SENT",
            rejectedAttachments: rejectedAttachments
        )
    }
}

private func postGmailJSONObject(
    path: String,
    accessToken: String,
    body: [String: Any],
    context: String
) throws -> [String: Any] {
    let components = gmailURLComponents(path: path)
    guard let url = components.url else {
        throw MailGatewayError(
            "Failed to construct Gmail API URL",
            code: .providerApiError,
            exitCode: .providerApiError
        )
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    let response = try performGmailHTTPRequest(request, context: context)
    guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
        throw MailGatewayError(
            "Gmail API response was not a JSON object",
            code: .providerApiError,
            exitCode: .providerApiError
        )
    }
    return object
}

func buildRawMessage(from: String, input: OutboundMailInput, attachmentPaths: [String]) throws -> String {
    var headers: [String] = [
        "From: \(from)"
    ]
    if !input.to.isEmpty {
        headers.append("To: \(input.to.joined(separator: ", "))")
    }
    if !input.cc.isEmpty {
        headers.append("Cc: \(input.cc.joined(separator: ", "))")
    }
    if !input.bcc.isEmpty {
        headers.append("Bcc: \(input.bcc.joined(separator: ", "))")
    }
    if let replyTo = nonBlank(input.replyTo) {
        headers.append("Reply-To: \(replyTo)")
    }
    if let subject = input.subject {
        headers.append("Subject: \(mimeHeaderValue(subject))")
    }
    headers.append("MIME-Version: 1.0")

    let body: String
    if attachmentPaths.isEmpty {
        body = simpleBody(input: input, headers: &headers)
    } else {
        body = try multipartBody(input: input, headers: &headers, attachmentPaths: attachmentPaths)
    }
    let messageData = Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    guard messageData.count <= gmailRawMessageSizeLimitBytes else {
        throw MailGatewayError(
            "Raw message exceeds Gmail size limit before provider call",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError,
            details: [
                "sizeBytes": String(messageData.count),
                "limitBytes": String(gmailRawMessageSizeLimitBytes)
            ]
        )
    }
    return base64URLString(messageData)
}

private func mimeHeaderValue(_ value: String) -> String {
    guard value.unicodeScalars.contains(where: { !$0.isASCII || $0.value < 0x20 || $0.value == 0x7f }) else {
        return value
    }

    let maxChunkBytes = 45
    var chunks: [String] = []
    var current = ""
    var currentByteCount = 0

    for character in value {
        let bytes = String(character).utf8.count
        if !current.isEmpty && currentByteCount + bytes > maxChunkBytes {
            chunks.append(current)
            current = ""
            currentByteCount = 0
        }
        current.append(character)
        currentByteCount += bytes
    }
    if !current.isEmpty {
        chunks.append(current)
    }

    return chunks.map { chunk in
        "=?UTF-8?B?\(Data(chunk.utf8).base64EncodedString())?="
    }.joined(separator: "\r\n ")
}

private func simpleBody(input: OutboundMailInput, headers: inout [String]) -> String {
    if let textBody = input.textBody,
       let htmlBody = input.htmlBody {
        let boundary = "mail-gateway-alt-\(UUID().uuidString)"
        headers.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")
        return multipartAlternativeBody(textBody: textBody, htmlBody: htmlBody, boundary: boundary)
    }
    if let htmlBody = input.htmlBody {
        headers.append("Content-Type: text/html; charset=utf-8")
        headers.append("Content-Transfer-Encoding: 8bit")
        return normalizedMIMEText(htmlBody)
    }
    headers.append("Content-Type: text/plain; charset=utf-8")
    headers.append("Content-Transfer-Encoding: 8bit")
    return normalizedMIMEText(input.textBody ?? "")
}

private func multipartBody(input: OutboundMailInput, headers: inout [String], attachmentPaths: [String]) throws -> String {
    let boundary = "mail-gateway-\(UUID().uuidString)"
    headers.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
    var parts: [String] = []
    parts.append(multipartMessageBodyPart(input: input, boundary: boundary))
    for path in attachmentPaths {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let filename = sanitizedFilename(path)
        let contentType = attachmentContentType(for: filename)
        parts.append([
            "--\(boundary)",
            "Content-Type: \(contentType); name=\"\(filename)\"",
            "Content-Disposition: attachment; filename=\"\(filename)\"",
            "Content-Transfer-Encoding: base64",
            "",
            wrappedBase64(data)
        ].joined(separator: "\r\n"))
    }
    parts.append("--\(boundary)--")
    return parts.joined(separator: "\r\n")
}

private func attachmentContentType(for filename: String) -> String {
    let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
    switch ext {
    case "txt":
        return "text/plain"
    case "htm", "html":
        return "text/html"
    case "csv":
        return "text/csv"
    case "json":
        return "application/json"
    case "pdf":
        return "application/pdf"
    case "png":
        return "image/png"
    case "jpg", "jpeg":
        return "image/jpeg"
    case "gif":
        return "image/gif"
    case "webp":
        return "image/webp"
    case "svg":
        return "image/svg+xml"
    case "mp3":
        return "audio/mpeg"
    case "mp4":
        return "video/mp4"
    case "mov":
        return "video/quicktime"
    case "eml":
        return "message/rfc822"
    case "zip":
        return "application/zip"
    default:
        return "application/octet-stream"
    }
}

private func multipartMessageBodyPart(input: OutboundMailInput, boundary: String) -> String {
    if let textBody = input.textBody,
       let htmlBody = input.htmlBody {
        let alternativeBoundary = "mail-gateway-alt-\(UUID().uuidString)"
        return [
            "--\(boundary)",
            "Content-Type: multipart/alternative; boundary=\"\(alternativeBoundary)\"",
            "",
            multipartAlternativeBody(textBody: textBody, htmlBody: htmlBody, boundary: alternativeBoundary)
        ].joined(separator: "\r\n")
    }
    let contentType = input.htmlBody == nil ? "text/plain" : "text/html"
    let bodyText = normalizedMIMEText(input.htmlBody ?? input.textBody ?? "")
    return [
        "--\(boundary)",
        "Content-Type: \(contentType); charset=utf-8",
        "Content-Transfer-Encoding: 8bit",
        "",
        bodyText
    ].joined(separator: "\r\n")
}

private func multipartAlternativeBody(textBody: String, htmlBody: String, boundary: String) -> String {
    [
        [
            "--\(boundary)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: 8bit",
            "",
            normalizedMIMEText(textBody)
        ].joined(separator: "\r\n"),
        [
            "--\(boundary)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Transfer-Encoding: 8bit",
            "",
            normalizedMIMEText(htmlBody)
        ].joined(separator: "\r\n"),
        "--\(boundary)--"
    ].joined(separator: "\r\n")
}

private func normalizedMIMEText(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .replacingOccurrences(of: "\n", with: "\r\n")
}

private func wrappedBase64(_ data: Data) -> String {
    data.base64EncodedString(options: [
        .lineLength76Characters,
        .endLineWithCarriageReturn,
        .endLineWithLineFeed
    ])
}
