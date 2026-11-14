import Foundation

struct GmailLiveReader {
    func searchThreads(
        account: AccountConfig,
        credential: CredentialConfig,
        query: String?,
        starred: Bool,
        direction: ThreadSearchDirection?,
        labelIds: [String]?,
        receivedAfter: String?,
        receivedBefore: String?,
        includeEdges: Bool,
        includeNodeDetails: Bool
    ) throws -> [String: Any] {
        let accessToken = try validAccessToken(credential: credential)
        let listed = try listMessages(
            account: account,
            accessToken: accessToken,
            query: query,
            starred: starred,
            direction: direction,
            labelIds: labelIds,
            receivedAfter: receivedAfter,
            receivedBefore: receivedBefore
        )
        let pageInfo: [String: Any] = [
            "hasNextPage": listed.nextPageToken != nil,
            "endCursor": listed.nextPageToken as Any? ?? NSNull()
        ]
        guard includeEdges else {
            return [
                "edges": [[String: Any]](),
                "pageInfo": pageInfo,
                "totalCount": listed.resultSizeEstimate ?? listed.messages.count
            ]
        }

        var seenThreads: Set<String> = []
        var edges: [[String: Any]] = []

        for item in listed.messages {
            guard !seenThreads.contains(item.threadId) else {
                continue
            }
            seenThreads.insert(item.threadId)
            var edge: [String: Any] = ["cursor": item.id]
            if includeNodeDetails {
                let message = try getMessageFull(messageId: item.id, account: account, accessToken: accessToken)
                edge["node"] = buildThread(account: account, threadId: item.threadId, messages: [message])
            }
            edges.append(edge)
        }

        return [
            "edges": edges,
            "pageInfo": pageInfo,
            "totalCount": listed.resultSizeEstimate ?? edges.count
        ]
    }

    func getThread(account: AccountConfig, credential: CredentialConfig, threadId: String) throws -> Any {
        let accessToken = try validAccessToken(credential: credential)
        var components = gmailURLComponents(path: "/gmail/v1/users/me/threads/\(urlPathEncode(threadId))")
        components.queryItems = fullQueryItems()
        let object = try getGmailJSONObject(
            components: components,
            accessToken: accessToken,
            context: "Gmail thread retrieval failed"
        )
        let messages = (object["messages"] as? [[String: Any]] ?? [])
            .map { buildMessage(account: account, object: $0) }
        return buildThread(account: account, threadId: threadId, messages: messages)
    }

    func getMessage(account: AccountConfig, credential: CredentialConfig, messageId: String) throws -> Any {
        let accessToken = try validAccessToken(credential: credential)
        return try getMessageFull(messageId: messageId, account: account, accessToken: accessToken)
    }

    func getAttachment(
        account: AccountConfig,
        credential: CredentialConfig,
        messageId: String,
        attachmentId: String
    ) throws -> Any {
        let accessToken = try validAccessToken(credential: credential)
        let message = try getMessageFull(messageId: messageId, account: account, accessToken: accessToken)
        let attachments = message["attachments"] as? [[String: Any]] ?? []
        let attachment = attachments.first(where: { item in
            guard let gmail = (item["providerMetadata"] as? [String: Any])?["gmail"] as? [String: Any] else {
                return item["id"] as? String == attachmentId
            }
            return gmail["attachmentId"] as? String == attachmentId || item["id"] as? String == attachmentId
        })

        var components = gmailURLComponents(
            path: "/gmail/v1/users/me/messages/\(urlPathEncode(messageId))/attachments/\(urlPathEncode(attachmentId))"
        )
        components.queryItems = nil
        let object = try getGmailJSONObject(
            components: components,
            accessToken: accessToken,
            context: "Gmail attachment retrieval failed"
        )
        let remoteSize = gmailInt(object["size"]) ?? nonBlank(object["data"] as? String)
            .flatMap(dataFromGmailBase64URLString)?
            .count
        let resolvedAttachment = attachment ?? remoteSize.flatMap { size in
            attachments.first { gmailInt($0["sizeBytes"]) == size }
        }

        var resolved = resolvedAttachment ?? [
            "id": attachmentId,
            "filename": NSNull(),
            "mimeType": "application/octet-stream",
            "sizeBytes": NSNull(),
            "localPath": NSNull(),
            "materializationState": AttachmentMaterializationState.notMaterialized.rawValue,
            "providerMetadata": [
                "gmail": [
                    "accountId": account.id,
                    "messageId": messageId,
                    "threadId": message["threadId"] as? String ?? "",
                    "attachmentId": attachmentId,
                    "partId": NSNull()
                ] as [String: Any]
            ]
        ]
        resolved["id"] = attachmentId
        resolved["messageId"] = messageId
        resolved["accountId"] = account.id
        if var providerMetadata = resolved["providerMetadata"] as? [String: Any],
           var gmailMetadata = providerMetadata["gmail"] as? [String: Any] {
            gmailMetadata["attachmentId"] = attachmentId
            providerMetadata["gmail"] = gmailMetadata
            resolved["providerMetadata"] = providerMetadata
        }
        if resolved["sizeBytes"] is NSNull,
           let remoteSize {
            resolved["sizeBytes"] = remoteSize
        }
        return resolved
    }
}

