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
        let accessToken = try gmailWriteAccessToken(credential: credential, context: "creating Gmail drafts")
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
        let accessToken = try gmailWriteAccessToken(credential: credential, context: "sending Gmail messages")
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

private func gmailWriteAccessToken(credential: CredentialConfig, context: String) throws -> String {
    let tokenStore = try loadGmailWriteTokenStore(credential: credential, context: context)
    if let accessToken = nonBlank(tokenStore.accessToken),
       tokenStore.expiresAt.flatMap({ ISO8601DateFormatter().date(from: $0) }).map({
           $0 > Date().addingTimeInterval(60)
       }) ?? true {
        return accessToken
    }
    return try refreshGmailWriteAccessToken(credential: credential, tokenStore: tokenStore)
}

private func loadGmailWriteTokenStore(credential: CredentialConfig, context: String) throws -> GmailOAuthTokenStore {
    guard credential.tokenStoreJSON != nil || FileManager.default.isReadableFile(atPath: credential.tokenStorePath) else {
        throw MailGatewayError(
            "Authentication is required before \(context)",
            code: .authRequired,
            exitCode: .graphqlExecutionError
        )
    }
    let data: Data
    do {
        if let tokenStoreJSON = credential.tokenStoreJSON {
            data = Data(tokenStoreJSON.utf8)
        } else {
            data = try Data(contentsOf: URL(fileURLWithPath: credential.tokenStorePath))
        }
        let tokenStore = try JSONDecoder().decode(GmailOAuthTokenStore.self, from: data)
        if tokenStore.accessMode != credential.accessMode {
            throw MailGatewayError(
                "Stored Gmail token scope does not match configured access mode",
                code: .authRequired,
                exitCode: .graphqlExecutionError
            )
        }
        return tokenStore
    } catch let error as MailGatewayError {
        throw error
    } catch {
        throw MailGatewayError(
            "Failed to read Gmail token store",
            code: .authRequired,
            exitCode: .graphqlExecutionError,
            details: ["cause": error.localizedDescription]
        )
    }
}

private func refreshGmailWriteAccessToken(
    credential: CredentialConfig,
    tokenStore: GmailOAuthTokenStore
) throws -> String {
    guard let refreshToken = nonBlank(tokenStore.refreshToken) else {
        throw MailGatewayError(
            "Stored Gmail access token is expired and has no refresh token",
            code: .authRequired,
            exitCode: .graphqlExecutionError
        )
    }
    let client = try loadGmailWriteOAuthClient(credential: credential)
    var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let body = [
        ("client_id", client.clientId),
        ("client_secret", client.clientSecret),
        ("refresh_token", refreshToken),
        ("grant_type", "refresh_token")
    ]
    request.httpBody = formURLEncoded(body).data(using: .utf8)
    let response = try performGmailWriteHTTPRequest(request, context: "Gmail token refresh failed")
    guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
          let accessToken = nonBlank(object["access_token"] as? String) else {
        throw MailGatewayError(
            "Gmail token refresh response did not include an access token",
            code: .authRequired,
            exitCode: .graphqlExecutionError
        )
    }
    let refreshed = GmailOAuthTokenStore(
        accessMode: tokenStore.accessMode,
        accessToken: accessToken,
        refreshToken: tokenStore.refreshToken,
        tokenType: object["token_type"] as? String ?? tokenStore.tokenType,
        scope: object["scope"] as? String ?? tokenStore.scope,
        expiresAt: gmailWriteInt(object["expires_in"]).map {
            ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval($0)))
        },
        emailAddress: tokenStore.emailAddress
    )
    try writeGmailWriteTokenStoreIfFileBacked(refreshed, credential: credential)
    return accessToken
}

