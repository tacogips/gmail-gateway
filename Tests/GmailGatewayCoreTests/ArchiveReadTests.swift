import Foundation
import XCTest
import GatewaySDKKit
@testable import GmailGatewayCore

final class ArchiveReadTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ArchiveReadProtocol.reset()
    }

    private func service(token: String? = "synthetic") -> GmailGatewayService {
        let credential = CredentialConfig(id: "fixture", provider: .gmail, accessMode: .read,
            directAccessToken: token, oauthClientSecretPath: "/not-read", oauthClientSecretJSON: nil,
            tokenStorePath: "/not-read", tokenStoreJSON: nil)
        let account = AccountConfig(id: "personal", provider: .gmail, emailAddress: "fixture@example.invalid",
            credentialId: "fixture", defaultLabelIds: ["INBOX"])
        return GmailGatewayService(config: GmailGatewayConfig(configPath: "/not-read",
            storage: StorageConfig(cacheDir: "/not-created", attachmentDir: "/not-created", allowedSendAttachmentRoots: []),
            credentials: [credential], accounts: [account]))
    }

    func testReaderSDKExposesBothOperationsAndRejectsInvalidBoundsBeforeTransport() async throws {
        let fixture = try GatewayRuntimeFixture()
        defer { fixture.remove() }
        let page = await GmailGatewaySDK(mode: .reader).execute(
            document: #"{ messageIds(accountId: "personal", query: "", first: 101) { messages { id threadId } pageInfo { hasNextPage } } }"#,
            variables: [:], environment: fixture.environment)
        XCTAssertEqual(page.errors.map(\.code), ["INVALID_ARGUMENT"])
        let bytes = await GmailGatewaySDK(mode: .reader).execute(
            document: #"{ attachmentBytes(accountId: "personal", messageId: "m", attachmentId: "a", maxBytes: 0) { byteCount dataBase64 } }"#,
            variables: [:], environment: fixture.environment)
        XCTAssertEqual(bytes.errors.map(\.code), ["INVALID_ARGUMENT"])
        XCTAssertTrue(ArchiveReadProtocol.urls.isEmpty)
    }

    func testSDKSuccessWithExplicitEphemeralTransportFixture() async throws {
        let fixture = try GatewayRuntimeFixture()
        defer { fixture.remove() }
        ArchiveReadProtocol.payload = Data(#"{"size":0,"data":""}"#.utf8)
        let result = await GmailBoundedRead.$protocolClasses.withValue([ArchiveReadProtocol.self]) {
            await GmailGatewaySDK(mode: .reader).execute(
                document: #"{ attachmentBytes(accountId: "personal", messageId: "m", attachmentId: "a", maxBytes: 1) { byteCount dataBase64 } }"#,
                variables: [:], environment: fixture.environment)
        }
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(result.data, .object(["attachmentBytes": .object(["byteCount": .int(0), "dataBase64": .string("")])]))
        XCTAssertEqual(ArchiveReadProtocol.urls.count, 1)
    }

    func testAllCLIReadModesAcceptArchiveOperationsButRejectBoundsBeforeDispatch() throws {
        let fixture = try GatewayRuntimeFixture()
        defer { fixture.remove() }
        for mode: GmailGatewayCLIMode in [.reader, .draftGateway, .directSender, .mailboxThreads, .messageBox] {
            for (operation, arguments) in [
                ("messageIds", #"{"accountId":"personal","query":"","first":101}"#),
                ("attachmentBytes", #"{"accountId":"personal","messageId":"m","attachmentId":"a","maxBytes":0}"#),
                ("messagePartBytes", #"{"accountId":"personal","messageId":"m","partId":"0","maxBytes":0}"#)
            ] {
                let result = GmailGatewayCLI(mode: mode).run(
                    arguments: ["graphql", "operation", operation, "--variables", arguments,
                                "--select", operation == "messageIds" ? "messages.id" : "byteCount"], environment: fixture.environment)
                XCTAssertNotEqual(result.exitCode, 0)
                XCTAssertTrue((result.stdout + result.stderr).contains("INVALID_ARGUMENT"), result.stdout + result.stderr)
            }
        }
        XCTAssertTrue(ArchiveReadProtocol.urls.isEmpty)
    }

    func testExplicitEmptyRootPartIdentitySurvivesMetadataAndRead() throws {
        let object: [String: Any] = ["id": "m", "threadId": "t", "payload": [
            "partId": "", "filename": "root.pdf", "body": ["size": 0, "data": ""]]]
        let account = AccountConfig(id: "personal", provider: .gmail, emailAddress: "fixture@example.invalid",
                                    credentialId: "fixture", defaultLabelIds: [])
        XCTAssertEqual(buildMailMessage(account: account, object: object).attachments.first?.providerMetadata?.gmail?.partId, "")
        let typed = try JSONDecoder().decode(GmailAPIMessage.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(buildMailMessage(account: account, object: typed).attachments.first?.providerMetadata?.gmail?.partId, "")
        try GmailBoundedRead.$protocolClasses.withValue([ArchiveReadProtocol.self]) {
            ArchiveReadProtocol.payload = try JSONSerialization.data(withJSONObject: object)
            let result = try service().messagePartBytes(accountId: "personal", messageId: "m", partId: "")
            XCTAssertEqual(result["partId"] as? String, "")
            XCTAssertEqual(result["byteCount"] as? Int, 0)
        }
    }

    func testExactInlineNestedPartBytesAndDuplicateFilenames() throws {
        try GmailBoundedRead.$protocolClasses.withValue([ArchiveReadProtocol.self]) {
            ArchiveReadProtocol.payload = Data((#"{"id":"m","payload":{"partId":"","parts":["#
                + #"{"partId":"1.0","filename":"same.pdf","body":{"size":3,"data":"YWJj"}},"#
                + #"{"partId":"1.1","filename":"same.pdf","body":{"size":1,"data":"ZA"}}]}}"#).utf8)
            let result = try service().messagePartBytes(accountId: "personal", messageId: "m", partId: "1.1", maxBytes: 1)
            XCTAssertEqual(result["dataBase64"] as? String, "ZA==")
            XCTAssertEqual(result["partId"] as? String, "1.1")
            XCTAssertEqual(ArchiveReadProtocol.urls.last?.path, "/gmail/v1/users/me/messages/m")
            XCTAssertEqual(ArchiveReadProtocol.urls.last?.query, "format=full")
            XCTAssertThrowsError(try service().messagePartBytes(accountId: "personal", messageId: "m", partId: "1.0", maxBytes: 2))
            XCTAssertThrowsError(try service().messagePartBytes(accountId: "personal", messageId: "m", partId: "2"))
        }
    }

    func testInlinePartRejectsAmbiguousRemoteMissingAndWrongIdentity() throws {
        try GmailBoundedRead.$protocolClasses.withValue([ArchiveReadProtocol.self]) {
            for payload in [
                #"{"id":"wrong","payload":{"partId":"0","filename":"a","body":{"size":1,"data":"ZA"}}}"#,
                #"{"id":"m","payload":{"partId":"0","filename":"","body":{"size":1,"data":"ZA"}}}"#,
                #"{"id":"m","payload":{"partId":"0","filename":"a","body":{"size":1,"attachmentId":"remote"}}}"#,
                #"{"id":"m","payload":{"partId":"0","filename":"a","body":{"size":2,"data":"ZA"}}}"#,
                #"{"id":"m","payload":{"partId":"0","filename":"a","body":{"size":1,"data":"ZA"},"parts":[{"partId":"0"}]}}"#
            ] {
                ArchiveReadProtocol.payload = Data(payload.utf8)
                XCTAssertThrowsError(try service().messagePartBytes(accountId: "personal", messageId: "m", partId: "0"))
            }
            let before = ArchiveReadProtocol.urls.count
            XCTAssertThrowsError(try service().messagePartBytes(accountId: "personal", messageId: "m", partId: "../x"))
            XCTAssertEqual(ArchiveReadProtocol.urls.count, before)
        }
    }

    func testProviderAttemptBudgetAppliesBeforeDispatch() throws {
        try GmailBoundedRead.$protocolClasses.withValue([ArchiveReadProtocol.self]) {
            let budget = GmailGatewayProviderAttemptBudget(maximumRequests: 0)
            try GmailGatewayProviderAttemptBudgetContext.$current.withValue(budget) {
                XCTAssertThrowsError(try service().messageIds(accountId: "personal", query: "")) { error in
                    XCTAssertEqual((error as? GmailGatewayError)?.code, .resourceLimit)
                }
            }
            XCTAssertTrue(ArchiveReadProtocol.urls.isEmpty)
        }
    }

    func testCancellationStopsOwnedReadInFlight() throws {
        try GmailBoundedRead.$protocolClasses.withValue([ArchiveReadProtocol.self]) {
            let cancellation = GmailGatewayProviderCancellation()
            ArchiveReadProtocol.onStart = { cancellation.cancel() }
            let started = Date()
            try GmailGatewayProviderCancellationContext.$current.withValue(cancellation) {
                XCTAssertThrowsError(try service().messageIds(accountId: "personal", query: "")) { error in
                    XCTAssertEqual((error as? GmailGatewayError)?.code, .cancelled)
                }
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
            XCTAssertEqual(ArchiveReadProtocol.urls.count, 1)
        }
    }

    func testMessageListDoesNotHydrateAndCursorBindsEveryFilter() throws {
        try GmailBoundedRead.$protocolClasses.withValue([ArchiveReadProtocol.self]) {
            ArchiveReadProtocol.payload = Data(#"{"messages":[{"id":"m1","threadId":"t1"}],"nextPageToken":"next","resultSizeEstimate":2}"#.utf8)
            let page = try service().messageIds(accountId: "personal", query: "from:example.test", first: 5, includeSpamTrash: true)
            let info = try XCTUnwrap(page["pageInfo"] as? [String: Any])
            let cursor = try XCTUnwrap(info["endCursor"] as? String)
            XCTAssertEqual(ArchiveReadProtocol.urls.count, 1)
            XCTAssertEqual(ArchiveReadProtocol.urls[0].path, "/gmail/v1/users/me/messages")
            let query = try XCTUnwrap(URLComponents(url: ArchiveReadProtocol.urls[0], resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(query.first { $0.name == "includeSpamTrash" }?.value, "true")
            XCTAssertNil(query.first { $0.name == "labelIds" })
            XCTAssertThrowsError(try service().messageIds(accountId: "personal", query: "other", first: 5, after: cursor, includeSpamTrash: true))
            XCTAssertThrowsError(try service().messageIds(accountId: "personal", query: "from:example.test", first: 6, after: cursor, includeSpamTrash: true))
            XCTAssertThrowsError(try service().messageIds(accountId: "personal", query: "from:example.test", first: 5, after: cursor))
            XCTAssertEqual(ArchiveReadProtocol.urls.count, 1)
            ArchiveReadProtocol.payload = Data(#"{"messages":[],"resultSizeEstimate":2}"#.utf8)
            let end = try service().messageIds(accountId: "personal", query: "from:example.test", first: 5, after: cursor, includeSpamTrash: true)
            XCTAssertEqual((end["pageInfo"] as? [String: Any])?["hasNextPage"] as? Bool, false)
            XCTAssertEqual(ArchiveReadProtocol.urls.count, 2)
            XCTAssertEqual(URLComponents(url: ArchiveReadProtocol.urls[1], resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pageToken" }?.value, "next")
        }
    }

    func testInvalidArgumentsAndCancelledContextNeverDispatch() throws {
        try GmailBoundedRead.$protocolClasses.withValue([ArchiveReadProtocol.self]) {
            for first in [0, 101] { XCTAssertThrowsError(try service().messageIds(accountId: "personal", query: "", first: first)) }
            XCTAssertThrowsError(try service().messageIds(accountId: "personal", query: "", after: "invalid"))
            XCTAssertThrowsError(try service().attachmentBytes(accountId: "personal", messageId: "../bad", attachmentId: "a"))
            for maximum in [0, 20 * 1024 * 1024 + 1] {
                XCTAssertThrowsError(try service().attachmentBytes(accountId: "personal", messageId: "m", attachmentId: "a", maxBytes: maximum))
            }
            let cancellation = GmailGatewayProviderCancellation()
            cancellation.cancel()
            try GmailGatewayProviderCancellationContext.$current.withValue(cancellation) {
                XCTAssertThrowsError(try service(token: nil).messageIds(accountId: "personal", query: "")) { error in
                    XCTAssertEqual((error as? GmailGatewayError)?.code, .cancelled)
                }
                XCTAssertThrowsError(try service(token: nil).attachmentBytes(accountId: "personal", messageId: "m", attachmentId: "a")) { error in
                    XCTAssertEqual((error as? GmailGatewayError)?.code, .cancelled)
                }
            }
            XCTAssertTrue(ArchiveReadProtocol.urls.isEmpty)
        }
    }

    func testAttachmentBytesAreExactBoundedAndNoLocalMaterialization() throws {
        try GmailBoundedRead.$protocolClasses.withValue([ArchiveReadProtocol.self]) {
            ArchiveReadProtocol.payload = Data(#"{"size":3,"data":"YWJj"}"#.utf8)
            let result = try service().attachmentBytes(accountId: "personal", messageId: "m", attachmentId: "a", maxBytes: 3)
            XCTAssertEqual(result["dataBase64"] as? String, "YWJj")
            XCTAssertEqual(result["byteCount"] as? Int, 3)
            XCTAssertEqual(result["sha256"] as? String, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
            XCTAssertEqual(result["messageId"] as? String, "m")
            XCTAssertNil(result["downloadKey"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: "/not-created"))
            XCTAssertThrowsError(try service().attachmentBytes(accountId: "personal", messageId: "m", attachmentId: "a", maxBytes: 2))
        }
    }

    func testMalformedOrDishonestAttachmentResponsesFail() throws {
        try GmailBoundedRead.$protocolClasses.withValue([ArchiveReadProtocol.self]) {
            for value in [#"{"size":4,"data":"YWJj"}"#, #"{"size":3,"data":"!!!!"}"#, #"{"size":-1,"data":""}"#, #"{}"#] {
                ArchiveReadProtocol.payload = Data(value.utf8)
                XCTAssertThrowsError(try service().attachmentBytes(accountId: "personal", messageId: "m", attachmentId: "a", maxBytes: 10))
            }
        }
    }

    func testBoundedTransportRejectsDeclaredAndStreamedOversize() throws {
        try GmailBoundedRead.$protocolClasses.withValue([ArchiveReadProtocol.self]) {
            ArchiveReadProtocol.payload = Data(repeating: 65, count: 100)
            for declared in [nil, "100"] {
                ArchiveReadProtocol.contentLength = declared
                XCTAssertThrowsError(try GmailBoundedRead.get(gmailURLComponents(path: "/gmail/v1/users/me/messages"), token: "synthetic", maximumBytes: 5)) { error in
                    XCTAssertEqual((error as? GmailGatewayError)?.code, .resourceLimit)
                }
            }
        }
    }

    func testMalformedMetadataDoesNotHydrateOrAcceptMissingIdentity() throws {
        try GmailBoundedRead.$protocolClasses.withValue([ArchiveReadProtocol.self]) {
            for value in [#"{"messages":[{"id":"m","threadId":""}]}"#,
                          #"{"messages":[{"id":"m","threadId":"t"},{"id":"m","threadId":"t"}]}"#,
                          #"{"nextPageToken":""}"#] {
                ArchiveReadProtocol.payload = Data(value.utf8)
                XCTAssertThrowsError(try service().messageIds(accountId: "personal", query: ""))
            }
            XCTAssertEqual(ArchiveReadProtocol.urls.count, 3)
        }
    }
}

private class ArchiveReadProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var payload = Data()
    nonisolated(unsafe) static var contentLength: String?
    nonisolated(unsafe) static var onStart: (@Sendable () -> Void)?
    nonisolated(unsafe) private static var requests: [URL] = []
    static var urls: [URL] { lock.lock(); defer { lock.unlock() }; return requests }
    static func reset() { lock.lock(); defer { lock.unlock() }; requests = []; payload = Data(); contentLength = nil; onStart = nil }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "gmail.googleapis.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock(); Self.requests.append(url); Self.lock.unlock()
        if let onStart = Self.onStart { onStart(); return }
        let headers = Self.contentLength.map { ["Content-Length": $0] } ?? [:]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