private struct GmailListedMessages {
    let messages: [GmailListedMessage]
    let nextPageToken: String?
    let resultSizeEstimate: Int?
}

private struct GmailListedMessage {
    let id: String
    let threadId: String
}

private struct GmailOAuthClientForRefresh: Decodable {
    let clientId: String
    let clientSecret: String?
    let tokenURI: String

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case clientSecret = "client_secret"
        case tokenURI = "token_uri"
    }
}

private struct GmailOAuthClientFileForRefresh: Decodable {
    let installed: GmailOAuthClientForRefresh?
}

private func validAccessToken(credential: CredentialConfig) throws -> String {
    let tokenStore = try loadTokenStore(credential: credential)
    if let expiresAt = tokenStore.expiresAt,
       let expiresAtDate = ISO8601DateFormatter().date(from: expiresAt),
       expiresAtDate <= Date().addingTimeInterval(60) {
        return try refreshAccessToken(credential: credential, tokenStore: tokenStore)
    }
    return tokenStore.accessToken
}

private func loadTokenStore(credential: CredentialConfig) throws -> GmailOAuthTokenStore {
    do {
        let data: Data
        if let tokenStoreJSON = credential.tokenStoreJSON {
            data = Data(tokenStoreJSON.utf8)
        } else {
            guard FileManager.default.isReadableFile(atPath: credential.tokenStorePath) else {
                throw MailGatewayError(
                    "Authentication is required before reading Gmail",
                    code: .authRequired,
                    exitCode: .graphqlExecutionError,
                    details: ["credentialId": credential.id, "tokenStorePath": credential.tokenStorePath]
                )
            }
            data = try Data(contentsOf: URL(fileURLWithPath: credential.tokenStorePath))
        }
        let tokenStore = try JSONDecoder().decode(GmailOAuthTokenStore.self, from: data)
        guard tokenStore.accessMode == credential.accessMode else {
            throw MailGatewayError(
                "Stored Gmail token scope does not match configured access mode",
                code: .authRequired,
                exitCode: .graphqlExecutionError,
                details: ["credentialId": credential.id]
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
            details: ["credentialId": credential.id, "cause": error.localizedDescription]
        )
    }
}

private func refreshAccessToken(credential: CredentialConfig, tokenStore: GmailOAuthTokenStore) throws -> String {
    guard let refreshToken = nonBlank(tokenStore.refreshToken) else {
        throw MailGatewayError(
            "Stored Gmail access token is expired and has no refresh token",
            code: .authRequired,
            exitCode: .graphqlExecutionError,
            details: ["credentialId": credential.id]
        )
    }
    let client = try loadOAuthClientForRefresh(credential: credential)
    guard let tokenURL = URL(string: client.tokenURI) else {
        throw MailGatewayError(
            "OAuth client token_uri is invalid",
            code: .configInvalid,
            exitCode: .configurationError,
            details: ["credentialId": credential.id]
        )
    }

    var fields = [
        ("client_id", client.clientId),
        ("grant_type", "refresh_token"),
        ("refresh_token", refreshToken)
    ]
    if let clientSecret = nonBlank(client.clientSecret) {
        fields.append(("client_secret", clientSecret))
    }

    var request = URLRequest(url: tokenURL)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formURLEncoded(fields).data(using: .utf8)
    let response = try performGmailHTTPRequest(request, context: "Gmail token refresh failed")
    guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
          let accessToken = nonBlank(object["access_token"] as? String) else {
        throw MailGatewayError(
            "Gmail token refresh response did not include an access token",
            code: .authRequired,
            exitCode: .graphqlExecutionError,
            details: ["credentialId": credential.id]
        )
    }

    let refreshed = GmailOAuthTokenStore(
        accessMode: tokenStore.accessMode,
        accessToken: accessToken,
        refreshToken: tokenStore.refreshToken,
        tokenType: nonBlank(object["token_type"] as? String) ?? tokenStore.tokenType,
        scope: nonBlank(object["scope"] as? String) ?? tokenStore.scope,
        expiresAt: gmailInt(object["expires_in"]).map {
            ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval($0)))
        },
        emailAddress: tokenStore.emailAddress
    )
    if credential.tokenStoreJSON == nil {
        try? writeRefreshedTokenStore(refreshed, to: credential.tokenStorePath)
    }
    return accessToken
}

