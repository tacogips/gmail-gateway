import CryptoKit
import Foundation

private struct GmailArchiveCursor: Codable {
    let version: Int
    let binding: String
    let token: String
}

private struct GmailMessageIDList: Decodable {
    struct Message: Decodable { let id: String; let threadId: String }
    let messages: [Message]?
    let nextPageToken: String?
    let resultSizeEstimate: Int?
}

private struct GmailArchiveAttachment: Decodable {
    let size: Int
    let data: String
}

extension GmailGatewayService {
    /// List message identities only; never fetch bodies or apply thread/default-label filters.
    public func messageIds(accountId: String, query: String, first: Int = 50, after: String? = nil,
                           includeSpamTrash: Bool = false) throws -> [String: Any] {
        try GmailGatewayProviderCancellationContext.throwIfCancelled()
        guard (1...100).contains(first), query.utf8.count <= 4096,
              !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw archiveArgumentError()
        }
        let account = try requireAccount(accountId)
        let bindingData = try JSONEncoder().encode([account.id, account.emailAddress, account.credentialId,
            account.provider.rawValue, query, String(first), String(includeSpamTrash)])
        let binding = archiveSHA256(bindingData)
        var pageToken: String?
        if let after {
            guard after.utf8.count <= 16_384, let encoded = Data(base64Encoded: after),
                  let cursor = try? JSONDecoder().decode(GmailArchiveCursor.self, from: encoded),
                  cursor.version == 1, cursor.binding == binding, validArchiveToken(cursor.token) else {
                throw archiveArgumentError()
            }
            pageToken = cursor.token
        }
        let credential = try requireCredential(account.credentialId)
        let token = try validGmailAccessToken(credential: credential, use: .read)
        var components = gmailURLComponents(path: "/gmail/v1/users/me/messages")
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "maxResults", value: String(first)),
            URLQueryItem(name: "includeSpamTrash", value: String(includeSpamTrash))]
        if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        let payload = try GmailBoundedRead.get(components, token: token, maximumBytes: 1_048_576)
        guard let listed = try? JSONDecoder().decode(GmailMessageIDList.self, from: payload) else { throw archiveResponseError() }
        let messages = listed.messages ?? []
        guard messages.count <= first, Set(messages.map(\.id)).count == messages.count,
              messages.allSatisfy({ validArchiveID($0.id) && validArchiveID($0.threadId) }),
              listed.resultSizeEstimate.map({ $0 >= 0 }) ?? true else { throw archiveResponseError() }
        var cursor: String?
        if let next = listed.nextPageToken {
            guard validArchiveToken(next), next != pageToken else { throw archiveResponseError() }
            cursor = try JSONEncoder().encode(GmailArchiveCursor(version: 1, binding: binding, token: next)).base64EncodedString()
        }
        return ["messages": messages.map { ["id": $0.id, "threadId": $0.threadId] },
                "pageInfo": ["hasNextPage": cursor != nil, "endCursor": cursor as Any? ?? NSNull()],
                "resultSizeEstimate": listed.resultSizeEstimate as Any? ?? NSNull()]
    }

    /// Read only an explicitly identified inline filename part; never reinterpret it as an attachment ID.
    public func messagePartBytes(accountId: String, messageId: String, partId: String,
                                 maxBytes: Int = 20 * 1024 * 1024) throws -> [String: Any] {
        try GmailGatewayProviderCancellationContext.throwIfCancelled()
        guard (1...(20 * 1024 * 1024)).contains(maxBytes), validArchiveID(messageId),
              partId.utf8.count <= 4096,
              partId.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else { throw archiveArgumentError() }
        let account = try requireAccount(accountId)
        let credential = try requireCredential(account.credentialId)
        let token = try validGmailAccessToken(credential: credential, use: .read)
        var components = gmailURLComponents(path: "/gmail/v1/users/me/messages/\(messageId)")
        components.queryItems = [URLQueryItem(name: "format", value: "full")]
        let payload = try GmailBoundedRead.get(components, token: token, maximumBytes: 32 * 1024 * 1024)
        guard let message = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              message["id"] as? String == messageId, let root = message["payload"] as? [String: Any] else {
            throw archiveResponseError()
        }
        var stack: [([String: Any], Int)] = [(root, 0)]
        var matches: [[String: Any]] = []
        var visited = 0
        while let (part, depth) = stack.popLast() {
            visited += 1
            guard depth <= 64, visited <= 10_000 else { throw archiveResponseError() }
            if part["partId"] as? String == partId { matches.append(part) }
            if let children = part["parts"] {
                guard let children = children as? [[String: Any]], children.count <= 10_000 else { throw archiveResponseError() }
                stack.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        guard matches.count == 1, let part = matches.first,
              let filename = part["filename"] as? String, !filename.isEmpty,
              let body = part["body"] as? [String: Any], body["attachmentId"] == nil,
              let encoded = try? JSONSerialization.data(withJSONObject: body),
              let attachment = try? JSONDecoder().decode(GmailArchiveAttachment.self, from: encoded),
              attachment.size >= 0 else { throw archiveResponseError() }
        let encodedLimit = ((maxBytes + 2) / 3) * 4
        guard attachment.size <= maxBytes, attachment.data.utf8.count <= encodedLimit else {
            throw GmailGatewayError("Attachment exceeds byte limit", code: .resourceLimit, exitCode: .providerApiError)
        }
        guard let bytes = dataFromBase64URLString(attachment.data), bytes.count == attachment.size else {
            throw archiveResponseError()
        }
        return ["accountId": account.id, "messageId": messageId, "partId": partId,
                "dataBase64": bytes.base64EncodedString(), "byteCount": bytes.count, "sha256": archiveSHA256(bytes)]
    }

    /// Raw bytes stay in memory for the caller's isolated inspection boundary.
    public func attachmentBytes(accountId: String, messageId: String, attachmentId: String,
                                maxBytes: Int = 20 * 1024 * 1024) throws -> [String: Any] {
        try GmailGatewayProviderCancellationContext.throwIfCancelled()
        guard (1...(20 * 1024 * 1024)).contains(maxBytes), validArchiveID(messageId), validArchiveID(attachmentId) else {
            throw archiveArgumentError()
        }
        let account = try requireAccount(accountId)
        let credential = try requireCredential(account.credentialId)
        let token = try validGmailAccessToken(credential: credential, use: .read)
        let components = gmailURLComponents(path: "/gmail/v1/users/me/messages/\(messageId)/attachments/\(attachmentId)")
        let encodedLimit = ((maxBytes + 2) / 3) * 4
        let payload = try GmailBoundedRead.get(components, token: token, maximumBytes: encodedLimit + 65_536)
        guard let attachment = try? JSONDecoder().decode(GmailArchiveAttachment.self, from: payload),
              attachment.size >= 0 else { throw archiveResponseError() }
        guard attachment.size <= maxBytes, attachment.data.utf8.count <= encodedLimit else {
            throw GmailGatewayError("Attachment exceeds byte limit", code: .resourceLimit, exitCode: .providerApiError)
        }
        guard let bytes = dataFromBase64URLString(attachment.data), bytes.count == attachment.size,
              bytes.count <= maxBytes else { throw archiveResponseError() }
        return ["accountId": account.id, "messageId": messageId, "attachmentId": attachmentId,
                "dataBase64": bytes.base64EncodedString(), "byteCount": bytes.count, "sha256": archiveSHA256(bytes)]
    }
}

private func archiveSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func validArchiveID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 4096 && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
    }
}

private func validArchiveToken(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 8192 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
}

private func archiveArgumentError() -> GmailGatewayError {
    GmailGatewayError("Invalid archive read arguments or cursor binding", code: .invalidArgument, exitCode: .graphqlExecutionError)
}

private func archiveResponseError() -> GmailGatewayError {
    GmailGatewayError("Invalid archive read response", code: .providerApiError, exitCode: .providerApiError)
}
