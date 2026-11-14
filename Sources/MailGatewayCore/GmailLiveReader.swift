import Foundation

struct GmailThreadSearchRequest {
    let account: AccountConfig
    let credential: CredentialConfig
    let query: String?
    let starred: Bool
    let direction: ThreadSearchDirection?
    let labelIds: [String]?
    let receivedAfter: String?
    let receivedBefore: String?
    let first: Int
    let after: String?
    let includeEdges: Bool
    let includeNodeDetails: Bool
    let includeFullNodeDetails: Bool
}

struct GmailMessageBodyFile {
    let kind: MessageMaterializedFileKind
    let filename: String
    let mimeType: String
    let data: Data
}

struct GmailLiveReader {
    func searchThreads(_ request: GmailThreadSearchRequest) throws -> MailThreadConnection {
        let accessToken = try validGmailAccessToken(credential: request.credential, use: .read)
        let listed = try listThreads(
            account: request.account,
            accessToken: accessToken,
            query: request.query,
            starred: request.starred,
            direction: request.direction,
            labelIds: request.labelIds,
            receivedAfter: request.receivedAfter,
            receivedBefore: request.receivedBefore,
            maxResults: request.first,
            pageToken: request.after
        )
        let pageInfo = MailPageInfo(hasNextPage: listed.nextPageToken != nil, endCursor: listed.nextPageToken)
        guard request.includeEdges else {
            return MailThreadConnection(
                edges: [],
                pageInfo: pageInfo,
                totalCount: listed.resultSizeEstimate ?? listed.threads.count
            )
        }

        var edges: [MailThreadEdge] = []

        for item in listed.threads {
            let node: MailThread?
            if request.includeNodeDetails {
                if request.includeFullNodeDetails {
                    node = try getThreadFull(threadId: item.id, account: request.account, accessToken: accessToken)
                } else {
                    node = buildListedThread(account: request.account, item: item)
                }
            } else {
                node = nil
            }
            edges.append(MailThreadEdge(cursor: item.id, node: node))
        }

        return MailThreadConnection(
            edges: edges,
            pageInfo: pageInfo,
            totalCount: listed.resultSizeEstimate ?? edges.count
        )
    }

    func getThread(account: AccountConfig, credential: CredentialConfig, threadId: String) throws -> MailThread {
        let accessToken = try validGmailAccessToken(credential: credential, use: .read)
        return try getThreadFull(threadId: threadId, account: account, accessToken: accessToken)
    }

    func getMessage(account: AccountConfig, credential: CredentialConfig, messageId: String) throws -> MailMessage {
        let accessToken = try validGmailAccessToken(credential: credential, use: .read)
        return try getMessageFull(messageId: messageId, account: account, accessToken: accessToken)
    }

    func getMessageBodyFiles(
        credential: CredentialConfig,
        messageId: String
    ) throws -> [GmailMessageBodyFile] {
        let accessToken = try validGmailAccessToken(credential: credential, use: .read)
        let object = try getGmailMessageObject(messageId: messageId, accessToken: accessToken)
        guard let payload = object.payload else {
            return []
        }
        return parseGmailBodyFiles(payload)
    }