private func loadOAuthClientForRefresh(credential: CredentialConfig) throws -> GmailOAuthClientForRefresh {
    do {
        let data: Data
        if let oauthClientSecretJSON = credential.oauthClientSecretJSON {
            data = Data(oauthClientSecretJSON.utf8)
        } else {
            data = try Data(contentsOf: URL(fileURLWithPath: credential.oauthClientSecretPath))
        }
        let decoded = try JSONDecoder().decode(GmailOAuthClientFileForRefresh.self, from: data)
        guard let installed = decoded.installed else {
            throw MailGatewayError(
                "OAuth client JSON must contain an installed desktop client",
                code: .configInvalid,
                exitCode: .configurationError,
                details: ["credentialId": credential.id]
            )
        }
        return installed
    } catch let error as MailGatewayError {
        throw error
    } catch {
        throw MailGatewayError(
            "Failed to read Gmail OAuth client JSON",
            code: .configInvalid,
            exitCode: .configurationError,
            details: ["credentialId": credential.id, "cause": error.localizedDescription]
        )
    }
}

private func writeRefreshedTokenStore(_ tokenStore: GmailOAuthTokenStore, to path: String) throws {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let data = try JSONEncoder().encode(tokenStore)
    try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
}

private func listMessages(
    account: AccountConfig,
    accessToken: String,
    query: String?,
    starred: Bool,
    direction: ThreadSearchDirection?,
    labelIds: [String]?,
    receivedAfter: String?,
    receivedBefore: String?
) throws -> GmailListedMessages {
    var components = gmailURLComponents(path: "/gmail/v1/users/me/messages")
    var queryItems = [
        URLQueryItem(name: "maxResults", value: "10")
    ]
    if let query = gmailMessageSearchQuery(
        query: query,
        starred: starred,
        direction: direction,
        receivedAfter: receivedAfter,
        receivedBefore: receivedBefore
    ) {
        queryItems.append(URLQueryItem(name: "q", value: query))
    }
    for labelId in gmailSearchLabelIds(account: account, explicitLabelIds: labelIds, direction: direction) {
        queryItems.append(URLQueryItem(name: "labelIds", value: labelId))
    }
    components.queryItems = queryItems
    let object = try getGmailJSONObject(
        components: components,
        accessToken: accessToken,
        context: "Gmail message list failed"
    )
    let messages = (object["messages"] as? [[String: Any]] ?? []).compactMap { item -> GmailListedMessage? in
        guard let id = nonBlank(item["id"] as? String),
              let threadId = nonBlank(item["threadId"] as? String) else {
            return nil
        }
        return GmailListedMessage(id: id, threadId: threadId)
    }
    return GmailListedMessages(
        messages: messages,
        nextPageToken: nonBlank(object["nextPageToken"] as? String),
        resultSizeEstimate: gmailInt(object["resultSizeEstimate"])
    )
}

