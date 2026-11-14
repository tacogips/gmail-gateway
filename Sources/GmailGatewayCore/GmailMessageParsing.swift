import Foundation

func buildMessage(account: AccountConfig, object: [String: Any]) -> [String: Any] {
    buildMailMessage(account: account, object: object).graphQLObject()
}

func buildMailMessage(account: AccountConfig, object: [String: Any]) -> MailMessage {
    let headers = gmailHeaders(object)
    let labelIds = object["labelIds"] as? [String] ?? []
    let internalDate = nonBlank(object["internalDate"] as? String).flatMap(millisecondsDateString)
    let payload = object["payload"] as? [String: Any]
    let parsedPayload = payload.map(parseGmailPayload) ?? GmailParsedPayload()
    let messageId = object["id"] as? String ?? ""
    let threadId = object["threadId"] as? String ?? ""
    return MailMessage(
        id: messageId,
        threadId: threadId,
        accountId: account.id,
        subject: headers["subject"],
        from: mailAddressList(headers["from"]),
        to: mailAddressList(headers["to"]),
        cc: mailAddressList(headers["cc"]),
        bcc: mailAddressList(headers["bcc"]),
        replyTo: mailAddressList(headers["reply-to"]),
        sentAt: parseMailDate(headers["date"]) ?? internalDate,
        receivedAt: internalDate,
        snippet: object["snippet"] as? String,
        attachments: parsedPayload.attachments.map {
            buildAttachment(account: account, messageId: messageId, threadId: threadId, part: $0)
        },
        labels: labelIds,
        historyId: object["historyId"] as? String,
        providerMetadata: MailProviderMetadata(gmail: GmailMailMetadata(
            accountId: nil,
            messageId: nil,
            threadId: nil,
            attachmentId: nil,
            partId: nil,
            labelIds: labelIds,
            historyId: object["historyId"] as? String
        )),
        rfc822MessageId: nonBlank(headers["message-id"]),
        referencesHeader: nonBlank(headers["references"]),
        inReplyToHeader: nonBlank(headers["in-reply-to"])
    )
}

func buildMailMessage(account: AccountConfig, object: GmailAPIMessage) -> MailMessage {
    let headers = gmailHeaders(object)
    let labelIds = object.labelIds ?? []
    let internalDate = nonBlank(object.internalDate).flatMap(millisecondsDateString)
    let parsedPayload = object.payload.map(parseGmailPayload) ?? GmailParsedPayload()
    let messageId = object.id ?? ""
    let threadId = object.threadId ?? ""
    return MailMessage(
        id: messageId,
        threadId: threadId,
        accountId: account.id,
        subject: headers["subject"],
        from: mailAddressList(headers["from"]),
        to: mailAddressList(headers["to"]),
        cc: mailAddressList(headers["cc"]),
        bcc: mailAddressList(headers["bcc"]),
        replyTo: mailAddressList(headers["reply-to"]),
        sentAt: parseMailDate(headers["date"]) ?? internalDate,
        receivedAt: internalDate,
        snippet: object.snippet,
        attachments: parsedPayload.attachments.map {
            buildAttachment(account: account, messageId: messageId, threadId: threadId, part: $0)
        },
        labels: labelIds,
        historyId: object.historyId,
        providerMetadata: MailProviderMetadata(gmail: GmailMailMetadata(
            accountId: nil,
            messageId: nil,
            threadId: nil,
            attachmentId: nil,
            partId: nil,
            labelIds: labelIds,
            historyId: object.historyId
        )),
        rfc822MessageId: nonBlank(headers["message-id"]),
        referencesHeader: nonBlank(headers["references"]),
        inReplyToHeader: nonBlank(headers["in-reply-to"])
    )
}

