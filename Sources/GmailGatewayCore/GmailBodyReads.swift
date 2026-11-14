import Foundation

private struct GmailBodyPartData: Decodable {
    let size: Int
    let data: String?
    let attachmentId: String?
}

extension GmailGatewayService {
    /// Explicit pipe-safe body access; message/thread retain their file-only contract.
    public func messageBodyBytes(accountId: String, messageId: String,
                                 maxBytes: Int = 2 * 1024 * 1024) throws -> [String: Any] {
        try GmailGatewayProviderCancellationContext.throwIfCancelled()
        guard validArchiveID(messageId), (1...(8 * 1024 * 1024)).contains(maxBytes) else {
            throw archiveArgumentError()
        }
        let account = try requireAccount(accountId)
        let credential = try requireCredential(account.credentialId)
        let token = try validGmailAccessToken(credential: credential, use: .read)
        var components = gmailURLComponents(path: "/gmail/v1/users/me/messages/\(messageId)")
        components.queryItems = [URLQueryItem(name: "format", value: "full")]
        let payload = try GmailBoundedRead.get(components, token: token, maximumBytes: 32 * 1024 * 1024)
        guard let message = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              message["id"] as? String == messageId, let root = message["payload"] as? [String: Any] else {
            throw bodyResponseError(.messageEnvelope)
        }
        let selected = try selectedBodyParts(root)
        var total = 0
        var parts: [[String: Any]] = []
        for part in selected {
            try GmailGatewayProviderCancellationContext.throwIfCancelled()
            guard let body = part["body"] as? [String: Any],
                  let encoded = try? JSONSerialization.data(withJSONObject: body),
                  let descriptor = try? JSONDecoder().decode(GmailBodyPartData.self, from: encoded),
                  descriptor.size >= 0 else { throw bodyResponseError(.bodyDescriptor) }
            guard descriptor.size <= maxBytes - total else { throw bodyLimitError() }
            let data: Data
            if let attachmentId = descriptor.attachmentId {
                guard validArchiveID(attachmentId), descriptor.data == nil else { throw bodyResponseError(.externalBodyDescriptor) }
                let endpoint = gmailURLComponents(path: "/gmail/v1/users/me/messages/\(messageId)/attachments/\(attachmentId)")
                let maximum = ((maxBytes - total + 2) / 3) * 4 + 65_536
                let response = try GmailBoundedRead.get(endpoint, token: token, maximumBytes: maximum)
                guard let remote = try? JSONDecoder().decode(GmailBodyPartData.self, from: response),
                      remote.attachmentId == nil, remote.size == descriptor.size else { throw bodyResponseError(.externalBodyResponse) }
                data = try decodeBody(remote, maximum: maxBytes - total)
            } else {
                data = try decodeBody(descriptor, maximum: maxBytes - total)
            }
            total += data.count
            parts.append(["partId": part["partId"] ?? "", "mimeType": (part["mimeType"] as? String)?.lowercased() ?? "",
                "charset": try bodyCharset(part) as Any? ?? NSNull(),
                "dataBase64": data.base64EncodedString(), "byteCount": data.count, "sha256": archiveSHA256(data)])
        }
        return ["accountId": account.id, "messageId": messageId, "complete": true,
                "byteCount": total, "parts": parts]
    }
}