private func gmailMessageSearchQuery(
    query: String?,
    starred: Bool,
    direction: ThreadSearchDirection?,
    receivedAfter: String?,
    receivedBefore: String?
) -> String? {
    var terms: [String] = []
    switch direction {
    case .sent:
        terms.append("in:sent")
    case .received:
        terms.append("-in:sent")
    case .all, nil:
        break
    }
    if let receivedAfter = gmailSearchDateTerm(prefix: "after", value: receivedAfter) {
        terms.append(receivedAfter)
    }
    if let receivedBefore = gmailSearchDateTerm(prefix: "before", value: receivedBefore) {
        terms.append(receivedBefore)
    }
    if starred {
        terms.append("is:starred")
    }
    if let query = nonBlank(query) {
        terms.append(query)
    }
    return nonBlank(terms.joined(separator: " "))
}

private func gmailSearchLabelIds(
    account: AccountConfig,
    explicitLabelIds: [String]?,
    direction: ThreadSearchDirection?
) -> [String] {
    if let explicitLabelIds {
        return explicitLabelIds.compactMap(nonBlank)
    }
    if direction == .sent {
        return []
    }
    return account.defaultLabelIds
}

private func gmailSearchDateTerm(prefix: String, value: String?) -> String? {
    guard let value = nonBlank(value) else {
        return nil
    }
    let normalized = value.replacingOccurrences(of: "-", with: "/")
    if normalized.count >= 10 {
        let endIndex = normalized.index(normalized.startIndex, offsetBy: 10)
        let date = String(normalized[..<endIndex])
        if isGmailSearchDate(date) {
            return "\(prefix):\(date)"
        }
    }
    return "\(prefix):\(normalized)"
}

private func isGmailSearchDate(_ value: String) -> Bool {
    let parts = value.split(separator: "/")
    guard parts.count == 3,
          parts[0].count == 4,
          parts[1].count == 2,
          parts[2].count == 2 else {
        return false
    }
    return parts.allSatisfy { part in part.allSatisfy(\.isNumber) }
}

private func getMessageFull(messageId: String, account: AccountConfig, accessToken: String) throws -> [String: Any] {
    var components = gmailURLComponents(path: "/gmail/v1/users/me/messages/\(urlPathEncode(messageId))")
    components.queryItems = fullQueryItems()
    let object = try getGmailJSONObject(
        components: components,
        accessToken: accessToken,
        context: "Gmail message retrieval failed"
    )
    return buildMessage(account: account, object: object)
}

