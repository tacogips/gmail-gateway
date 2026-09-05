import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GmailGatewayCore
import Testing

@Suite(.serialized)
struct GmailRequestProtocolTests {
    private let readableTokenStoreJSON = """
    {
      "accessMode": "read",
      "accessToken": "test-access-token",
      "refreshToken": null,
      "tokenType": "Bearer",
      "scope": "https://www.googleapis.com/auth/gmail.readonly",
      "expiresAt": "2999-01-01T00:00:00Z",
      "emailAddress": "person@example.com"
    }
    """

    private let sendTokenStoreJSON = """
    {
      "accessMode": "read_send",
      "accessToken": "test-access-token",
      "refreshToken": null,
      "tokenType": "Bearer",
      "scope": "https://www.googleapis.com/auth/gmail.send",
      "expiresAt": "2999-01-01T00:00:00Z",
      "emailAddress": "person@example.com"
    }
    """

    @Test func threadSearchWiresFirstAndAfterToGmailListRequest() throws {
        try withReaderService(tokenStoreJSON: readableTokenStoreJSON) { service, _ in
            TestGmailRequestCaptureProtocol.reset()
            TestGmailRequestCaptureProtocol.expectedListMaxResults = "25"
            TestGmailRequestCaptureProtocol.expectedListPageToken = "page-token"
            URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
            defer {
                URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
                TestGmailRequestCaptureProtocol.reset()
            }

            _ = try service.searchThreads(
                accountId: "personal",
                first: 25,
                after: "page-token",
                includeEdges: false,
                includeNodeDetails: false
            )

            #expect(TestGmailRequestCaptureProtocol.capturedURLs.map(\.path) == ["/gmail/v1/users/me/threads"])
        }
    }

    @Test func threadSearchDateTimeFiltersUseEpochSeconds() throws {
        try withReaderService(tokenStoreJSON: readableTokenStoreJSON) { service, _ in
            TestGmailRequestCaptureProtocol.reset()
            TestGmailRequestCaptureProtocol.expectedListQuery = "after:1782918000 before:2026/07/02"
            URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
            defer {
                URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
                TestGmailRequestCaptureProtocol.reset()
            }

            _ = try service.searchThreads(
                accountId: "personal",
                receivedAfter: "2026-07-01T15:00:00Z",
                receivedBefore: "2026-07-02",
                includeEdges: false,
                includeNodeDetails: false
            )
        }
    }

