import Foundation

struct GmailThreadListResponse: Decodable {
    let threads: [GmailThreadListItem]?
    let nextPageToken: String?
    let resultSizeEstimate: Int?
}

struct GmailThreadListItem: Decodable {
    let id: String?
    let snippet: String?
    let historyId: String?
}

struct GmailAPIThread: Decodable {
    let id: String?
    let messages: [GmailAPIMessage]?
}

struct GmailAPIMessage: Decodable {
    let id: String?
    let threadId: String?
    let labelIds: [String]?
    let snippet: String?
    let historyId: String?
    let internalDate: String?
    let payload: GmailAPIPayload?
}

struct GmailAPIPayload: Decodable {
    let partId: String?
    let mimeType: String?
    let filename: String?
    let body: GmailAPIBody?
    let parts: [GmailAPIPayload]?
    let headers: [GmailAPIHeader]?
}

struct GmailAPIBody: Decodable {
    let size: Int?
    let data: String?
    let attachmentId: String?
}

struct GmailAPIHeader: Decodable {
    let name: String?
    let value: String?
}

struct GmailAttachmentPayloadResponse: Decodable {
    let data: String?
}
