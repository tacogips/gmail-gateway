import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct GmailLiveWriter {
    func createDraft(
        account: AccountConfig,
        credential: CredentialConfig,
        input: OutboundMailInput,
        validatedAttachmentPaths: [String]
    ) throws -> [String: Any] {
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
        return [
            "operation": MailGatewayWriteMode.draftDefault.operationValue,
            "accountId": account.id,
            "provider": account.provider.graphQLValue,
            "draftId": object["id"] as? String ?? NSNull(),
            "messageId": message["id"] as? String ?? NSNull(),
            "threadId": message["threadId"] as? String ?? NSNull(),
            "status": "DRAFT_CREATED",
            "rejectedAttachments": []
        ]
    }

    func sendMessage(
        account: AccountConfig,
        credential: CredentialConfig,
        input: OutboundMailInput,
        validatedAttachmentPaths: [String]
    ) throws -> [String: Any] {
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
        return [
            "operation": MailGatewayWriteMode.directSend.operationValue,
            "accountId": account.id,
            "provider": account.provider.graphQLValue,
            "messageId": object["id"] as? String ?? NSNull(),
            "threadId": object["threadId"] as? String ?? NSNull(),
            "status": "SENT",
            "rejectedAttachments": []
        ]
    }
}

private func postGmailJSONObject(
    path: String,
    accessToken: String,
    body: [String: Any],
    context: String
) throws -> [String: Any] {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "gmail.googleapis.com"
    components.path = path
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

private func buildRawMessage(from: String, input: OutboundMailInput, attachmentPaths: [String]) throws -> String {
    var headers: [String] = [
        "From: \(from)",
        "To: \(input.to.joined(separator: ", "))"
    ]
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
    return base64URLString(Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8))
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
    if let htmlBody = input.htmlBody {
        headers.append("Content-Type: text/html; charset=utf-8")
        headers.append("Content-Transfer-Encoding: 8bit")
        return htmlBody
    }
    headers.append("Content-Type: text/plain; charset=utf-8")
    headers.append("Content-Transfer-Encoding: 8bit")
    return input.textBody ?? ""
}

private func multipartBody(input: OutboundMailInput, headers: inout [String], attachmentPaths: [String]) throws -> String {
    let boundary = "mail-gateway-\(UUID().uuidString)"
    headers.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
    var parts: [String] = []
    let contentType = input.htmlBody == nil ? "text/plain" : "text/html"
    let bodyText = input.htmlBody ?? input.textBody ?? ""
    parts.append("""
--\(boundary)
Content-Type: \(contentType); charset=utf-8
Content-Transfer-Encoding: 8bit

\(bodyText)
""")
    for path in attachmentPaths {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let filename = sanitizedFilename(path)
        parts.append("""
--\(boundary)
Content-Type: application/octet-stream; name="\(filename)"
Content-Disposition: attachment; filename="\(filename)"
Content-Transfer-Encoding: base64

\(data.base64EncodedString())
""")
    }
    parts.append("--\(boundary)--")
    return parts.joined(separator: "\r\n")
}