    func getAttachment(
        account: AccountConfig,
        credential: CredentialConfig,
        messageId: String,
        attachmentId: String
    ) throws -> MailAttachment {
        let accessToken = try validGmailAccessToken(credential: credential, use: .read)
        let message = try getMessageFull(messageId: messageId, account: account, accessToken: accessToken)
        let attachment = message.attachments.first(where: { item in
            item.providerMetadata?.gmail?.attachmentId == attachmentId || item.id == attachmentId
        })

        let base = attachment ?? MailAttachment(
            id: attachmentId,
            accountId: account.id,
            messageId: messageId,
            filename: nil,
            mimeType: "application/octet-stream",
            sizeBytes: nil,
            localPath: nil,
            downloadKey: nil,
            materializationState: .notMaterialized,
            providerMetadata: MailProviderMetadata(gmail: GmailMailMetadata(
                accountId: account.id,
                messageId: messageId,
                threadId: message.threadId,
                attachmentId: attachmentId,
                partId: nil,
                labelIds: nil,
                historyId: nil
            ))
        )
        return MailAttachment(
            id: attachmentId,
            accountId: account.id,
            messageId: messageId,
            filename: base.filename,
            mimeType: base.mimeType,
            sizeBytes: base.sizeBytes,
            localPath: base.localPath,
            downloadKey: attachmentDownloadKey(
                accountId: account.id,
                messageId: messageId,
                attachmentId: attachmentId,
                filename: base.filename,
                mimeType: base.mimeType
            ),
            materializationState: base.materializationState,
            providerMetadata: MailProviderMetadata(gmail: GmailMailMetadata(
                accountId: account.id,
                messageId: messageId,
                threadId: message.threadId,
                attachmentId: attachmentId,
                partId: base.providerMetadata?.gmail?.partId,
                labelIds: nil,
                historyId: nil
            ))
        )
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
        let object = try getGmailObject(
            components: components,
            accessToken: accessToken,
            context: "Gmail attachment retrieval failed",
            as: GmailAttachmentPayloadResponse.self
        )
        guard let encoded = nonBlank(object.data),
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

private struct GmailListedThreads {
    let threads: [GmailListedThread]
    let nextPageToken: String?
    let resultSizeEstimate: Int?
}

private struct GmailListedThread {
    let id: String
    let snippet: String?
    let historyId: String?
}

private func listThreads(
    account: AccountConfig,
    accessToken: String,
    query: String?,
    starred: Bool,
    direction: ThreadSearchDirection?,
    labelIds: [String]?,
    receivedAfter: String?,
    receivedBefore: String?,
    maxResults: Int,
    pageToken: String?
) throws -> GmailListedThreads {
    var components = gmailURLComponents(path: "/gmail/v1/users/me/threads")
    var queryItems = [
        URLQueryItem(name: "maxResults", value: String(maxResults))
    ]
    if let pageToken {
        queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
    }
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
    let object = try getGmailObject(
        components: components,
        accessToken: accessToken,
        context: "Gmail thread list failed",
        as: GmailThreadListResponse.self
    )
    let threads = (object.threads ?? []).compactMap { item -> GmailListedThread? in
        guard let id = nonBlank(item.id) else {
            return nil
        }
        return GmailListedThread(
            id: id,
            snippet: nonBlank(item.snippet),
            historyId: nonBlank(item.historyId)
        )
    }
    return GmailListedThreads(
        threads: threads,
        nextPageToken: nonBlank(object.nextPageToken),
        resultSizeEstimate: object.resultSizeEstimate
    )
}

private func buildListedThread(account: AccountConfig, item: GmailListedThread) -> MailThread {
    MailThread(
        id: item.id,
        accountId: account.id,
        subject: nil,
        snippet: item.snippet,
        messages: [],
        labels: [],
        providerMetadata: MailProviderMetadata(gmail: GmailMailMetadata(
            accountId: nil,
            messageId: nil,
            threadId: nil,
            attachmentId: nil,
            partId: nil,
            labelIds: [],
            historyId: item.historyId
        ))
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
    if value.contains("T"),
       let date = parseISO8601SearchDate(value) {
        return "\(prefix):\(Int(date.timeIntervalSince1970))"
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

private func parseISO8601SearchDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
        return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
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

private func getMessageFull(messageId: String, account: AccountConfig, accessToken: String) throws -> MailMessage {
    let object = try getGmailMessageObject(messageId: messageId, accessToken: accessToken)
    return buildMailMessage(account: account, object: object)
}

private func getThreadFull(threadId: String, account: AccountConfig, accessToken: String) throws -> MailThread {
    var components = gmailURLComponents(path: "/gmail/v1/users/me/threads/\(urlPathEncode(threadId))")
    components.queryItems = fullQueryItems()
    let object = try getGmailObject(
        components: components,
        accessToken: accessToken,
        context: "Gmail thread retrieval failed",
        as: GmailAPIThread.self
    )
    let messages = (object.messages ?? [])
        .map { buildMailMessage(account: account, object: $0) }
    return buildThread(account: account, threadId: object.id ?? threadId, messages: messages)
}

private func getGmailMessageObject(messageId: String, accessToken: String) throws -> GmailAPIMessage {
    var components = gmailURLComponents(path: "/gmail/v1/users/me/messages/\(urlPathEncode(messageId))")
    components.queryItems = fullQueryItems()
    return try getGmailObject(
        components: components,
        accessToken: accessToken,
        context: "Gmail message retrieval failed",
        as: GmailAPIMessage.self
    )
}

private func getGmailObject<T: Decodable>(
    components: URLComponents,
    accessToken: String,
    context: String,
    as type: T.Type
) throws -> T {
    let data = try getGmailData(components: components, accessToken: accessToken, context: context)
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch {
        throw MailGatewayError(
            "Gmail API response was not a JSON object",
            code: .providerApiError,
            exitCode: .providerApiError
        )
    }
}

private func getGmailData(
    components: URLComponents,
    accessToken: String,
    context: String
) throws -> Data {
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
    return response.data
}

private func buildThread(account: AccountConfig, threadId: String, messages: [MailMessage]) -> MailThread {
    let labels = uniqueStrings(messages.flatMap(\.labels))
    return MailThread(
        id: threadId,
        accountId: account.id,
        subject: messages.first?.subject,
        snippet: messages.first?.snippet,
        messages: messages,
        labels: labels,
        providerMetadata: MailProviderMetadata(gmail: GmailMailMetadata(
            accountId: nil,
            messageId: nil,
            threadId: nil,
            attachmentId: nil,
            partId: nil,
            labelIds: labels,
            historyId: messages.first?.historyId
        ))
    )
}

func buildMessage(account: AccountConfig, object: [String: Any]) -> [String: Any] {
    buildMailMessage(account: account, object: object).graphQLObject()
}

private func buildMailMessage(account: AccountConfig, object: [String: Any]) -> MailMessage {
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
        ))
    )
}

private func buildMailMessage(account: AccountConfig, object: GmailAPIMessage) -> MailMessage {
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
        ))
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

private func parseGmailBodyFiles(_ payload: [String: Any]) -> [GmailMessageBodyFile] {
    var files: [GmailMessageBodyFile] = []
    parseGmailBodyFilePart(payload, files: &files)
    return files
}

private func parseGmailBodyFiles(_ payload: GmailAPIPayload) -> [GmailMessageBodyFile] {
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

private func fullQueryItems() -> [URLQueryItem] {
    [
        URLQueryItem(name: "format", value: "full")
    ]
}

func gmailURLComponents(path: String) -> URLComponents {
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
