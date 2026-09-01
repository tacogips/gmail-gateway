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
            throw GmailGatewayError(
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

private func uniqueStrings(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var output: [String] = []
    for value in values where !seen.contains(value) {
        seen.insert(value)
        output.append(value)
    }
    return output
}