private func writeGmailWriteTokenStoreIfFileBacked(
    _ tokenStore: GmailOAuthTokenStore,
    credential: CredentialConfig
) throws {
    guard credential.tokenStoreJSON == nil else {
        return
    }
    do {
        let data = try JSONEncoder().encode(tokenStore)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: credential.tokenStorePath).deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: URL(fileURLWithPath: credential.tokenStorePath), options: [.atomic])
    } catch {
        throw MailGatewayError(
            "Failed to write refreshed Gmail token store",
            code: .authRequired,
            exitCode: .graphqlExecutionError,
            details: ["cause": error.localizedDescription]
        )
    }
}

private struct GmailWriteOAuthClient: Decodable {
    let clientId: String
    let clientSecret: String

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case clientSecret = "client_secret"
    }
}

private struct GmailWriteOAuthClientFile: Decodable {
    let installed: GmailWriteOAuthClient?
    let web: GmailWriteOAuthClient?
}

private func loadGmailWriteOAuthClient(credential: CredentialConfig) throws -> GmailWriteOAuthClient {
    let data: Data
    do {
        if let oauthClientSecretJSON = credential.oauthClientSecretJSON {
            data = Data(oauthClientSecretJSON.utf8)
        } else {
            data = try Data(contentsOf: URL(fileURLWithPath: credential.oauthClientSecretPath))
        }
        let decoded = try JSONDecoder().decode(GmailWriteOAuthClientFile.self, from: data)
        if let client = decoded.installed ?? decoded.web {
            return client
        }
        throw MailGatewayError(
            "Gmail OAuth client JSON must contain installed or web credentials",
            code: .configInvalid,
            exitCode: .configurationError
        )
    } catch let error as MailGatewayError {
        throw error
    } catch {
        throw MailGatewayError(
            "Failed to read Gmail OAuth client JSON",
            code: .configInvalid,
            exitCode: .configurationError,
            details: ["cause": error.localizedDescription]
        )
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
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    let response = try performGmailWriteHTTPRequest(request, context: context)
    guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
        throw MailGatewayError(
            "Gmail API response was not a JSON object",
            code: .providerApiError,
            exitCode: .providerApiError
        )
    }
    return object
}

private func performGmailWriteHTTPRequest(_ request: URLRequest, context: String) throws -> (data: Data, response: HTTPURLResponse) {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<(Data, HTTPURLResponse), MailGatewayError>?
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        if let error {
            result = .failure(MailGatewayError(
                context,
                code: .providerApiError,
                exitCode: .providerApiError,
                details: ["cause": error.localizedDescription]
            ))
            return
        }
        guard let data,
              let httpResponse = response as? HTTPURLResponse else {
            result = .failure(MailGatewayError(
                "Gmail API response was empty",
                code: .providerApiError,
                exitCode: .providerApiError
            ))
            return
        }
        if httpResponse.statusCode == 429 {
            result = .failure(MailGatewayError(
                context,
                code: .providerRateLimited,
                exitCode: .providerApiError,
                details: ["statusCode": "\(httpResponse.statusCode)"]
            ))
            return
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            result = .failure(MailGatewayError(
                context,
                code: .providerApiError,
                exitCode: .providerApiError,
                details: [
                    "statusCode": "\(httpResponse.statusCode)",
                    "response": String(data: data, encoding: .utf8) ?? ""
                ]
            ))
            return
        }
        result = .success((data, httpResponse))
    }.resume()
    semaphore.wait()
    switch result {
    case .success(let value):
        return value
    case .failure(let error):
        throw error
    case .none:
        throw MailGatewayError(
            "Gmail API request did not complete",
            code: .providerApiError,
            exitCode: .providerApiError
        )
    }
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
    return base64URL(Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8))
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

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func formURLEncoded(_ fields: [(String, String)]) -> String {
    fields
        .map { key, value in
            "\(urlFormEncode(key))=\(urlFormEncode(value))"
        }
        .joined(separator: "&")
}

private func urlFormEncode(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private func gmailWriteInt(_ value: Any?) -> Int? {
    if let value = value as? Int {
        return value
    }
    if let value = value as? Double {
        return Int(value)
    }
    if let value = value as? String {
        return Int(value)
    }
    return nil
}
