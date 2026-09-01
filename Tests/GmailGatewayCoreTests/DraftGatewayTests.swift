import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GmailGatewayCore
import Testing

// Nested inside the serialized GmailRequestProtocolTests suite so these tests never run
// concurrently with the other tests that share TestGmailRequestCaptureProtocol global state.
extension GmailRequestProtocolTests {
    @Suite(.serialized)
    struct DraftGatewayTests {
        private let sendTokenStoreJSON = """
        {
          "accessMode": "read_send",
          "accessToken": "test-access-token",
          "refreshToken": null,
          "tokenType": "Bearer",
          "scope": "https://www.googleapis.com/auth/gmail.modify",
          "expiresAt": "2999-01-01T00:00:00Z",
          "emailAddress": "person@example.com"
        }
        """

        // MARK: - Binary capability boundaries

        @Test func draftGatewayRejectsSendMutations() throws {
            let queries = [
                #"mutation { sendMessage(accountId: "personal", to: ["a@example.com"], textBody: "Body") { status } }"#,
                #"mutation { replyMessage(accountId: "personal", messageId: "m1", textBody: "Body") { status } }"#,
                #"mutation { forwardMessage(accountId: "personal", messageId: "m1", to: ["a@example.com"]) { status } }"#
            ]
            try withDraftConfig { config, _ in
                for query in queries {
                    let result = try executeWriteGraphQL(config: config, query: query, mode: .draftDefault)

                    #expect(result.exitCode == .graphqlExecutionError)
                    #expect(graphQLErrorCode(result.body) == GmailGatewayErrorCode.sendDisabledInDraftGateway.rawValue)
                }
            }
        }

        @Test func draftGatewayRejectsAliasedSendMutation() throws {
            try withDraftConfig { config, _ in
                let result = try executeWriteGraphQL(
                    config: config,
                    query: #"mutation { out: sendMessage(accountId: "personal", to: ["a@example.com"], textBody: "B") { status } }"#,
                    mode: .draftDefault
                )

                #expect(graphQLErrorCode(result.body) == GmailGatewayErrorCode.sendDisabledInDraftGateway.rawValue)
            }
        }