private func selectedBodyParts(_ root: [String: Any]) throws -> [[String: Any]] {
    var stack: [([String: Any], Int)] = [(root, 0)]
    var result: [[String: Any]] = []
    var identities = Set<String>()
    var visited = 0
    while let (part, depth) = stack.popLast() {
        visited += 1
        guard depth <= 64, visited <= 10_000 else { throw bodyResponseError(.treeLimit) }
        if let filename = part["filename"] {
            guard let filename = filename as? String else { throw bodyResponseError(.filename) }
            if !filename.isEmpty { continue } // Attached files and their nested messages are separate originals.
        }
        guard let mime = part["mimeType"] as? String else { throw bodyResponseError(.mimeType) }
        if mime.lowercased() == "message/rfc822" { continue }
        if ["text/plain", "text/html"].contains(mime.lowercased()) {
            guard let identity = part["partId"] as? String, identity.utf8.count <= 4096,
                  identity.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
                  identities.insert(identity).inserted, result.count < 64 else { throw bodyResponseError(.partIdentity) }
            result.append(part)
        }
        if let children = part["parts"] {
            guard let children = children as? [[String: Any]], children.count <= 10_000 else { throw bodyResponseError(.children) }
            stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
    }
    return result
}

private func decodeBody(_ body: GmailBodyPartData, maximum: Int) throws -> Data {
    guard body.size >= 0, body.size <= maximum else { throw bodyLimitError() }
    if body.size == 0 && body.data == nil { return Data() }
    guard let encoded = body.data else { throw bodyResponseError(.missingData) }
    guard encoded.utf8.count <= ((maximum + 2) / 3) * 4 else { throw bodyLimitError() }
    guard let bytes = dataFromBase64URLString(encoded), bytes.count == body.size else { throw bodyResponseError(.decodedSize) }
    return bytes
}

private func bodyCharset(_ part: [String: Any]) throws -> String? {
    guard let raw = part["headers"] else { return nil }
    guard let headers = raw as? [[String: Any]], headers.count <= 1000 else { throw bodyResponseError(.headers) }
    let values = headers.filter { ($0["name"] as? String)?.lowercased() == "content-type" }
    guard values.count <= 1 else { throw bodyResponseError(.duplicateContentType) }
    guard let header = values.first else { return nil }
    guard let rawValue = header["value"] as? String else { throw bodyResponseError(.headerValue) }
    let value = try unfoldedBodyHeader(rawValue)
    let components = value.split(separator: ";", omittingEmptySubsequences: false)
    guard components.first?.trimmingCharacters(in: .whitespaces).lowercased() == (part["mimeType"] as? String)?.lowercased() else {
        throw bodyResponseError(.mimeMismatch)
    }
    let charsets = components.dropFirst().compactMap { field -> String? in
        let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard pair.first?.trimmingCharacters(in: .whitespaces).lowercased() == "charset" else { return nil }
        return pair.count == 2 ? String(pair[1]).trimmingCharacters(in: .whitespaces) : ""
    }
    guard charsets.count <= 1 else { throw bodyResponseError(.duplicateCharset) }
    guard var charset = charsets.first else { return nil }
    if charset.hasPrefix("\"") || charset.hasSuffix("\"") {
        guard charset.count >= 2, charset.hasPrefix("\""), charset.hasSuffix("\"") else { throw bodyResponseError(.charsetQuotes) }
        charset = String(charset.dropFirst().dropLast())
    }
    guard !charset.isEmpty, charset.utf8.count <= 64,
          charset.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 95, 46].contains($0) }) else {
        throw bodyResponseError(.charsetValue)
    }
    return charset
}

private func bodyLimitError() -> GmailGatewayError {
    GmailGatewayError("Message body exceeds byte limit", code: .resourceLimit, exitCode: .providerApiError)
}

// Closed codes only: never include message IDs, headers, body data or provider error text.
private enum BodyReadReason: String {
    case messageEnvelope, bodyDescriptor, externalBodyDescriptor, externalBodyResponse
    case treeLimit, filename, mimeType, partIdentity, children, missingData, decodedSize
    case headers, duplicateContentType, headerValue, mimeMismatch, duplicateCharset, charsetQuotes, charsetValue
}

private func bodyResponseError(_ reason: BodyReadReason) -> GmailGatewayError {
    GmailGatewayError("Invalid message body response [gmailBodyReason=\(reason.rawValue)]",
                      code: .providerApiError, exitCode: .providerApiError,
                      details: ["bodyReadReason": reason.rawValue])
}

/// RFC 5322 section 2.2.3: remove CRLF only when followed by SP or HTAB.
private func unfoldedBodyHeader(_ value: String) throws -> String {
    guard value.utf8.count <= 4096 else { throw bodyResponseError(.headerValue) }
    let bytes = Array(value.utf8)
    var result: [UInt8] = []
    var index = 0
    while index < bytes.count {
        let byte = bytes[index]
        if byte == 13 {
            guard index + 2 < bytes.count, bytes[index + 1] == 10,
                  bytes[index + 2] == 32 || bytes[index + 2] == 9 else { throw bodyResponseError(.headerValue) }
            index += 2
            continue
        }
        guard byte != 10, byte >= 32 || byte == 9, byte != 127 else { throw bodyResponseError(.headerValue) }
        result.append(byte)
        index += 1
    }
    guard let unfolded = String(bytes: result, encoding: .utf8) else { throw bodyResponseError(.headerValue) }
    return unfolded
}
