import Foundation
import GatewaySDKKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GmailGatewayCore
import Testing

struct GatewayRuntimeFixture {
    let root: URL
    let configPath: String
    let environment: [String: String]

    init(accessMode: AccessMode = .read) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmail-gateway-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        configPath = root.appendingPathComponent("config.toml").path
        let tokenVariable = GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
            credentialId: "gmail-personal",
            valueKey: "token_store_json"
        )
        let config = """
        [storage]
        cache_dir = "cache"
        attachment_dir = "attachments"
        allowed_send_attachment_roots = ["send"]

        [[credentials]]
        id = "gmail-personal"
        provider = "gmail"
        access_mode = "\(accessMode.rawValue)"
        oauth_client_secret_path = "client.json"
        token_store_path = "token.json"

        [[accounts]]
        id = "personal"
        provider = "gmail"
        email_address = "person@example.com"
        credential_id = "gmail-personal"
        default_label_ids = ["INBOX"]
        """
        try Data(config.utf8).write(to: URL(fileURLWithPath: configPath))
        environment = [
            "GMAIL_GATEWAY_CONFIG": configPath,
            tokenVariable: """
            {"accessMode":"\(accessMode.rawValue)","accessToken":"test","expiresAt":"2999-01-01T00:00:00Z"}
            """
        ]
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

final class GatewayRuntimeURLProtocol: URLProtocol {
    struct CapturedRequest {
        let url: String
        let method: String
        let body: Data?
        let contentType: String?

        var jsonBody: [String: Any]? {
            guard let body else { return nil }
            return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
    }