private struct GmailParsedPayload {
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

private func parseGmailPayload(_ payload: GmailAPIPayload) -> GmailParsedPayload {
    var parsed = GmailParsedPayload()
    parseGmailPayloadPart(payload, parsed: &parsed)
    return parsed
}

func parseGmailBodyFiles(_ payload: [String: Any]) -> [GmailMessageBodyFile] {
    var files: [GmailMessageBodyFile] = []
    parseGmailBodyFilePart(payload, files: &files)
    return files
}

func parseGmailBodyFiles(_ payload: GmailAPIPayload) -> [GmailMessageBodyFile] {
    var files: [GmailMessageBodyFile] = []
    parseGmailBodyFilePart(payload, files: &files)
    return files
}

private func parseGmailBodyFilePart(_ payload: [String: Any], files: inout [GmailMessageBodyFile]) {
    let mimeType = nonBlank(payload["mimeType"] as? String)?.lowercased() ?? "application/octet-stream"
    let body = payload["body"] as? [String: Any] ?? [:]
    if let kind = messageBodyKind(for: mimeType),
       !files.contains(where: { $0.kind == kind }),
       let encoded = nonBlank(body["data"] as? String),
       let data = dataFromBase64URLString(encoded) {
        files.append(GmailMessageBodyFile(
            kind: kind,
            filename: filename(for: kind),
            mimeType: mimeType,
            data: data
        ))
    }

    for part in payload["parts"] as? [[String: Any]] ?? [] {
        parseGmailBodyFilePart(part, files: &files)
    }
}

private func parseGmailBodyFilePart(_ payload: GmailAPIPayload, files: inout [GmailMessageBodyFile]) {
    let mimeType = nonBlank(payload.mimeType)?.lowercased() ?? "application/octet-stream"
    let body = payload.body
    if let kind = messageBodyKind(for: mimeType),
       !files.contains(where: { $0.kind == kind }),
       let encoded = nonBlank(body?.data),
       let data = dataFromBase64URLString(encoded) {
        files.append(GmailMessageBodyFile(
            kind: kind,
            filename: filename(for: kind),
            mimeType: mimeType,
            data: data
        ))
    }

    for part in payload.parts ?? [] {
        parseGmailBodyFilePart(part, files: &files)
    }
}

private func messageBodyKind(for mimeType: String) -> MessageMaterializedFileKind? {
    switch mimeType {
    case "text/plain":
        return .bodyText
    case "text/html":
        return .bodyHTML
    default:
        return nil
    }
}

private func filename(for kind: MessageMaterializedFileKind) -> String {
    switch kind {
    case .bodyText:
        return "body.txt"
    case .bodyHTML:
        return "body.html"
    case .attachment, .temporaryFile:
        return "body"
    }
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
    }

    for part in payload["parts"] as? [[String: Any]] ?? [] {
        parseGmailPayloadPart(part, parsed: &parsed)
    }
}

private func parseGmailPayloadPart(_ payload: GmailAPIPayload, parsed: inout GmailParsedPayload) {
    let mimeType = nonBlank(payload.mimeType)?.lowercased() ?? "application/octet-stream"
    let partId = nonBlank(payload.partId)
    let filename = nonBlank(payload.filename)
    let body = payload.body
    let attachmentId = nonBlank(body?.attachmentId)
    let sizeBytes = body?.size
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
    }

    for part in payload.parts ?? [] {
        parseGmailPayloadPart(part, parsed: &parsed)
    }
}

private func buildAttachment(
    account: AccountConfig,
    messageId: String,
    threadId: String,
    part: GmailAttachmentPart
) -> MailAttachment {
    MailAttachment(
        id: part.id,
        accountId: nil,
        messageId: nil,
        filename: part.filename,
        mimeType: part.mimeType,
        sizeBytes: part.sizeBytes,
        localPath: nil,
        downloadKey: attachmentDownloadKey(
            accountId: account.id,
            messageId: messageId,
            attachmentId: part.attachmentId,
            filename: part.filename,
            mimeType: part.mimeType
        ),
        materializationState: .notMaterialized,
        providerMetadata: MailProviderMetadata(gmail: GmailMailMetadata(
            accountId: account.id,
            messageId: messageId,
            threadId: threadId,
            attachmentId: part.attachmentId,
            partId: part.partId,
            labelIds: nil,
            historyId: nil
        ))
    )
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

private func gmailHeaders(_ object: GmailAPIMessage) -> [String: String] {
    var output: [String: String] = [:]
    for header in object.payload?.headers ?? [] {
        guard let name = nonBlank(header.name),
              let value = nonBlank(header.value) else {
            continue
        }
        output[name.lowercased()] = value
    }
    return output
}

private func mailAddressList(_ value: String?) -> [MailAddress] {
    guard let value = nonBlank(value) else {
        return []
    }
    return splitMailAddressList(value).map {
        MailAddress(raw: $0)
    }
}

private func splitMailAddressList(_ value: String) -> [String] {
    var addresses: [String] = []
    var current = ""
    var inQuotedString = false
    var escaping = false
    for character in value {
        if escaping {
            current.append(character)
            escaping = false
            continue
        }
        if character == "\\" {
            current.append(character)
            escaping = true
            continue
        }
        if character == "\"" {
            current.append(character)
            inQuotedString.toggle()
            continue
        }
        if character == ",",
           !inQuotedString {
            if let address = nonBlank(current) {
                addresses.append(address)
            }
            current = ""
            continue
        }
        current.append(character)
    }
    if let address = nonBlank(current) {
        addresses.append(address)
    }
    return addresses
}

private func parseMailDate(_ value: String?) -> String? {
    guard let value = nonBlank(value) else {
        return nil
    }
    for dateFormat in [
        "EEE, d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "d MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss zzz"
    ] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = dateFormat
        if let date = formatter.date(from: value) {
            return ISO8601DateFormatter().string(from: date)
        }
    }
    return nil
}

private func millisecondsDateString(_ value: String) -> String? {
    guard let milliseconds = Double(value) else {
        return nil
    }
    return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: milliseconds / 1_000))
}