    @Test func threadSearchUsesThreadsListAndBuildsFullThreadNodes() throws {
        try withReaderService(tokenStoreJSON: readableTokenStoreJSON) { service, _ in
            TestGmailRequestCaptureProtocol.reset()
            TestGmailRequestCaptureProtocol.threadListResponseData = Data("""
            {
              "threads": [
                { "id": "thread-id", "snippet": "thread snippet" }
              ],
              "resultSizeEstimate": 1
            }
            """.utf8)
            TestGmailRequestCaptureProtocol.threadGetResponseData = Data("""
            {
              "id": "thread-id",
              "messages": [
                {
                  "id": "message-1",
                  "threadId": "thread-id",
                  "internalDate": "1782936000000",
                  "payload": {
                    "headers": [
                      { "name": "Subject", "value": "First" }
                    ]
                  }
                },
                {
                  "id": "message-2",
                  "threadId": "thread-id",
                  "internalDate": "1782937000000",
                  "payload": {
                    "headers": [
                      { "name": "Subject", "value": "Second" }
                    ]
                  }
                }
              ]
            }
            """.utf8)
            URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
            defer {
                URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
                TestGmailRequestCaptureProtocol.reset()
            }

            let result = try service.searchThreads(accountId: "personal")
            let edges = try #require(result["edges"] as? [[String: Any]])
            let edge = try #require(edges.first)
            let node = try #require(edge["node"] as? [String: Any])
            let messages = try #require(node["messages"] as? [[String: Any]])

            #expect(edge["cursor"] as? String == "thread-id")
            #expect(node["id"] as? String == "thread-id")
            #expect(messages.compactMap { $0["id"] as? String } == ["message-1", "message-2"])
            #expect(TestGmailRequestCaptureProtocol.capturedURLs.map(\.path) == [
                "/gmail/v1/users/me/threads",
                "/gmail/v1/users/me/threads/thread-id"
            ])
        }
    }

    @Test func catalogRuntimeThreadSearchProjectsSelectedFields() async throws {
        let fixture = try GatewayRuntimeFixture()
        defer { fixture.remove() }
        let threadList = Data("""
        {
          "threads": [
            { "id": "thread-id", "snippet": "thread snippet" }
          ],
          "resultSizeEstimate": 1
        }
        """.utf8)
        let threadDetail = Data("""
        {
          "id": "thread-id",
          "messages": [
            {
              "id": "message-id",
              "threadId": "thread-id",
              "internalDate": "1782936000000",
              "payload": {
                "headers": [
                  { "name": "From", "value": "Display Name <person@example.com>" },
                  { "name": "Subject", "value": "Subject" }
                ]
              }
            }
          ]
        }
        """.utf8)
        func configureThreadResponses() {
            TestGmailRequestCaptureProtocol.threadListResponseData = threadList
            TestGmailRequestCaptureProtocol.threadGetResponseData = threadDetail
        }
        TestGmailRequestCaptureProtocol.reset()
        configureThreadResponses()
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }

        let summary = await GmailGatewayGraphQLExecutor().run(
            query: "{ threads(input: { accountId: \"personal\" }) { totalCount } }",
            mode: .reader,
            environment: fixture.environment
        )
        #expect(summary.exitCode == 0)
        let summaryData = try #require(summary.data?.anyValue as? [String: Any])
        let summaryThreads = try #require(summaryData["threads"] as? [String: Any])
        #expect(summaryThreads["totalCount"] as? Int == 1)
        #expect(TestGmailRequestCaptureProtocol.capturedURLs.map(\.path) == [
            "/gmail/v1/users/me/threads"
        ])

        TestGmailRequestCaptureProtocol.reset()
        configureThreadResponses()

        let result = await GmailGatewayGraphQLExecutor().run(
            query: """
            { threads(input: { accountId: "personal" }) { edges { node { id messages { id from { raw address } } } } } }
            """,
            mode: .reader,
            environment: fixture.environment
        )
        #expect(result.exitCode == 0)
        let data = try #require(result.data?.anyValue as? [String: Any])
        let threads = try #require(data["threads"] as? [String: Any])
        let edges = try #require(threads["edges"] as? [[String: Any]])
        let node = try #require(edges.first?["node"] as? [String: Any])
        let messages = try #require(node["messages"] as? [[String: Any]])
        let from = try #require(messages.first?["from"] as? [[String: Any]])
        let expectedFrom = try canonicalJSON([[
            "raw": "Display Name <person@example.com>",
            "address": "Display Name <person@example.com>"
        ]])
        #expect(try canonicalJSON(from) == expectedFrom)
        #expect(TestGmailRequestCaptureProtocol.capturedURLs.map(\.path) == [
            "/gmail/v1/users/me/threads",
            "/gmail/v1/users/me/threads/thread-id"
        ])
    }

    @Test func threadMetadataHydrationPreservesListedSummaryFields() async throws {
        let fixture = try GatewayRuntimeFixture()
        defer { fixture.remove() }
        let threadList = Data("""
        {
          "threads": [
            {
              "id": "thread-id",
              "snippet": "listed snippet",
              "historyId": "listed-history"
            }
          ],
          "resultSizeEstimate": 1
        }
        """.utf8)
        let threadDetail = Data("""
        {
          "id": "thread-id",
          "messages": [
            {
              "id": "message-id",
              "threadId": "thread-id",
              "snippet": "detail snippet",
              "historyId": "detail-history",
              "labelIds": ["INBOX", "Label_1"],
              "payload": { "headers": [] }
            }
          ]
        }
        """.utf8)
        let expectedRequests = [
            "https://gmail.googleapis.com/gmail/v1/users/me/threads?maxResults=1&labelIds=INBOX",
            "https://gmail.googleapis.com/gmail/v1/users/me/threads/thread-id?format=full"
        ]
        let expectedSummary: [String: Any] = [
            "snippet": "listed snippet",
            "providerMetadata": [
                "gmail": [
                    "labelIds": ["INBOX", "Label_1"],
                    "historyId": "listed-history"
                ]
            ]
        ]
        func configureThreadResponses() {
            TestGmailRequestCaptureProtocol.threadListResponseData = threadList
            TestGmailRequestCaptureProtocol.threadGetResponseData = threadDetail
        }
        func node(from query: String) async throws -> [String: Any] {
            let result = await GmailGatewayGraphQLExecutor().run(
                query: query,
                mode: .reader,
                environment: fixture.environment
            )
            #expect(result.exitCode == 0)
            let data = try #require(result.data?.anyValue as? [String: Any])
            let threads = try #require(data["threads"] as? [String: Any])
            let edges = try #require(threads["edges"] as? [[String: Any]])
            return try #require(edges.first?["node"] as? [String: Any])
        }

        TestGmailRequestCaptureProtocol.reset()
        configureThreadResponses()
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }

        let metadataNode = try await node(from: """
        { threads(input: { accountId: "personal", first: 1 }) {
          edges { node { snippet providerMetadata { gmail { labelIds historyId } } } }
        } }
        """)
        #expect(try canonicalJSON(metadataNode) == canonicalJSON(expectedSummary))
        #expect(TestGmailRequestCaptureProtocol.capturedURLs.map(\.absoluteString) == expectedRequests)
        #expect(TestGmailRequestCaptureProtocol.capturedMethods == ["GET", "GET"])

        TestGmailRequestCaptureProtocol.reset()
        configureThreadResponses()

        let detailNode = try await node(from: """
        { threads(input: { accountId: "personal", first: 1 }) {
          edges {
            node {
              snippet
              providerMetadata { gmail { labelIds historyId } }
              messages { id }
            }
          }
        } }
        """)
        let detailSummary: [String: Any] = [
            "snippet": try #require(detailNode["snippet"]),
            "providerMetadata": try #require(detailNode["providerMetadata"])
        ]
        #expect(try canonicalJSON(detailSummary) == canonicalJSON(expectedSummary))
        #expect((try #require(detailNode["messages"] as? [[String: Any]])).first?["id"] as? String == "message-id")
        #expect(TestGmailRequestCaptureProtocol.capturedURLs.map(\.absoluteString) == expectedRequests)
        #expect(TestGmailRequestCaptureProtocol.capturedMethods == ["GET", "GET"])
    }

    @Test func catalogRuntimePreservesProviderErrorCodes() async throws {
        let fixture = try GatewayRuntimeFixture()
        defer { fixture.remove() }
        TestGmailRequestCaptureProtocol.reset()
        TestGmailRequestCaptureProtocol.responseStatusCode = 429
        TestGmailRequestCaptureProtocol.responseData = Data(#"{"error":{"message":"rate limited"}}"#.utf8)
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }

        let result = await GmailGatewayGraphQLExecutor().run(
            query: "{ threads(input: { accountId: \"personal\" }) { totalCount } }",
            mode: .reader,
            environment: fixture.environment
        )
        #expect(result.exitCode == GmailGatewayExitCode.generalError.rawValue)
        #expect(result.errors.first?.code == GmailGatewayErrorCode.providerRateLimited.rawValue)
    }

    @Test func catalogRuntimeProjectsCompleteProfileAndFiltersMalformedLabels() async throws {
        let fixture = try GatewayRuntimeFixture()
        defer { fixture.remove() }
        TestGmailRequestCaptureProtocol.reset()
        TestGmailRequestCaptureProtocol.profileResponseData = Data("""
        {
          "emailAddress": "profile@example.com",
          "messagesTotal": 17,
          "threadsTotal": 9,
          "historyId": "history-17"
        }
        """.utf8)
        TestGmailRequestCaptureProtocol.labelListResponseData = Data("""
        {
          "labels": [
            {
              "id": "Label_1",
              "name": "Visible",
              "type": "user",
              "messageListVisibility": "show",
              "labelListVisibility": "labelShow"
            },
            {
              "name": "Malformed",
              "type": "user",
              "messageListVisibility": "hide",
              "labelListVisibility": "labelHide"
            }
          ]
        }
        """.utf8)
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }

        let profile = await GmailGatewayGraphQLExecutor().run(
            query: "{ profile(accountId: \"personal\") { accountId emailAddress messagesTotal threadsTotal historyId } }",
            mode: .reader,
            environment: fixture.environment
        )
        #expect(profile.exitCode == 0)
        #expect(profile.errors.isEmpty)
        #expect(profile.data == .object(["profile": .object([
            "accountId": .string("personal"),
            "emailAddress": .string("profile@example.com"),
            "messagesTotal": .int(17),
            "threadsTotal": .int(9),
            "historyId": .string("history-17")
        ])]))
        #expect(TestGmailRequestCaptureProtocol.capturedURLs.map(\.path) == ["/gmail/v1/users/me/profile"])

        TestGmailRequestCaptureProtocol.capturedURLs = []
        TestGmailRequestCaptureProtocol.capturedMethods = []
        let labels = await GmailGatewayGraphQLExecutor().run(
            query: "{ labels(accountId: \"personal\") { id accountId name type messageListVisibility labelListVisibility } }",
            mode: .reader,
            environment: fixture.environment
        )
        #expect(labels.exitCode == 0)
        #expect(labels.errors.isEmpty)
        #expect(labels.data == .object(["labels": .array([.object([
            "id": .string("Label_1"),
            "accountId": .string("personal"),
            "name": .string("Visible"),
            "type": .string("user"),
            "messageListVisibility": .string("show"),
            "labelListVisibility": .string("labelShow")
        ])])]))
        #expect(TestGmailRequestCaptureProtocol.capturedURLs.map(\.path) == ["/gmail/v1/users/me/labels"])
    }

    @Test func directMessageReadDoesNotInlineBodies() throws {
        try withReaderService(tokenStoreJSON: readableTokenStoreJSON) { service, _ in
            TestGmailRequestCaptureProtocol.reset()
            TestGmailRequestCaptureProtocol.responseData = Data("""
            {
              "id": "message-id",
              "threadId": "thread-id",
              "payload": {
                "mimeType": "multipart/alternative",
                "parts": [
                  {
                    "mimeType": "text/plain",
                    "body": {
                      "size": 19,
                      "data": "cHJpdmF0ZSB0ZXh0IGJvZHk"
                    }
                  },
                  {
                    "mimeType": "text/html",
                    "body": {
                      "size": 26,
                      "data": "PHA-cHJpdmF0ZSBodG1sIGJvZHk8L3A-"
                    }
                  }
                ]
              }
            }
            """.utf8)
            URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
            defer {
                URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
                TestGmailRequestCaptureProtocol.reset()
            }

            let message = try #require(try service.getMessage(
                accountId: "personal",
                messageId: "message-id"
            ) as? [String: Any])

            #expect(message["textBody"] is NSNull)
            #expect(message["htmlBody"] is NSNull)
            #expect(!"\(message)".contains("private text body"))
            #expect(!"\(message)".contains("private html body"))
        }
    }

    @Test func threadReadDoesNotInlineNestedMessageBodies() throws {
        try withReaderService(tokenStoreJSON: readableTokenStoreJSON) { service, _ in
            TestGmailRequestCaptureProtocol.reset()
            TestGmailRequestCaptureProtocol.threadGetResponseData = Data("""
            {
              "id": "thread-id",
              "messages": [
                {
                  "id": "message-id",
                  "threadId": "thread-id",
                  "payload": {
                    "mimeType": "multipart/alternative",
                    "parts": [
                      {
                        "mimeType": "text/plain",
                        "body": {
                          "size": 19,
                          "data": "cHJpdmF0ZSB0ZXh0IGJvZHk"
                        }
                      },
                      {
                        "mimeType": "text/html",
                        "body": {
                          "size": 26,
                          "data": "PHA-cHJpdmF0ZSBodG1sIGJvZHk8L3A-"
                        }
                      }
                    ]
                  }
                }
              ]
            }
            """.utf8)
            URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
            defer {
                URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
                TestGmailRequestCaptureProtocol.reset()
            }

            let thread = try #require(try service.getThread(
                accountId: "personal",
                threadId: "thread-id"
            ) as? [String: Any])
            let messages = try #require(thread["messages"] as? [[String: Any]])
            let message = try #require(messages.first)

            #expect(message["textBody"] is NSNull)
            #expect(message["htmlBody"] is NSNull)
            #expect(!"\(thread)".contains("private text body"))
            #expect(!"\(thread)".contains("private html body"))
        }
    }

    @Test func threadSearchWithoutNodeDetailsDoesNotFetchThreadBodies() throws {
        try withReaderService(tokenStoreJSON: readableTokenStoreJSON) { service, _ in
            TestGmailRequestCaptureProtocol.reset()
            TestGmailRequestCaptureProtocol.threadListResponseData = Data("""
            {
              "threads": [
                { "id": "thread-id" }
              ],
              "resultSizeEstimate": 1
            }
            """.utf8)
            URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
            defer {
                URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
                TestGmailRequestCaptureProtocol.reset()
            }

            let result = try service.searchThreads(
                accountId: "personal",
                includeNodeDetails: false
            )
            let edges = try #require(result["edges"] as? [[String: Any]])

            #expect(edges.first?["cursor"] as? String == "thread-id")
            #expect(edges.first?["node"] == nil)
            #expect(TestGmailRequestCaptureProtocol.capturedURLs.map(\.path) == ["/gmail/v1/users/me/threads"])
        }
    }

    @Test func attachmentMetadataDoesNotFetchAttachmentPayload() throws {
        try withReaderService(tokenStoreJSON: readableTokenStoreJSON) { service, _ in
            TestGmailRequestCaptureProtocol.reset()
            TestGmailRequestCaptureProtocol.responseData = Data("""
            {
              "id": "message-id",
              "threadId": "thread-id",
              "internalDate": "1782936000000",
              "payload": {
                "mimeType": "multipart/mixed",
                "parts": [
                  {
                    "partId": "1",
                    "filename": "report.pdf",
                    "mimeType": "application/pdf",
                    "body": {
                      "attachmentId": "attachment-id",
                      "size": 123
                    }
                  }
                ]
              }
            }
            """.utf8)
            TestGmailRequestCaptureProtocol.failAttachmentPayloadRequests = true
            URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
            defer {
                URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
                TestGmailRequestCaptureProtocol.reset()
            }

            let attachment = try #require(try service.getAttachment(
                accountId: "personal",
                messageId: "message-id",
                attachmentId: "attachment-id"
            ) as? [String: Any])

            #expect(attachment["filename"] as? String == "report.pdf")
            #expect(attachment["sizeBytes"] as? Int == 123)
        }
    }

    @Test func messageFileSetExposesRemoteBodiesAndDownloadMaterializesSelectedBody() throws {
        try withReaderService(tokenStoreJSON: readableTokenStoreJSON) { service, paths in
            TestGmailRequestCaptureProtocol.reset()
            TestGmailRequestCaptureProtocol.responseData = Data("""
            {
              "id": "message-id",
              "threadId": "thread-id",
              "payload": {
                "mimeType": "multipart/alternative",
                "parts": [
                  {
                    "mimeType": "text/plain",
                    "body": {
                      "size": 16,
                      "data": "cmVtb3RlIHRleHQgYm9keQ"
                    }
                  },
                  {
                    "mimeType": "text/html",
                    "body": {
                      "size": 23,
                      "data": "PHA-cmVtb3RlIGh0bWwgYm9keTwvcD4"
                    }
                  }
                ]
              }
            }
            """.utf8)
            URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
            defer {
                URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
                TestGmailRequestCaptureProtocol.reset()
            }

            let fileSet = try service.getMessageFileSet(accountId: "personal", messageId: "message-id")
            let files = try #require(fileSet["files"] as? [[String: Any]])
            let textFile = try #require(files.first { $0["kind"] as? String == "BODY_TEXT" })
            let htmlFile = try #require(files.first { $0["kind"] as? String == "BODY_HTML" })

            #expect(textFile["filename"] as? String == "body.txt")
            #expect(textFile["sizeBytes"] as? Int == "remote text body".utf8.count)
            #expect(textFile["materializationState"] as? String == AttachmentMaterializationState.notMaterialized.rawValue)
            #expect(textFile["localPath"] == nil)
            #expect(htmlFile["filename"] as? String == "body.html")
            #expect(htmlFile["localPath"] == nil)

            let downloadKey = try #require(textFile["downloadKey"] as? String)
            let outputDirectory = URL(fileURLWithPath: paths.cacheDir)
                .appendingPathComponent("downloads", isDirectory: true)
                .path
            let downloaded = try service.downloadFile(downloadKey: downloadKey, outputDirectory: outputDirectory)
            let localPath = try #require(downloaded["localPath"] as? String)
            let contents = try String(contentsOfFile: localPath, encoding: .utf8)

            #expect(downloaded["kind"] as? String == "BODY_TEXT")
            #expect(contents == "remote text body")
        }
    }

    @Test func cachedAttachmentRetainsDownloadMetadataForRuntimeNormalization() throws {
        let paths = temporaryConfigPaths()
        defer {
            try? FileManager.default.removeItem(atPath: paths.root)
        }
        let messageDirectory = URL(fileURLWithPath: paths.attachmentDir)
            .appendingPathComponent("personal", isDirectory: true)
            .appendingPathComponent("message-id", isDirectory: true)
        try FileManager.default.createDirectory(at: messageDirectory, withIntermediateDirectories: true)
        let attachmentURL = messageDirectory.appendingPathComponent(gmailGatewayAttachmentStorageFilename(
            attachmentId: "attachment-id",
            filename: "report.pdf"
        ))
        try "cached attachment".write(to: attachmentURL, atomically: true, encoding: .utf8)

        let attachment = try #require(
            GmailGatewayService(config: testConfig(paths: paths)).getAttachment(
                accountId: "personal",
                messageId: "message-id",
                attachmentId: "attachment-id"
            ) as? [String: Any]
        )

        #expect(attachment["filename"] as? String == "report.pdf")
        #expect(attachment["localPath"] is String)
        #expect(attachment["downloadKey"] is String)
    }

    @Test func invalidMessageFileDownloadKeyUsesSpecificErrorTaxonomy() throws {
        try withReaderService { service, _ in
            let error = try requireGmailGatewayError {
                _ = try service.downloadFile(downloadKey: "not-a-download-key", outputDirectory: nil)
            }

            #expect(error.code == .invalidDownloadKey)
            #expect(error.exitCode == .generalError)
        }
    }

    @Test func attachmentDownloadKeyWithoutAttachmentIdUsesSpecificErrorTaxonomy() throws {
        let key = encodeMessageFileDownloadKey(MessageFileDownloadKey(
            accountId: "personal",
            messageId: "message-id",
            kind: .attachment,
            filename: "report.pdf",
            attachmentId: nil,
            mimeType: "application/pdf"
        ))

        let error = try requireGmailGatewayError {
            _ = try decodeMessageFileDownloadKey(key)
        }

        #expect(error.code == .invalidDownloadKey)
        #expect(error.exitCode == .generalError)
    }

    @Test func providerRateLimitUsesSpecificErrorTaxonomy() throws {
        TestGmailRequestCaptureProtocol.reset()
        TestGmailRequestCaptureProtocol.responseStatusCode = 429
        TestGmailRequestCaptureProtocol.responseData = Data(#"{"error":{"message":"rate limited"}}"#.utf8)
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }

        try withReaderService(tokenStoreJSON: readableTokenStoreJSON) { service, _ in
            let error = try requireGmailGatewayError {
                _ = try service.searchThreads(accountId: "personal")
            }
            #expect(error.code == .providerRateLimited)
            #expect(error.exitCode == .providerApiError)
        }
    }

    @Test func providerErrorDetailsUseGoogleErrorFieldsWhenAvailable() throws {
        TestGmailRequestCaptureProtocol.reset()
        TestGmailRequestCaptureProtocol.responseStatusCode = 403
        TestGmailRequestCaptureProtocol.responseData = Data("""
        {
          "error": {
            "code": 403,
            "message": "quota exceeded",
            "status": "PERMISSION_DENIED",
            "errors": [
              { "reason": "dailyLimitExceeded", "message": "raw provider details" }
            ]
          }
        }
        """.utf8)
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }

        let request = URLRequest(url: URL(string: "https://gmail.googleapis.com/test")!)
        let error = try requireGmailGatewayError {
            _ = try performGmailHTTPRequest(request, context: "Gmail request failed")
        }

        #expect(error.code == .providerApiError)
        #expect(error.details["httpStatus"] == "403")
        #expect(error.details["providerErrorStatus"] == "PERMISSION_DENIED")
        #expect(error.details["providerErrorMessage"] == "quota exceeded")
        #expect(error.details["providerErrorReason"] == "dailyLimitExceeded")
        #expect(error.details["body"] == nil)
    }

    @Test func idempotentGmailGetRetriesRateLimitAndServerErrors() throws {
        try withReaderService(tokenStoreJSON: readableTokenStoreJSON) { service, _ in
            TestGmailRequestCaptureProtocol.reset()
            TestGmailRequestCaptureProtocol.responseStatusCodes = [429, 500, 200]
            URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
            defer {
                URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
                TestGmailRequestCaptureProtocol.reset()
            }

            _ = try service.searchThreads(
                accountId: "personal",
                includeEdges: false,
                includeNodeDetails: false
            )

            #expect(TestGmailRequestCaptureProtocol.capturedURLs.count == 3)
        }
    }

    @Test func nonIdempotentGmailPostDoesNotRetryServerError() throws {
        TestGmailRequestCaptureProtocol.reset()
        TestGmailRequestCaptureProtocol.responseStatusCodes = [500, 200]
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/test")!)
        request.httpMethod = "POST"

        let error = try requireGmailGatewayError {
            _ = try performGmailHTTPRequest(request, context: "Gmail POST failed")
        }

        #expect(error.code == .providerApiError)
        #expect(TestGmailRequestCaptureProtocol.capturedURLs.count == 1)
    }

    @Test func sendMessageReportsRejectedAttachmentsAndSendsOnlyValidFiles() throws {
        let paths = temporaryConfigPaths()
        defer {
            try? FileManager.default.removeItem(atPath: paths.root)
        }
        try FileManager.default.createDirectory(atPath: paths.sendDir, withIntermediateDirectories: true)
        let validAttachment = URL(fileURLWithPath: paths.sendDir).appendingPathComponent("valid.txt")
        try Data("valid attachment".utf8).write(to: validAttachment)
        let outsideAttachment = URL(fileURLWithPath: paths.root).appendingPathComponent("outside.txt")
        try Data("outside attachment".utf8).write(to: outsideAttachment)
        let missingAttachment = URL(fileURLWithPath: paths.sendDir).appendingPathComponent("missing.txt")
        let config = testConfig(paths: paths, accessMode: .readSend, tokenStoreJSON: sendTokenStoreJSON)

        TestGmailRequestCaptureProtocol.reset()
        TestGmailRequestCaptureProtocol.responseData = Data(#"{"id":"sent-id","threadId":"thread-id"}"#.utf8)
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }

        let result = try GmailGatewayWriteService(config: config).sendMessage(
            input: OutboundMailInput(
                accountId: "personal",
                to: ["recipient@example.com"],
                textBody: "Body",
                attachmentPaths: [validAttachment.path, outsideAttachment.path, missingAttachment.path]
            ),
            mode: .directSend
        )
        let rejected = try #require(result["rejectedAttachments"] as? [[String: String]])
        let rawMessage = try sentRawMessage()

        #expect(result["status"] as? String == "SENT")
        #expect(rejected.count == 2)
        #expect(rejected.contains { $0["path"] == outsideAttachment.path && $0["code"] == GmailGatewayErrorCode.configInvalid.rawValue })
        #expect(rejected.contains { $0["path"] == missingAttachment.path && $0["code"] == GmailGatewayErrorCode.attachmentNotFound.rawValue })
        #expect(rawMessage.contains("Content-Disposition: attachment; filename=\"valid.txt\""))
        #expect(!rawMessage.contains("outside.txt"))
        #expect(!rawMessage.contains("missing.txt"))
    }

    @Test func sendMessageWithOnlyRejectedAttachmentsStillSendsBodyWithoutMultipartAttachments() throws {
        let paths = temporaryConfigPaths()
        defer {
            try? FileManager.default.removeItem(atPath: paths.root)
        }
        try FileManager.default.createDirectory(atPath: paths.sendDir, withIntermediateDirectories: true)
        let missingAttachment = URL(fileURLWithPath: paths.sendDir).appendingPathComponent("missing.txt")
        let config = testConfig(paths: paths, accessMode: .readSend, tokenStoreJSON: sendTokenStoreJSON)

        TestGmailRequestCaptureProtocol.reset()
        TestGmailRequestCaptureProtocol.responseData = Data(#"{"id":"sent-id","threadId":"thread-id"}"#.utf8)
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }

        let result = try GmailGatewayWriteService(config: config).sendMessage(
            input: OutboundMailInput(
                accountId: "personal",
                to: ["recipient@example.com"],
                textBody: "Body",
                attachmentPaths: [missingAttachment.path]
            ),
            mode: .directSend
        )
        let rejected = try #require(result["rejectedAttachments"] as? [[String: String]])
        let rawMessage = try sentRawMessage()

        #expect(result["status"] as? String == "SENT")
        #expect(rejected.count == 1)
        #expect(rejected.first?["code"] == GmailGatewayErrorCode.attachmentNotFound.rawValue)
        #expect(rawMessage.contains("Content-Type: text/plain; charset=utf-8"))
        #expect(!rawMessage.contains("Content-Disposition: attachment"))
        #expect(!rawMessage.contains("multipart/mixed"))
    }
}

private func sentRawMessage() throws -> String {
    let body = try #require(TestGmailRequestCaptureProtocol.capturedHTTPBodies.last)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let raw = try #require(object["raw"] as? String)
    let data = try #require(dataFromBase64URLString(raw))
    return try #require(String(data: data, encoding: .utf8))
}