    nonisolated(unsafe) static var requests: [CapturedRequest] = []
    nonisolated(unsafe) static var urls: [URL] = []
    nonisolated(unsafe) static var methods: [String] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    nonisolated(unsafe) static var data = Data(#"{"threads":[],"resultSizeEstimate":0}"#.utf8)
    nonisolated(unsafe) static var responseStatusCodes: [Int] = []
    nonisolated(unsafe) static var responseDelay: TimeInterval = 0
    nonisolated(unsafe) static var responseLostAfterProviderAcceptance = false
    nonisolated(unsafe) static var responseFailsAfterHTTPResponse = false
    nonisolated(unsafe) static var completedResponseCount = 0
    nonisolated(unsafe) static var stoppedRequestCount = 0
    nonisolated(unsafe) static var draftListResponseData: Data?
    nonisolated(unsafe) static var draftDetailResponseData: Data?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "gmail.googleapis.com"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = request.httpBody ?? Self.data(from: request.httpBodyStream)
        if let url = request.url {
            Self.urls.append(url)
        }
        Self.methods.append(request.httpMethod ?? "GET")
        if let body {
            Self.bodies.append(body)
        }
        Self.requests.append(
            .init(
                url: request.url?.absoluteString ?? "",
                method: request.httpMethod ?? "GET",
                body: body,
                contentType: request.value(forHTTPHeaderField: "Content-Type")
            )
        )
        let statusCode = Self.responseStatusCodes.isEmpty ? 200 : Self.responseStatusCodes.removeFirst()
        let delay = Self.responseDelay
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.finishLoading(statusCode: statusCode)
            }
        } else {
            finishLoading(statusCode: statusCode)
        }
    }

    override func stopLoading() {
        loadingLock.lock()
        isStopped = true
        loadingLock.unlock()
        Self.stoppedRequestCount += 1
    }

    static func reset() {
        requests = []
        urls = []
        methods = []
        bodies = []
        data = Data(#"{"threads":[],"resultSizeEstimate":0}"#.utf8)
        responseStatusCodes = []
        responseDelay = 0
        responseLostAfterProviderAcceptance = false
        responseFailsAfterHTTPResponse = false
        completedResponseCount = 0
        stoppedRequestCount = 0
        draftListResponseData = nil
        draftDetailResponseData = nil
    }

    private let loadingLock = NSLock()
    private var isStopped = false

    private func finishLoading(statusCode: Int) {
        loadingLock.lock()
        let stopped = isStopped
        loadingLock.unlock()
        guard !stopped else { return }
        if Self.responseLostAfterProviderAcceptance {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://gmail.googleapis.com/")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if Self.responseFailsAfterHTTPResponse {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        client?.urlProtocol(self, didLoad: responseData(for: request))
        client?.urlProtocolDidFinishLoading(self)
        Self.completedResponseCount += 1
    }

    private static let messageData = Data("""
    {
      "id": "message-id",
      "threadId": "thread-id",
        "payload": {
          "headers": [
          { "name": "From", "value": "Display Name <person@example.com>" },
          { "name": "To", "value": "recipient@example.com" },
          { "name": "Subject", "value": "Runtime subject" },
          { "name": "Message-ID", "value": "<message-id@example.com>" }
          ]
      }
    }
    """.utf8)

    private func responseData(for request: URLRequest) -> Data {
        let path = request.url?.path ?? ""
        let method = request.httpMethod?.uppercased() ?? "GET"
        if method == "DELETE" { return Data() }
        if path == "/oauth/token" {
            return Data(#"{"access_token":"refreshed","token_type":"Bearer","expires_in":3600}"#.utf8)
        }
        if path == "/gmail/v1/users/me/labels" {
            return Data(#"{"labels":[{"id":"Label_1","name":"Work","type":"user"}]}"#.utf8)
        }
        if path == "/gmail/v1/users/me/profile" {
            return Data(#"{"emailAddress":"person@example.com","messagesTotal":1,"threadsTotal":1,"historyId":"1"}"#.utf8)
        }
        if path == "/gmail/v1/users/me/drafts" {
            if method == "POST" {
                return Data(#"{"id":"draft-1","message":{"id":"message-id","threadId":"thread-id"}}"#.utf8)
            }
            return Self.draftListResponseData ?? Data(#"{"drafts":[],"resultSizeEstimate":0}"#.utf8)
        }
        if path.hasPrefix("/gmail/v1/users/me/drafts/") {
            return Self.draftDetailResponseData ?? Data(#"{"id":"draft-1","message":{"id":"message-id","threadId":"thread-id","payload":{"headers":[]}}}"#.utf8)
        }
        if path == "/gmail/v1/users/me/threads" {
            return Data(#"{"threads":[],"resultSizeEstimate":0}"#.utf8)
        }
        if path.hasPrefix("/gmail/v1/users/me/threads/") {
            return Data(#"{"id":"thread-1","messages":[]}"#.utf8)
        }
        if path.contains("/attachments/") {
            return Data(#"{"attachmentId":"attachment-id","size":1,"data":"eA=="}"#.utf8)
        }
        if path.hasPrefix("/gmail/v1/users/me/messages/") {
            return Self.messageData
        }
        if path == "/gmail/v1/users/me/messages" || path == "/gmail/v1/users/me/messages/import" {
            return Data(#"{"id":"message-id","threadId":"thread-id","labelIds":[]}"#.utf8)
        }
        return Self.data
    }

    private static func data(from stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}

extension GatewayRuntimeURLProtocol: @unchecked Sendable {}

/// The accepted capability contract is deliberately test-owned.  Do not derive
/// expectations from the production catalogs: doing so would hide a widened mode.
enum GmailGatewayAcceptedRuntimeContract {
    static let readOperations: Set<String> = [
        "accounts", "account", "threads", "thread", "message", "messageFileSet",
        "attachment", "labels", "profile"
    ]
    static let draftOperations: Set<String> = [
        "drafts", "draft", "createDraft", "createReplyDraft", "createForwardDraft",
        "updateDraft", "deleteDraft"
    ]
    static let senderOperations: Set<String> = [
        "sendMessage", "replyMessage", "forwardMessage", "sendDraft"
    ]
    static let mailboxOperations: Set<String> = [
        "modifyThreadLabels", "modifyMessageLabels", "batchModifyMessageLabels",
        "trashThread", "untrashThread", "trashMessage", "untrashMessage", "deleteThread",
        "deleteMessage", "batchDeleteMessages", "createLabel", "updateLabel", "deleteLabel"
    ]
    static let ingestOperations: Set<String> = ["importMessage", "insertMessage"]

    static func operations(for mode: GmailGatewayCLIMode) -> Set<String> {
        switch mode {
        case .reader: readOperations
        case .draftGateway: readOperations.union(draftOperations)
        case .directSender: readOperations.union(draftOperations).union(senderOperations)
        case .mailboxThreads: readOperations.union(mailboxOperations)
        case .messageBox: readOperations.union(ingestOperations)
        }
    }

    static func authorized(_ operation: String, in mode: GmailGatewayCLIMode) -> Bool {
        operations(for: mode).contains(operation)
    }
}

func canonicalJSON(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard let text = String(data: data, encoding: .utf8) else {
        throw GatewayRuntimeTestError.invalidJSON
    }
    return text
}

func assertCompleteSuccessEnvelope(
    _ result: GmailGatewayCommandResult,
    expectedData: [String: Any]
) throws {
    guard case .object(var actual) = try GatewayJSONValue.parse(result.stdout),
          case .array(let errors)? = actual["errors"], errors.isEmpty,
          case .object(let extensions)? = actual["extensions"],
          Set(extensions.keys) == ["requestId"],
          case .string(let requestId)? = extensions["requestId"],
          UUID(uuidString: requestId) != nil else {
        throw GatewayRuntimeTestError.invalidJSON
    }
    actual["extensions"] = .object(["requestId": .string("<request-id>")])
    let expected = GatewayJSONValue.object([
        "data": try GatewayJSONValue.parse(canonicalJSON(expectedData)),
        "errors": .array([]),
        "extensions": .object(["requestId": .string("<request-id>")])
    ])
    #expect(.object(actual) == expected)
}

func assertCompleteProviderBodies(
    _ requests: [GatewayRuntimeURLProtocol.CapturedRequest],
    finalBody: [String: Any]?
) throws {
    guard let finalRequest = requests.last else {
        throw GatewayRuntimeTestError.invalidJSON
    }
    for request in requests.dropLast() {
        #expect(request.body == nil, "Prerequisite provider requests must be bodyless")
        #expect(request.contentType == nil, "Prerequisite provider requests must omit Content-Type")
    }
    if finalBody == nil {
        #expect(finalRequest.body == nil, "Bodyless provider requests must not serialize an empty JSON object")
        #expect(finalRequest.contentType == nil, "Bodyless provider requests must omit Content-Type")
    }
    #expect(
        try decodedCanonicalProviderBody(finalRequest) == (try finalBody.map(canonicalJSON)),
        "Final provider request body must match exactly"
    )
}

func decodedCanonicalProviderBody(_ request: GatewayRuntimeURLProtocol.CapturedRequest) throws -> String? {
    guard var body = request.jsonBody else { return nil }
    decodeRawMIME(in: &body)
    return try canonicalJSON(body)
}

private func decodeRawMIME(in object: inout [String: Any]) {
    if let raw = object["raw"] as? String,
       let data = dataFromBase64URLString(raw),
       let mime = String(bytes: data, encoding: .utf8) {
        object["raw"] = mime
    }
    if var message = object["message"] as? [String: Any] {
        decodeRawMIME(in: &message)
        object["message"] = message
    }
}

private enum GatewayRuntimeTestError: Error {
    case invalidJSON
}

func gatewayPlainMIME(to: String, subject: String?, body: String) -> String {
    var lines = ["From: person@example.com", "To: \(to)"]
    if let subject { lines.append("Subject: \(subject)") }
    lines += ["MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: 8bit", "", body]
    return lines.joined(separator: "\r\n")
}

func gatewayReplyMIME() -> String {
    [
        "From: person@example.com", "To: Display Name <person@example.com>", "Subject: Re: Runtime subject",
        "In-Reply-To: <message-id@example.com>", "References: <message-id@example.com>",
        "MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: 8bit", "", "x"
    ].joined(separator: "\r\n")
}

func gatewayForwardMIME() -> String {
    [
        "From: person@example.com", "To: a@example.test", "Subject: Fwd: Runtime subject",
        "References: <message-id@example.com>", "MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8",
        "Content-Transfer-Encoding: 8bit", "", "---------- Forwarded message ----------\r\nFrom: Display Name <person@example.com>\r\nSubject: Runtime subject\r\nTo: recipient@example.com"
    ].joined(separator: "\r\n")
}
