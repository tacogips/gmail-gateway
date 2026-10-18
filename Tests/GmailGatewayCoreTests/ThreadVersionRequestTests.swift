import Foundation
import GatewaySDKKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GmailGatewayCore
import Testing

extension GmailRequestProtocolTests {
    @Test func threadVersionReadsStayBodyFreeAndDetectNewRepliesWithSameSnippet() async throws {
        let fixture = try GatewayRuntimeFixture()
        defer { fixture.remove() }
        TestGmailRequestCaptureProtocol.reset()
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }
        let query = """
        query Version($account: ID!, $thread: ID!) {
          thread(accountId: $account, threadId: $thread) {
            id providerMetadata { gmail { historyId } }
          }
        }
        """
        let variables: [String: GatewayJSONValue] = ["account": .string("personal"), "thread": .string("thread-id")]
        func version() async throws -> String? {
            let result = await GmailGatewayGraphQLExecutor().run(
                query: query, variables: variables, mode: .reader, environment: fixture.environment
            )
            #expect(result.exitCode == 0)
            let data = try #require(result.data?.anyValue as? [String: Any])
            let thread = try #require(data["thread"] as? [String: Any])
            #expect(Set(thread.keys) == ["id", "providerMetadata"])
            let metadata = try #require(thread["providerMetadata"] as? [String: Any])
            let gmail = try #require(metadata["gmail"] as? [String: Any])
            return gmail["historyId"] as? String
        }
        TestGmailRequestCaptureProtocol.threadGetResponseData = Data("""
        {"id":"thread-id","historyId":"100","snippet":"same truncated snippet",
         "messages":[{"id":"old","threadId":"thread-id","historyId":"99"}]}
        """.utf8)
        let baseline = try await version()
        #expect(baseline == "100")
        #expect(try await version() == baseline)
        // The first message and snippet stay identical when a reply arrives.
        TestGmailRequestCaptureProtocol.threadGetResponseData = Data("""
        {"id":"thread-id","historyId":"101","snippet":"same truncated snippet",
         "messages":[{"id":"old","threadId":"thread-id","historyId":"99"},
                     {"id":"new","threadId":"thread-id","historyId":"101"}]}
        """.utf8)
        #expect(try await version() == "101")
        #expect(TestGmailRequestCaptureProtocol.capturedURLs.map(\.absoluteString) == Array(
            repeating: "https://gmail.googleapis.com/gmail/v1/users/me/threads/thread-id?format=minimal", count: 3
        ))
        #expect(TestGmailRequestCaptureProtocol.capturedMethods == ["GET", "GET", "GET"])
        #expect(TestGmailRequestCaptureProtocol.capturedHTTPBodies.isEmpty)

        // Absence is not replaced by the first message's older version.
        TestGmailRequestCaptureProtocol.threadGetResponseData = Data("""
        {"id":"thread-id","messages":[{"id":"old","historyId":"99"}]}
        """.utf8)
        #expect(try await version() == nil)
    }

    @Test func fullThreadReturnsThreadVersionAndRequestedMessageHeaders() async throws {
        let fixture = try GatewayRuntimeFixture()
        defer { fixture.remove() }
        TestGmailRequestCaptureProtocol.reset()
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }
        TestGmailRequestCaptureProtocol.threadGetResponseData = Data("""
        {"id":"thread-id","historyId":"101","messages":[
          {"id":"old","historyId":"99","payload":{"headers":[{"name":"Subject","value":"Old subject"}],"mimeType":"text/plain","body":{"data":"b2xk"}}},
          {"id":"new","historyId":"101","payload":{"headers":[{"name":"Subject","value":"New subject"}],"mimeType":"text/plain","body":{"data":"bmV3"}}}
        ]}
        """.utf8)
        let result = await GmailGatewayGraphQLExecutor().run(
            query: """
            { thread(accountId: "personal", threadId: "thread-id") {
                messages { id subject } providerMetadata { gmail { historyId } }
            } }
            """,
            mode: .reader, environment: fixture.environment
        )
        #expect(result.exitCode == 0)
        #expect(result.data == .object(["thread": .object([
            "messages": .array([
                .object(["id": .string("old"), "subject": .string("Old subject")]),
                .object(["id": .string("new"), "subject": .string("New subject")])
            ]),
            "providerMetadata": .object(["gmail": .object(["historyId": .string("101")])])
        ])]))
        #expect(TestGmailRequestCaptureProtocol.capturedURLs.map(\.absoluteString) == [
            "https://gmail.googleapis.com/gmail/v1/users/me/threads/thread-id?format=full"
        ])
    }

    @Test func pagedCandidateListsRemainBodyFreeWithoutHistoryIds() async throws {
        let fixture = try GatewayRuntimeFixture()
        defer { fixture.remove() }
        TestGmailRequestCaptureProtocol.reset()
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }
        let query = """
        query Candidates($after: String) {
          threads(input: { accountId: "personal", first: 1, after: $after }) {
            edges { node { id providerMetadata { gmail { historyId } } } }
            pageInfo { hasNextPage endCursor }
          }
        }
        """
        for (page, cursor) in [("first", GatewayJSONValue.null), ("second", .string("next-page"))] {
            TestGmailRequestCaptureProtocol.threadListResponseData = Data("""
            {"threads":[{"id":"\(page)"}],"nextPageToken":"next-page","resultSizeEstimate":2}
            """.utf8)
            let result = await GmailGatewayGraphQLExecutor().run(
                query: query, variables: ["after": cursor], mode: .reader, environment: fixture.environment
            )
            #expect(result.exitCode == 0)
            #expect(result.data?.anyValue is [String: Any])
        }
        #expect(TestGmailRequestCaptureProtocol.capturedURLs.map(\.absoluteString) == [
            "https://gmail.googleapis.com/gmail/v1/users/me/threads?maxResults=1&labelIds=INBOX",
            "https://gmail.googleapis.com/gmail/v1/users/me/threads?maxResults=1&pageToken=next-page&labelIds=INBOX"
        ])
    }

    @Test func unavailableThreadVersionPropagatesFailureInsteadOfUnchangedResult() async throws {
        let fixture = try GatewayRuntimeFixture()
        defer { fixture.remove() }
        TestGmailRequestCaptureProtocol.reset()
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }
        TestGmailRequestCaptureProtocol.responseStatusCode = 404
        TestGmailRequestCaptureProtocol.threadGetResponseData = Data(#"{"error":{"message":"Not Found"}}"#.utf8)
        let result = await GmailGatewayGraphQLExecutor().run(
            query: #"{ thread(accountId: "personal", threadId: "missing") { providerMetadata { gmail { historyId } } } }"#,
            mode: .reader, environment: fixture.environment
        )
        #expect(result.exitCode != 0)
        #expect(!result.errors.isEmpty)
        #expect(TestGmailRequestCaptureProtocol.capturedURLs.allSatisfy { $0.query == "format=minimal" })
    }
}
