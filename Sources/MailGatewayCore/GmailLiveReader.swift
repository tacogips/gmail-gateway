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
        let accessToken = try validGmailAccessToken(credential: credential, use: .read)
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
        let accessToken = try validGmailAccessToken(credential: credential, use: .read)
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
        let accessToken = try validGmailAccessToken(credential: credential, use: .read)
        return try getMessageFull(messageId: messageId, account: account, accessToken: accessToken)
    }

    func getAttachment(
        account: AccountConfig,
        credential: CredentialConfig,
        messageId: String,
        attachmentId: String
    ) throws -> Any {
        let accessToken = try validGmailAccessToken(credential: credential, use: .read)
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
        let remoteSize = intValue(object["size"]) ?? nonBlank(object["data"] as? String)
            .flatMap(dataFromBase64URLString)?
            .count
        let resolvedAttachment = attachment ?? remoteSize.flatMap { size in
            attachments.first { intValue($0["sizeBytes"]) == size }
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
        resolved["downloadKey"] = attachmentDownloadKey(
            accountId: account.id,
            messageId: messageId,
            attachmentId: attachmentId,
            filename: resolved["filename"] as? String,
            mimeType: resolved["mimeType"] as? String
        ) as Any? ?? NSNull()
        return resolved
    }

    func getAttachmentPayload(
        credential: CredentialConfig,
        messageId: String,
        attachmentId: String
    ) throws -> Data {
        let accessToken = try validGmailAccessToken(credential: credential, use: .read)
        var components = gmailURLComponents(
            path: "/gmail/v1/users/me/messages/\(urlPathEncode(messageId))/attachments/\(urlPathEncode(attachmentId))"
        )
        components.queryItems = nil
        let object = try getGmailJSONObject(
            components: components,
            accessToken: accessToken,
            context: "Gmail attachment retrieval failed"
        )
        guard let encoded = nonBlank(object["data"] as? String),
              let data = dataFromBase64URLString(encoded) else {
            throw MailGatewayError(
                "Gmail attachment response did not include decodable payload data",
                code: .providerApiError,
                exitCode: .providerApiError
            )
        }
        return data
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
        resultSizeEstimate: intValue(object["resultSizeEstimate"])
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
    let sizeBytes = intValue(body["size"])
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
              let decoded = dataFromBase64URLString(data),
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
    let messageId = message["id"] as? String ?? ""
    return [
        "id": part.id,
        "filename": part.filename as Any? ?? NSNull(),
        "mimeType": part.mimeType,
        "sizeBytes": part.sizeBytes as Any? ?? NSNull(),
        "localPath": NSNull(),
        "downloadKey": attachmentDownloadKey(
            accountId: account.id,
            messageId: messageId,
            attachmentId: part.attachmentId,
            filename: part.filename,
            mimeType: part.mimeType
        ) as Any? ?? NSNull(),
        "materializationState": AttachmentMaterializationState.notMaterialized.rawValue,
        "providerMetadata": [
            "gmail": [
                "accountId": account.id,
                "messageId": messageId,
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

private func urlPathEncode(_ value: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")
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