private func getGmailJSONObject(
    components: URLComponents,
    accessToken: String,
    context: String
) throws -> [String: Any] {
    guard let url = components.url else {
        throw MailGatewayError(
            "Failed to construct Gmail API URL",
            code: .providerApiError,
            exitCode: .providerApiError
        )
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 30
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
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

private func performGmailHTTPRequest(_ request: URLRequest, context: String) throws -> (data: Data, response: HTTPURLResponse) {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<(Data, HTTPURLResponse), Error>?
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer {
            semaphore.signal()
        }
        if let error {
            result = .failure(error)
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
        result = .success((data, httpResponse))
    }.resume()
    semaphore.wait()

    let resolved: (data: Data, response: HTTPURLResponse)
    do {
        resolved = try result?.get() ?? {
            throw MailGatewayError(
                "Gmail API request did not complete",
                code: .providerApiError,
                exitCode: .providerApiError
            )
        }()
    } catch let error as MailGatewayError {
        throw error
    } catch {
        throw MailGatewayError(
            context,
            code: .providerApiError,
            exitCode: .providerApiError,
            details: ["cause": error.localizedDescription]
        )
    }

    guard (200..<300).contains(resolved.response.statusCode) else {
        let body = String(data: resolved.data, encoding: .utf8) ?? ""
        throw MailGatewayError(
            context,
            code: .providerApiError,
            exitCode: .providerApiError,
            details: ["httpStatus": String(resolved.response.statusCode), "body": String(body.prefix(1_000))]
        )
    }
    return resolved
}

private func buildThread(account: AccountConfig, threadId: String, messages: [[String: Any]]) -> [String: Any] {
    let labels = uniqueStrings(messages.flatMap { $0["labels"] as? [String] ?? [] })
    return [
        "id": threadId,
        "accountId": account.id,
        "subject": messages.first?["subject"] as? String ?? NSNull(),
        "snippet": messages.first?["snippet"] as? String ?? NSNull(),
        "messages": messages,
        "labels": labels,
        "providerMetadata": [
            "gmail": [
                "labelIds": labels,
                "historyId": messages.first?["historyId"] as? String ?? NSNull()
            ] as [String: Any]
        ]
    ]
}

private func buildMessage(account: AccountConfig, object: [String: Any]) -> [String: Any] {
    let headers = gmailHeaders(object)
    let labelIds = object["labelIds"] as? [String] ?? []
    let internalDate = nonBlank(object["internalDate"] as? String).flatMap(millisecondsDateString)
    let payload = object["payload"] as? [String: Any]
    let parsedPayload = payload.map(parseGmailPayload) ?? GmailParsedPayload()
    return [
        "id": object["id"] as? String ?? "",
        "threadId": object["threadId"] as? String ?? "",
        "accountId": account.id,
        "subject": headers["subject"] ?? NSNull(),
        "from": mailAddressList(headers["from"]),
        "to": mailAddressList(headers["to"]),
        "cc": mailAddressList(headers["cc"]),
        "bcc": mailAddressList(headers["bcc"]),
        "replyTo": mailAddressList(headers["reply-to"]),
        "sentAt": parseMailDate(headers["date"]) as Any? ?? internalDate as Any? ?? NSNull(),
        "receivedAt": internalDate as Any? ?? NSNull(),
        "snippet": object["snippet"] as? String ?? NSNull(),
        "textBody": parsedPayload.textBody as Any? ?? NSNull(),
        "htmlBody": parsedPayload.htmlBody as Any? ?? NSNull(),
        "attachments": parsedPayload.attachments.map { buildAttachment(account: account, message: object, part: $0) },
        "labels": labelIds,
        "historyId": object["historyId"] as? String ?? NSNull(),
        "providerMetadata": [
            "gmail": [
                "labelIds": labelIds,
                "historyId": object["historyId"] as? String ?? NSNull()
            ] as [String: Any]
        ]
    ]
}

private struct GmailParsedPayload {
    var textBody: String?
    var htmlBody: String?
    var attachments: [GmailAttachmentPart] = []
}

private struct GmailAttachmentPart {
    let id: String
    let attachmentId: String?
    let partId: String?
    let filename: String?
    let mimeType: String
    let sizeBytes: Int?
}

private func parseGmailPayload(_ payload: [String: Any]) -> GmailParsedPayload {
    var parsed = GmailParsedPayload()
    parseGmailPayloadPart(payload, parsed: &parsed)
    return parsed
}

private func parseGmailPayloadPart(_ payload: [String: Any], parsed: inout GmailParsedPayload) {
    let mimeType = nonBlank(payload["mimeType"] as? String)?.lowercased() ?? "application/octet-stream"
    let partId = nonBlank(payload["partId"] as? String)
    let filename = nonBlank(payload["filename"] as? String)
    let body = payload["body"] as? [String: Any] ?? [:]
    let attachmentId = nonBlank(body["attachmentId"] as? String)
    let sizeBytes = gmailInt(body["size"])
    let hasAttachmentMetadata = attachmentId != nil || filename != nil

    if hasAttachmentMetadata {
        let fallbackId = partId ?? filename ?? UUID().uuidString
        parsed.attachments.append(GmailAttachmentPart(
            id: attachmentId ?? fallbackId,
            attachmentId: attachmentId,
            partId: partId,
            filename: filename,
            mimeType: mimeType,
            sizeBytes: sizeBytes
        ))
    } else if let data = nonBlank(body["data"] as? String),
              let decoded = dataFromGmailBase64URLString(data),
              let string = String(data: decoded, encoding: .utf8) {
        if mimeType == "text/plain", parsed.textBody == nil {
            parsed.textBody = string
        } else if mimeType == "text/html", parsed.htmlBody == nil {
            parsed.htmlBody = string
        }
    }

    for part in payload["parts"] as? [[String: Any]] ?? [] {
        parseGmailPayloadPart(part, parsed: &parsed)
    }
}

private func buildAttachment(account: AccountConfig, message: [String: Any], part: GmailAttachmentPart) -> [String: Any] {
    [
        "id": part.id,
        "filename": part.filename as Any? ?? NSNull(),
        "mimeType": part.mimeType,
        "sizeBytes": part.sizeBytes as Any? ?? NSNull(),
        "localPath": NSNull(),
        "materializationState": AttachmentMaterializationState.notMaterialized.rawValue,
        "providerMetadata": [
            "gmail": [
                "accountId": account.id,
                "messageId": message["id"] as? String ?? "",
                "threadId": message["threadId"] as? String ?? "",
                "attachmentId": part.attachmentId as Any? ?? NSNull(),
                "partId": part.partId as Any? ?? NSNull()
            ] as [String: Any]
        ]
    ]
}

private func gmailHeaders(_ object: [String: Any]) -> [String: String] {
    guard let payload = object["payload"] as? [String: Any],
          let headers = payload["headers"] as? [[String: Any]] else {
        return [:]
    }
    var output: [String: String] = [:]
    for header in headers {
        guard let name = nonBlank(header["name"] as? String),
              let value = nonBlank(header["value"] as? String) else {
            continue
        }
        output[name.lowercased()] = value
    }
    return output
}

private func mailAddressList(_ value: String?) -> [[String: String]] {
    guard let value = nonBlank(value) else {
        return []
    }
    return value.split(separator: ",").map {
        ["raw": $0.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
}

private func parseMailDate(_ value: String?) -> String? {
    guard let value = nonBlank(value) else {
        return nil
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
    if let date = formatter.date(from: value) {
        return ISO8601DateFormatter().string(from: date)
    }
    return value
}

private func millisecondsDateString(_ value: String) -> String? {
    guard let milliseconds = Double(value) else {
        return nil
    }
    return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: milliseconds / 1_000))
}

private func fullQueryItems() -> [URLQueryItem] {
    [
        URLQueryItem(name: "format", value: "full")
    ]
}

private func gmailURLComponents(path: String) -> URLComponents {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "gmail.googleapis.com"
    components.path = path
    return components
}

private func formURLEncoded(_ fields: [(String, String)]) -> String {
    fields
        .map { key, value in
            "\(urlFormEncode(key))=\(urlFormEncode(value))"
        }
        .joined(separator: "&")
}

private func urlPathEncode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
}

private func urlFormEncode(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private func uniqueStrings(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var output: [String] = []
    for value in values where !seen.contains(value) {
        seen.insert(value)
        output.append(value)
    }
    return output
}

private func gmailInt(_ value: Any?) -> Int? {
    if let value = value as? Int {
        return value
    }
    if let value = value as? NSNumber {
        return value.intValue
    }
    if let value = value as? String {
        return Int(value)
    }
    return nil
}

private func dataFromGmailBase64URLString(_ value: String) -> Data? {
    var base64 = value
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let padding = (4 - base64.count % 4) % 4
    base64 += String(repeating: "=", count: padding)
    return Data(base64Encoded: base64)
}
