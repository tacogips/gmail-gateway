import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import MailGatewayCore
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

    @Test func graphQLThreadSearchSummaryNodeDoesNotFetchFullThreads() throws {
        let paths = temporaryConfigPaths()
        defer {
            try? FileManager.default.removeItem(atPath: paths.root)
        }
        TestGmailRequestCaptureProtocol.reset()
        TestGmailRequestCaptureProtocol.threadListResponseData = Data("""
        {
          "threads": [
            {
              "id": "thread-id",
              "snippet": "thread snippet",
              "historyId": "history-id"
            }
          ],
          "resultSizeEstimate": 1
        }
        """.utf8)
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }

        let result = try executeReaderGraphQL(
            config: testConfig(paths: paths, tokenStoreJSON: readableTokenStoreJSON),
            query: """
            { threads(accountId: "personal") { edges { cursor node { id accountId snippet providerMetadata } } } }
            """
        )
        let data = try #require(result.body["data"] as? [String: Any])
        let threads = try #require(data["threads"] as? [String: Any])
        let edges = try #require(threads["edges"] as? [[String: Any]])
        let node = try #require(edges.first?["node"] as? [String: Any])

        #expect(result.exitCode == .success)
        #expect(node["id"] as? String == "thread-id")
        #expect(node["snippet"] as? String == "thread snippet")
        #expect(TestGmailRequestCaptureProtocol.capturedURLs.map(\.path) == ["/gmail/v1/users/me/threads"])
    }

    @Test func graphQLThreadSearchMessagesSelectionFetchesFullThreads() throws {
        let paths = temporaryConfigPaths()
        defer {
            try? FileManager.default.removeItem(atPath: paths.root)
        }
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
              "id": "message-id",
              "threadId": "thread-id",
              "internalDate": "1782936000000",
              "payload": {
                "headers": [
                  { "name": "Subject", "value": "Subject" }
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

        let result = try executeReaderGraphQL(
            config: testConfig(paths: paths, tokenStoreJSON: readableTokenStoreJSON),
            query: """
            { threads(accountId: "personal") { edges { node { id messages { id } } } } }
            """
        )
        let data = try #require(result.body["data"] as? [String: Any])
        let threads = try #require(data["threads"] as? [String: Any])
        let edges = try #require(threads["edges"] as? [[String: Any]])
        let node = try #require(edges.first?["node"] as? [String: Any])
        let messages = try #require(node["messages"] as? [[String: Any]])

        #expect(result.exitCode == .success)
        #expect(messages.first?["id"] as? String == "message-id")
        #expect(TestGmailRequestCaptureProtocol.capturedURLs.map(\.path) == [
            "/gmail/v1/users/me/threads",
            "/gmail/v1/users/me/threads/thread-id"
        ])
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

    @Test func graphQLCachedAttachmentDoesNotExposeLocalPathWhenRequested() throws {
        let paths = temporaryConfigPaths()
        defer {
            try? FileManager.default.removeItem(atPath: paths.root)
        }
        let messageDirectory = URL(fileURLWithPath: paths.attachmentDir)
            .appendingPathComponent("personal", isDirectory: true)
            .appendingPathComponent("message-id", isDirectory: true)
        try FileManager.default.createDirectory(at: messageDirectory, withIntermediateDirectories: true)
        let attachmentURL = messageDirectory.appendingPathComponent(mailGatewayAttachmentStorageFilename(
            attachmentId: "attachment-id",
            filename: "report.pdf"
        ))
        try "cached attachment".write(to: attachmentURL, atomically: true, encoding: .utf8)

        let result = try executeReaderGraphQL(
            config: testConfig(paths: paths),
            query: """
            { attachment(accountId: "personal", messageId: "message-id", attachmentId: "attachment-id") \
            { id filename localPath downloadKey materializationState } }
            """
        )
        let data = try #require(result.body["data"] as? [String: Any])
        let attachment = try #require(data["attachment"] as? [String: Any])

        #expect(result.exitCode == .success)
        #expect(attachment["filename"] as? String == "report.pdf")
        #expect(attachment["localPath"] == nil)
        #expect(attachment["downloadKey"] is String)
    }

    @Test func invalidMessageFileDownloadKeyUsesSpecificErrorTaxonomy() throws {
        try withReaderService { service, _ in
            let error = try requireMailGatewayError {
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

        let error = try requireMailGatewayError {
            _ = try decodeMessageFileDownloadKey(key)
        }

        #expect(error.code == .invalidDownloadKey)
        #expect(error.exitCode == .generalError)
    }

    @Test func providerRateLimitReturnsGraphQLErrorBody() throws {
        let paths = temporaryConfigPaths()
        defer {
            try? FileManager.default.removeItem(atPath: paths.root)
        }
        let config = testConfig(paths: paths, tokenStoreJSON: readableTokenStoreJSON)
        TestGmailRequestCaptureProtocol.reset()
        TestGmailRequestCaptureProtocol.responseStatusCode = 429
        TestGmailRequestCaptureProtocol.responseData = Data(#"{"error":{"message":"rate limited"}}"#.utf8)
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }

        let result = try executeReaderGraphQL(
            config: config,
            query: #"{ threads(input: { accountId: "personal" }) { totalCount } }"#
        )

        #expect(result.exitCode == .graphqlExecutionError)
        #expect("\(result.body)".contains(MailGatewayErrorCode.providerRateLimited.rawValue))
        #expect("\(result.body)".contains(String(MailGatewayExitCode.providerApiError.rawValue)))
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
        let error = try requireMailGatewayError {
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

        let error = try requireMailGatewayError {
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

        let result = try MailGatewayWriteService(config: config).sendMessage(
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
        #expect(rejected.contains { $0["path"] == outsideAttachment.path && $0["code"] == MailGatewayErrorCode.configInvalid.rawValue })
        #expect(rejected.contains { $0["path"] == missingAttachment.path && $0["code"] == MailGatewayErrorCode.attachmentNotFound.rawValue })
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

        let result = try MailGatewayWriteService(config: config).sendMessage(
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
        #expect(rejected.first?["code"] == MailGatewayErrorCode.attachmentNotFound.rawValue)
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