        @Test func senderGatewayStillAllowsSendMutations() throws {
            try withDraftConfig { config, _ in
                TestGmailRequestCaptureProtocol.reset()
                TestGmailRequestCaptureProtocol.responseData = Data(#"{"id":"sent-id","threadId":"thread-id"}"#.utf8)
                URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
                defer {
                    URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
                    TestGmailRequestCaptureProtocol.reset()
                }

                let result = try executeWriteGraphQL(
                    config: config,
                    query: #"mutation { sendMessage(accountId: "personal", to: ["a@example.com"], textBody: "Body") { status } }"#,
                    mode: .directSend
                )
                let data = try #require(result.body["data"] as? [String: Any])
                let payload = try #require(data["sendMessage"] as? [String: Any])

                #expect(result.exitCode == .success)
                #expect(payload["status"] as? String == "SENT")
                #expect(TestGmailRequestCaptureProtocol.capturedURLs.map(\.path) == ["/gmail/v1/users/me/messages/send"])
            }
        }

        @Test func readerRejectsDraftMutationsAndDraftQueries() throws {
            let queries = [
                #"mutation { updateDraft(accountId: "personal", draftId: "d1", subject: "New") { status } }"#,
                #"mutation { deleteDraft(accountId: "personal", draftId: "d1") { status } }"#,
                #"query { drafts(accountId: "personal") { totalCount } }"#,
                #"query { draft(accountId: "personal", draftId: "d1") { id } }"#
            ]
            try withDraftConfig { config, _ in
                for query in queries {
                    let result = try executeReaderGraphQL(config: config, query: query)

                    #expect(result.exitCode == .graphqlExecutionError)
                    #expect(graphQLErrorCode(result.body) == GmailGatewayErrorCode.sendDisabledInReader.rawValue)
                }
            }
        }

        // MARK: - updateDraft

        @Test func updateDraftRetainsOmittedHeadersBodyAndAttachments() throws {
            try withDraftConfig { config, _ in
                try withDraftProviderResponses {
                    let result = try GmailGatewayWriteService(config: config).updateDraft(
                        input: UpdateDraftInput(accountId: "personal", draftId: "draft-1", subject: "Updated subject")
                    )
                    let rawMessage = try updatedDraftRawMessage()

                    #expect(result["operation"] as? String == "UPDATE_DRAFT")
                    #expect(result["status"] as? String == "DRAFT_UPDATED")
                    #expect(result["draftId"] as? String == "draft-1")
                    #expect(result["messageId"] as? String == "message-1")
                    #expect(rawMessage.contains("Subject: Updated subject"))
                    #expect(rawMessage.contains("To: recipient@example.com"))
                    #expect(rawMessage.contains("Cc: copied@example.com"))
                    #expect(rawMessage.contains("In-Reply-To: <origin@mail.example.com>"))
                    #expect(rawMessage.contains("References: <root@mail.example.com>"))
                    #expect(rawMessage.contains("Existing draft text"))
                    #expect(rawMessage.contains("filename=\"keep.txt\""))
                }
            }
        }

        @Test func updateDraftUsesProviderPutOnTheSameDraftIdAndThread() throws {
            try withDraftConfig { config, _ in
                try withDraftProviderResponses {
                    _ = try GmailGatewayWriteService(config: config).updateDraft(
                        input: UpdateDraftInput(accountId: "personal", draftId: "draft-1", subject: "Updated subject")
                    )
                    let request = try updatedDraftRequestBody()
                    let message = try #require(request["message"] as? [String: Any])

                    #expect(TestGmailRequestCaptureProtocol.capturedMethods.last == "PUT")
                    #expect(TestGmailRequestCaptureProtocol.capturedURLs.last?.path == "/gmail/v1/users/me/drafts/draft-1")
                    #expect(request["id"] as? String == "draft-1")
                    #expect(message["threadId"] as? String == "thread-1")
                }
            }
        }

        @Test func updateDraftReplacesAttachmentsWhenKeepAttachmentIdsIsEmpty() throws {
            try withDraftConfig { config, paths in
                let replacement = try writeSendAttachment(paths: paths, filename: "replacement.txt")
                try withDraftProviderResponses {
                    _ = try GmailGatewayWriteService(config: config).updateDraft(
                        input: UpdateDraftInput(
                            accountId: "personal",
                            draftId: "draft-1",
                            attachmentPaths: [replacement.path],
                            keepAttachmentIds: []
                        )
                    )
                    let rawMessage = try updatedDraftRawMessage()

                    #expect(rawMessage.contains("filename=\"replacement.txt\""))
                    #expect(!rawMessage.contains("keep.txt"))
                }
            }
        }

        @Test func updateDraftKeepsOnlyRequestedAttachmentIds() throws {
            try withDraftConfig { config, _ in
                try withDraftProviderResponses {
                    _ = try GmailGatewayWriteService(config: config).updateDraft(
                        input: UpdateDraftInput(
                            accountId: "personal",
                            draftId: "draft-1",
                            keepAttachmentIds: ["attachment-keep"]
                        )
                    )
                    let rawMessage = try updatedDraftRawMessage()

                    #expect(rawMessage.contains("filename=\"keep.txt\""))
                    #expect(!rawMessage.contains("drop.txt"))
                }
            }
        }

        @Test func updateDraftRejectsUnknownKeepAttachmentIdsBeforeProviderWrite() throws {
            try withDraftConfig { config, _ in
                try withDraftProviderResponses {
                    let error = try requireGmailGatewayError {
                        _ = try GmailGatewayWriteService(config: config).updateDraft(
                            input: UpdateDraftInput(
                                accountId: "personal",
                                draftId: "draft-1",
                                keepAttachmentIds: ["attachment-missing"]
                            )
                        )
                    }

                    #expect(error.code == .attachmentNotFound)
                    #expect(error.details["keepAttachmentIds"] == "attachment-missing")
                    #expect(!TestGmailRequestCaptureProtocol.capturedMethods.contains("PUT"))
                }
            }
        }

        @Test func updateDraftBodyReplacementDropsStaleHTMLPart() throws {
            try withDraftConfig { config, _ in
                try withDraftProviderResponses {
                    _ = try GmailGatewayWriteService(config: config).updateDraft(
                        input: UpdateDraftInput(
                            accountId: "personal",
                            draftId: "draft-1",
                            textBody: "Replacement text"
                        )
                    )
                    let rawMessage = try updatedDraftRawMessage()

                    #expect(rawMessage.contains("Replacement text"))
                    #expect(!rawMessage.contains("Existing draft text"))
                    #expect(!rawMessage.contains("<p>Existing draft html</p>"))
                }
            }
        }

        @Test func updateDraftRejectsBlankDraftIdBeforeProviderCall() throws {
            try withDraftConfig { config, _ in
                try withDraftProviderResponses {
                    let error = try requireGmailGatewayError {
                        _ = try GmailGatewayWriteService(config: config).updateDraft(
                            input: UpdateDraftInput(accountId: "personal", draftId: "  ", subject: "New")
                        )
                    }

                    #expect(error.code == .invalidArgument)
                    #expect(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty)
                }
            }
        }

        @Test func updateDraftRejectsRemovingEveryRecipient() throws {
            try withDraftConfig { config, _ in
                try withDraftProviderResponses {
                    let error = try requireGmailGatewayError {
                        _ = try GmailGatewayWriteService(config: config).updateDraft(
                            input: UpdateDraftInput(accountId: "personal", draftId: "draft-1", to: [], cc: [], bcc: [])
                        )
                    }

                    #expect(error.code == .invalidArgument)
                    #expect(!TestGmailRequestCaptureProtocol.capturedMethods.contains("PUT"))
                    #expect(!TestGmailRequestCaptureProtocol.capturedURLs.contains { $0.path.contains("/attachments/") })
                }
            }
        }

        @Test func updateDraftRejectsUnsupportedGraphQLArguments() throws {
            try withDraftConfig { config, _ in
                let result = try executeWriteGraphQL(
                    config: config,
                    query: #"mutation { updateDraft(accountId: "personal", draftId: "draft-1", labelIds: ["INBOX"]) { status } }"#,
                    mode: .draftDefault
                )

                #expect(result.exitCode == .graphqlExecutionError)
                #expect(graphQLErrorCode(result.body) == GmailGatewayErrorCode.invalidArgument.rawValue)
            }
        }

        // MARK: - deleteDraft

        @Test func deleteDraftIssuesProviderDeleteAndReportsDraftId() throws {
            try withDraftConfig { config, _ in
                TestGmailRequestCaptureProtocol.reset()
                URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
                defer {
                    URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
                    TestGmailRequestCaptureProtocol.reset()
                }

                let result = try GmailGatewayWriteService(config: config).deleteDraft(
                    accountId: "personal",
                    draftId: "draft-1"
                )

                #expect(result["operation"] as? String == "DELETE_DRAFT")
                #expect(result["status"] as? String == "DRAFT_DELETED")
                #expect(result["draftId"] as? String == "draft-1")
                #expect(TestGmailRequestCaptureProtocol.capturedMethods == ["DELETE"])
                #expect(TestGmailRequestCaptureProtocol.capturedURLs.map(\.path) == ["/gmail/v1/users/me/drafts/draft-1"])
            }
        }

        // MARK: - draft reads

        @Test func draftQueryReturnsProviderDraftMetadata() throws {
            try withDraftConfig { config, _ in
                try withDraftProviderResponses {
                    let result = try executeWriteGraphQL(
                        config: config,
                        query: #"query { draft(accountId: "personal", draftId: "draft-1") { id } }"#,
                        mode: .draftDefault
                    )
                    let data = try #require(result.body["data"] as? [String: Any])
                    let draft = try #require(data["draft"] as? [String: Any])
                    let message = try #require(draft["message"] as? [String: Any])

                    #expect(draft["id"] as? String == "draft-1")
                    #expect(draft["accountId"] as? String == "personal")
                    #expect(message["id"] as? String == "message-1")
                }
            }
        }

        @Test func draftsQuerySkipsNodeHydrationWhenNodesAreNotSelected() throws {
            try withDraftConfig { config, _ in
                try withDraftProviderResponses {
                    let result = try executeWriteGraphQL(
                        config: config,
                        query: #"query { drafts(accountId: "personal", first: 5) { totalCount pageInfo { hasNextPage } } }"#,
                        mode: .draftDefault
                    )
                    let data = try #require(result.body["data"] as? [String: Any])
                    let drafts = try #require(data["drafts"] as? [String: Any])

                    #expect(drafts["totalCount"] as? Int == 1)
                    #expect(TestGmailRequestCaptureProtocol.capturedURLs.map(\.path) == ["/gmail/v1/users/me/drafts"])
                }
            }
        }

        @Test func draftsQueryRejectsOutOfRangeFirstBeforeProviderCall() throws {
            try withDraftConfig { config, _ in
                TestGmailRequestCaptureProtocol.reset()
                URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
                defer {
                    URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
                    TestGmailRequestCaptureProtocol.reset()
                }

                let result = try executeWriteGraphQL(
                    config: config,
                    query: #"query { drafts(accountId: "personal", first: 0) { totalCount } }"#,
                    mode: .draftDefault
                )

                #expect(result.exitCode == .graphqlExecutionError)
                #expect(graphQLErrorCode(result.body) == GmailGatewayErrorCode.invalidArgument.rawValue)
                #expect(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty)
            }
        }

        // MARK: - Helpers

        private func withDraftConfig(
            _ operation: (GmailGatewayConfig, TestConfigPaths) throws -> Void
        ) throws {
            let paths = temporaryConfigPaths()
            defer {
                try? FileManager.default.removeItem(atPath: paths.root)
            }
            try FileManager.default.createDirectory(atPath: paths.sendDir, withIntermediateDirectories: true)
            try operation(
                testConfig(paths: paths, accessMode: .readSend, tokenStoreJSON: sendTokenStoreJSON),
                paths
            )
        }

        private func writeSendAttachment(paths: TestConfigPaths, filename: String) throws -> URL {
            let url = URL(fileURLWithPath: paths.sendDir).appendingPathComponent(filename)
            try Data("replacement attachment".utf8).write(to: url)
            return url
        }

        private func withDraftProviderResponses(_ operation: () throws -> Void) throws {
            TestGmailRequestCaptureProtocol.reset()
            TestGmailRequestCaptureProtocol.draftListResponseData = Data("""
            {
              "drafts": [{ "id": "draft-1" }],
              "resultSizeEstimate": 1
            }
            """.utf8)
            TestGmailRequestCaptureProtocol.draftGetResponseData = Data(draftMessageJSON(wrappedAsDraft: true).utf8)
            TestGmailRequestCaptureProtocol.messageGetResponseData = Data(draftMessageJSON(wrappedAsDraft: false).utf8)
            TestGmailRequestCaptureProtocol.attachmentResponseData = Data(
                #"{"data":"\#(base64URLString(Data("attachment bytes".utf8)))"}"#.utf8
            )
            TestGmailRequestCaptureProtocol.draftUpdateResponseData = Data("""
            {
              "id": "draft-1",
              "message": { "id": "message-1", "threadId": "thread-1" }
            }
            """.utf8)
            URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
            defer {
                URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
                TestGmailRequestCaptureProtocol.reset()
            }
            try operation()
        }

        private func draftMessageJSON(wrappedAsDraft: Bool) -> String {
            let message = """
            {
              "id": "message-1",
              "threadId": "thread-1",
              "labelIds": ["DRAFT"],
              "internalDate": "1782936000000",
              "payload": {
                "mimeType": "multipart/mixed",
                "headers": [
                  { "name": "Subject", "value": "Existing subject" },
                  { "name": "To", "value": "recipient@example.com" },
                  { "name": "Cc", "value": "copied@example.com" },
                  { "name": "In-Reply-To", "value": "<origin@mail.example.com>" },
                  { "name": "References", "value": "<root@mail.example.com>" }
                ],
                "parts": [
                  {
                    "partId": "0",
                    "mimeType": "text/plain",
                    "body": { "size": 19, "data": "\(base64URLString(Data("Existing draft text".utf8)))" }
                  },
                  {
                    "partId": "1",
                    "mimeType": "text/html",
                    "body": { "size": 29, "data": "\(base64URLString(Data("<p>Existing draft html</p>".utf8)))" }
                  },
                  {
                    "partId": "2",
                    "mimeType": "text/plain",
                    "filename": "keep.txt",
                    "body": { "size": 16, "attachmentId": "attachment-keep" }
                  },
                  {
                    "partId": "3",
                    "mimeType": "text/plain",
                    "filename": "drop.txt",
                    "body": { "size": 16, "attachmentId": "attachment-drop" }
                  }
                ]
              }
            }
            """
            guard wrappedAsDraft else {
                return message
            }
            return """
            {
              "id": "draft-1",
              "message": \(message)
            }
            """
        }
    }
}

private func graphQLErrorCode(_ body: [String: Any]) -> String? {
    guard let errors = body["errors"] as? [[String: Any]],
          let extensions = errors.first?["extensions"] as? [String: Any] else {
        return nil
    }
    return extensions["code"] as? String
}

private func updatedDraftRequestBody() throws -> [String: Any] {
    let body = try #require(TestGmailRequestCaptureProtocol.capturedHTTPBodies.last)
    return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

private func updatedDraftRawMessage() throws -> String {
    let message = try #require(try updatedDraftRequestBody()["message"] as? [String: Any])
    let raw = try #require(message["raw"] as? String)
    let data = try #require(dataFromBase64URLString(raw))
    return try #require(String(data: data, encoding: .utf8))
}
