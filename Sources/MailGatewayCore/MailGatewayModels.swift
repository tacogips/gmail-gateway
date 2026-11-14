import Foundation

struct MailThreadConnection: Codable {
    let edges: [MailThreadEdge]
    let pageInfo: MailPageInfo
    let totalCount: Int

    func graphQLObject() -> [String: Any] {
        [
            "edges": edges.map { $0.graphQLObject() },
            "pageInfo": pageInfo.graphQLObject(),
            "totalCount": totalCount
        ]
    }
}

struct MailThreadEdge: Codable {
    let cursor: String
    let node: MailThread?

    func graphQLObject() -> [String: Any] {
        var object: [String: Any] = ["cursor": cursor]
        if let node {
            object["node"] = node.graphQLObject()
        }
        return object
    }
}

struct MailPageInfo: Codable {
    let hasNextPage: Bool
    let endCursor: String?

    func graphQLObject() -> [String: Any] {
        [
            "hasNextPage": hasNextPage,
            "endCursor": endCursor as Any? ?? NSNull()
        ]
    }
}

struct MailThread: Codable {
    let id: String
    let accountId: String
    let subject: String?
    let snippet: String?
    let messages: [MailMessage]
    let labels: [String]
    let providerMetadata: MailProviderMetadata?

    func graphQLObject() -> [String: Any] {
        [
            "id": id,
            "accountId": accountId,
            "subject": subject as Any? ?? NSNull(),
            "snippet": snippet as Any? ?? NSNull(),
            "messages": messages.map { $0.graphQLObject() },
            "labels": labels,
            "providerMetadata": providerMetadata?.graphQLObject() as Any? ?? NSNull()
        ]
    }
}

struct MailMessage: Codable {
    let id: String
    let threadId: String
    let accountId: String
    let subject: String?
    let from: [MailAddress]
    let to: [MailAddress]
    let cc: [MailAddress]
    let bcc: [MailAddress]
    let replyTo: [MailAddress]
    let sentAt: String?
    let receivedAt: String?
    let snippet: String?
    let attachments: [MailAttachment]
    let labels: [String]
    let historyId: String?
    let providerMetadata: MailProviderMetadata?

    func graphQLObject() -> [String: Any] {
        [
            "id": id,
            "threadId": threadId,
            "accountId": accountId,
            "subject": subject as Any? ?? NSNull(),
            "from": from.map { $0.graphQLObject() },
            "to": to.map { $0.graphQLObject() },
            "cc": cc.map { $0.graphQLObject() },
            "bcc": bcc.map { $0.graphQLObject() },
            "replyTo": replyTo.map { $0.graphQLObject() },
            "sentAt": sentAt as Any? ?? NSNull(),
            "receivedAt": receivedAt as Any? ?? NSNull(),
            "snippet": snippet as Any? ?? NSNull(),
            "textBody": NSNull(),
            "htmlBody": NSNull(),
            "attachments": attachments.map { $0.graphQLObject() },
            "labels": labels,
            "historyId": historyId as Any? ?? NSNull(),
            "providerMetadata": providerMetadata?.graphQLObject() as Any? ?? NSNull()
        ]
    }
}

struct MailAddress: Codable {
    let raw: String

    func graphQLObject() -> [String: String] {
        ["raw": raw]
    }
}

struct MailAttachment: Codable {
    let id: String
    let accountId: String?
    let messageId: String?
    let filename: String?
    let mimeType: String
    let sizeBytes: Int?
    let localPath: String?
    let downloadKey: String?
    let materializationState: AttachmentMaterializationState
    let providerMetadata: MailProviderMetadata?

    func graphQLObject() -> [String: Any] {
        var object: [String: Any] = [
            "id": id,
            "filename": filename as Any? ?? NSNull(),
            "mimeType": mimeType,
            "sizeBytes": sizeBytes as Any? ?? NSNull(),
            "localPath": localPath as Any? ?? NSNull(),
            "downloadKey": downloadKey as Any? ?? NSNull(),
            "materializationState": materializationState.rawValue
        ]
        if let accountId {
            object["accountId"] = accountId
        }
        if let messageId {
            object["messageId"] = messageId
        }
        if let providerMetadata {
            object["providerMetadata"] = providerMetadata.graphQLObject()
        }
        return object
    }
}

struct MailProviderMetadata: Codable {
    let gmail: GmailMailMetadata?

    func graphQLObject() -> [String: Any] {
        ["gmail": gmail?.graphQLObject() as Any? ?? NSNull()]
    }
}

struct GmailMailMetadata: Codable {
    let accountId: String?
    let messageId: String?
    let threadId: String?
    let attachmentId: String?
    let partId: String?
    let labelIds: [String]?
    let historyId: String?

    func graphQLObject() -> [String: Any] {
        var object: [String: Any] = [:]
        if let accountId {
            object["accountId"] = accountId
        }
        if let messageId {
            object["messageId"] = messageId
        }
        if let threadId {
            object["threadId"] = threadId
        }
        if let attachmentId {
            object["attachmentId"] = attachmentId
        } else if partId != nil {
            object["attachmentId"] = NSNull()
        }
        if let partId {
            object["partId"] = partId
        } else if attachmentId != nil {
            object["partId"] = NSNull()
        }
        if let labelIds {
            object["labelIds"] = labelIds
        }
        if let historyId {
            object["historyId"] = historyId
        } else if labelIds != nil {
            object["historyId"] = NSNull()
        }
        return object
    }
}

struct MailRejectedAttachment: Codable {
    let path: String
    let code: String
    let reason: String

    func graphQLObject() -> [String: String] {
        [
            "path": path,
            "code": code,
            "reason": reason
        ]
    }
}

struct MailWriteResult: Codable {
    let operation: String
    let accountId: String
    let provider: String
    let draftId: String?
    let messageId: String?
    let threadId: String?
    let status: String
    let rejectedAttachments: [MailRejectedAttachment]

    func graphQLObject() -> [String: Any] {
        var object: [String: Any] = [
            "operation": operation,
            "accountId": accountId,
            "provider": provider,
            "messageId": messageId as Any? ?? NSNull(),
            "threadId": threadId as Any? ?? NSNull(),
            "status": status,
            "rejectedAttachments": rejectedAttachments.map { $0.graphQLObject() }
        ]
        if operation == MailGatewayWriteMode.draftDefault.operationValue {
            object["draftId"] = draftId as Any? ?? NSNull()
        }
        return object
    }
}
