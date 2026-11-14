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

        @Test func catalogRuntimeEnforcesDraftAndSenderOwnership() async throws {
            let fixture = try GatewayRuntimeFixture(accessMode: .readSend)
            defer { fixture.remove() }
            let cases: [(GmailGatewayCLIMode, String)] = [
                (.reader, "mutation { createDraft(input: { accountId: \"personal\", to: [\"a@example.test\"], textBody: \"x\" }) { status } }"),
                (.draftGateway, "mutation { sendMessage(input: { accountId: \"personal\", to: [\"a@example.test\"], textBody: \"x\" }) { status } }"),
                (.draftGateway, "mutation { sendDraft(input: { accountId: \"personal\", draftId: \"draft-1\" }) { status } }"),
                (.reader, "query { drafts(accountId: \"personal\") { totalCount } }")
            ]
            for (mode, document) in cases {
                let envelope = await GmailGatewayGraphQLExecutor().run(
                    query: document,
                    mode: mode,
                    environment: fixture.environment
                )
                #expect(envelope.exitCode == 1)
                #expect(envelope.errors.first?.code == "CAPABILITY_DENIED")
            }
        }

        @Test func draftAndSenderGraphQLDocumentsUseRequiredInputsAndReachTheirProviderBoundary() async throws {
            let fixture = try GatewayRuntimeFixture(accessMode: .readSend)
            defer { fixture.remove() }
            GatewayRuntimeURLProtocol.reset()
            URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
                GatewayRuntimeURLProtocol.reset()
            }
            let provider = "https://gmail.googleapis.com"
            let draftListResponse = Data(#"{"drafts":[{"id":"draft-1"}],"resultSizeEstimate":1}"#.utf8)
            let draftDetailResponse = Data(#"{"id":"draft-1","message":{"id":"message-id","threadId":"thread-id","payload":{"headers":[]}}}"#.utf8)
            func configureDraftResponses() {
                GatewayRuntimeURLProtocol.draftListResponseData = draftListResponse
                GatewayRuntimeURLProtocol.draftDetailResponseData = draftDetailResponse
            }

            configureDraftResponses()
            let summary = await GmailGatewayGraphQLExecutor().run(
                query: "{ drafts(accountId: \"personal\", first: 1) { totalCount } }",
                mode: .draftGateway,
                environment: fixture.environment
            )
            #expect(summary.exitCode == 0)
            let summaryData = try #require(summary.data?.anyValue as? [String: Any])
            let summaryDrafts = try #require(summaryData["drafts"] as? [String: Any])
            #expect(summaryDrafts["totalCount"] as? Int == 1)
            #expect(
                GatewayRuntimeURLProtocol.requests.map { "\($0.method) \($0.url)" }
                    == ["GET \(provider)/gmail/v1/users/me/drafts?maxResults=1"]
            )

            GatewayRuntimeURLProtocol.reset()
            configureDraftResponses()
            let nodes = await GmailGatewayGraphQLExecutor().run(
                query: "{ drafts(accountId: \"personal\", first: 1) { edges { node { id } } } }",
                mode: .draftGateway,
                environment: fixture.environment
            )
            #expect(nodes.exitCode == 0)
            #expect(
                GatewayRuntimeURLProtocol.requests.map { "\($0.method) \($0.url)" }
                    == [
                        "GET \(provider)/gmail/v1/users/me/drafts?maxResults=1",
                        "GET \(provider)/gmail/v1/users/me/drafts/draft-1?format=full"
                    ]
            )

            // Request sequences include all fetch-before-write effects; each final JSON body is
            // decoded below rather than relying on aggregate path/method containment.
            // swiftlint:disable large_tuple line_length
            let cases: [(GmailGatewayCLIMode, String, [(String, String)], String, [String])] = [
                (.draftGateway, "{ drafts(accountId: \"personal\", first: 1) { totalCount } }", [("GET", "\(provider)/gmail/v1/users/me/drafts?maxResults=1")], "data", []),
                (.draftGateway, "{ draft(accountId: \"personal\", draftId: \"draft-1\") { id } }", [("GET", "\(provider)/gmail/v1/users/me/drafts/draft-1?format=full")], "data", []),
                (.draftGateway, "mutation { createDraft(input: { accountId: \"personal\", to: [\"a@example.test\"], textBody: \"x\" }) { status } }", [("POST", "\(provider)/gmail/v1/users/me/drafts")], "DRAFT_CREATED", ["message"]),
                (.draftGateway, "mutation { createReplyDraft(input: { accountId: \"personal\", messageId: \"message-id\", textBody: \"x\" }) { status } }", [("GET", "\(provider)/gmail/v1/users/me/messages/message-id?format=full"), ("POST", "\(provider)/gmail/v1/users/me/drafts")], "DRAFT_CREATED", ["message"]),
                (.draftGateway, "mutation { createForwardDraft(input: { accountId: \"personal\", messageId: \"message-id\", to: [\"a@example.test\"] }) { status } }", [("GET", "\(provider)/gmail/v1/users/me/messages/message-id?format=full"), ("GET", "\(provider)/gmail/v1/users/me/messages/message-id?format=full"), ("POST", "\(provider)/gmail/v1/users/me/drafts")], "DRAFT_CREATED", ["message"]),
                (.draftGateway, "mutation { updateDraft(input: { accountId: \"personal\", draftId: \"draft-1\", to: [\"a@example.test\"], textBody: \"x\" }) { status } }", [("GET", "\(provider)/gmail/v1/users/me/drafts/draft-1?format=full"), ("PUT", "\(provider)/gmail/v1/users/me/drafts/draft-1")], "DRAFT_UPDATED", ["id", "message"]),
                (.draftGateway, "mutation { deleteDraft(input: { accountId: \"personal\", draftId: \"draft-1\" }) { status } }", [("DELETE", "\(provider)/gmail/v1/users/me/drafts/draft-1")], "DRAFT_DELETED", []),
                (.directSender, "mutation { sendMessage(input: { accountId: \"personal\", to: [\"a@example.test\"], textBody: \"x\" }) { status } }", [("POST", "\(provider)/gmail/v1/users/me/messages/send")], "SENT", ["raw"]),
                (.directSender, "mutation { replyMessage(input: { accountId: \"personal\", messageId: \"message-id\", textBody: \"x\" }) { status } }", [("GET", "\(provider)/gmail/v1/users/me/messages/message-id?format=full"), ("POST", "\(provider)/gmail/v1/users/me/messages/send")], "SENT", ["raw"]),
                (.directSender, "mutation { forwardMessage(input: { accountId: \"personal\", messageId: \"message-id\", to: [\"a@example.test\"] }) { status } }", [("GET", "\(provider)/gmail/v1/users/me/messages/message-id?format=full"), ("GET", "\(provider)/gmail/v1/users/me/messages/message-id?format=full"), ("POST", "\(provider)/gmail/v1/users/me/messages/send")], "SENT", ["raw"]),
                (.directSender, "mutation { sendDraft(input: { accountId: \"personal\", draftId: \"draft-1\" }) { status } }", [("POST", "\(provider)/gmail/v1/users/me/drafts/send")], "SENT", ["id"])
            ]
            // swiftlint:enable large_tuple line_length
            for (mode, query, effects, status, _) in cases {
                GatewayRuntimeURLProtocol.reset()
                let result = GmailGatewayCLI(mode: mode).run(
                    arguments: ["graphql", "--query", query],
                    environment: fixture.environment
                )
                #expect(result.exitCode == 0, "\(query): \(result.stdout)\(result.stderr)")
                let root = try #require(draftRoot(in: query))
                try assertCompleteSuccessEnvelope(result, expectedData: draftEnvelope(root: root, status: status))
                #expect(
                    GatewayRuntimeURLProtocol.requests.map { "\($0.method) \($0.url)" }
                        == effects.map { "\($0.0) \($0.1)" }
                )
                let expectedBody = draftProviderBody(for: root)
                try assertCompleteProviderBodies(GatewayRuntimeURLProtocol.requests, finalBody: expectedBody)
            }
        }

        @Test func draftAliasesAndProjectionsRemainRuntimeValidated() throws {
            let fixture = try GatewayRuntimeFixture(accessMode: .readSend)
            defer { fixture.remove() }
            GatewayRuntimeURLProtocol.reset()
            URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
                GatewayRuntimeURLProtocol.reset()
            }
            let result = GmailGatewayCLI(mode: .draftGateway).run(
                arguments: [
                    "graphql", "--query",
                    "mutation { saved: createDraft(input: { accountId: \"personal\", to: [\"a@example.test\"], textBody: \"x\" }) { state: status } }"
                ],
                environment: fixture.environment
            )
            #expect(result.exitCode == 0)
            try assertCompleteSuccessEnvelope(result, expectedData: ["saved": ["state": "DRAFT_CREATED"]])
            #expect(
                GatewayRuntimeURLProtocol.requests.map { "\($0.method) \($0.url)" }
                    == ["POST https://gmail.googleapis.com/gmail/v1/users/me/drafts"]
            )
            try assertCompleteProviderBodies(
                GatewayRuntimeURLProtocol.requests,
                finalBody: ["message": ["raw": gatewayPlainMIME(to: "a@example.test", subject: nil, body: "x")]]
            )
        }

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
                    #expect(
                        normalizedDraftMIME(rawMessage) == expectedUpdatedDraftMIME(
                            subject: "Updated subject",
                            textBody: "Existing draft text",
                            htmlBody: "<p>Existing draft html</p>",
                            attachments: [
                                ("keep.txt", "YXR0YWNobWVudCBieXRlcw=="),
                                ("drop.txt", "YXR0YWNobWVudCBieXRlcw==")
                            ]
                        )
                    )
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
                    #expect(Set(request.keys) == ["id", "message"])
                    #expect(request["id"] as? String == "draft-1")
                    #expect(Set(message.keys) == ["raw", "threadId"])
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

                    #expect(
                        normalizedDraftMIME(rawMessage) == expectedUpdatedDraftMIME(
                            subject: "Existing subject",
                            textBody: "Existing draft text",
                            htmlBody: "<p>Existing draft html</p>",
                            attachments: [("replacement.txt", "cmVwbGFjZW1lbnQgYXR0YWNobWVudA==")]
                        )
                    )
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

                    #expect(
                        normalizedDraftMIME(rawMessage) == expectedUpdatedDraftMIME(
                            subject: "Existing subject",
                            textBody: "Existing draft text",
                            htmlBody: "<p>Existing draft html</p>",
                            attachments: [("keep.txt", "YXR0YWNobWVudCBieXRlcw==")]
                        )
                    )
                }
            }
        }

        @Test func providerAttemptBudgetRejectsAttempt1001DuringAttachmentFanoutBeforeDispatch() throws {
            try withDraftConfig { config, _ in
                try withDraftProviderResponses {
                    let budget = GmailGatewayProviderAttemptBudget(maximumRequests: 1_000)
                    try GmailGatewayProviderAttemptBudgetContext.$current.withValue(budget) {
                        for _ in 0..<997 {
                            try budget.consumeAttempt()
                        }
                        let error = try requireGmailGatewayError {
                            _ = try GmailGatewayWriteService(config: config).updateDraft(
                                input: UpdateDraftInput(
                                    accountId: "personal",
                                    draftId: "draft-1",
                                    subject: "Updated subject"
                                )
                            )
                        }

                        #expect(error.code == .resourceLimit)
                        #expect(budget.consumedAttemptCount == 1_000)
                        #expect(TestGmailRequestCaptureProtocol.capturedURLs.map(\.path) == [
                            "/gmail/v1/users/me/drafts/draft-1",
                            "/gmail/v1/users/me/messages/message-1",
                            "/gmail/v1/users/me/messages/message-1/attachments/attachment-keep"
                        ])
                        #expect(!TestGmailRequestCaptureProtocol.capturedMethods.contains("PUT"))
                    }
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

                    #expect(
                        normalizedDraftMIME(rawMessage) == expectedUpdatedDraftMIME(
                            subject: "Existing subject",
                            textBody: "Replacement text",
                            htmlBody: nil,
                            attachments: [
                                ("keep.txt", "YXR0YWNobWVudCBieXRlcw=="),
                                ("drop.txt", "YXR0YWNobWVudCBieXRlcw==")
                            ]
                        )
                    )
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

        @Test func draftReadKeepsDetailedMailMetadataAndRejectsOutOfRangePages() throws {
            try withDraftConfig { config, _ in
                try withDraftProviderResponses {
                    let service = GmailGatewayWriteService(config: config)
                    let draft = try service.getDraft(accountId: "personal", draftId: "draft-1")
                    let message = try #require(draft["message"] as? [String: Any])
                    let from = try #require(message["from"] as? [[String: Any]])

                    #expect(draft["id"] as? String == "draft-1")
                    #expect(draft["accountId"] as? String == "personal")
                    #expect(message["id"] as? String == "message-1")
                    #expect(message["threadId"] as? String == "thread-1")
                    #expect(message["subject"] as? String == "Existing subject")
                    let expectedFrom = try canonicalJSON([["raw": "Sender <sender@example.com>"]])
                    #expect(try canonicalJSON(from) == expectedFrom)

                    TestGmailRequestCaptureProtocol.reset()
                    let error = try requireGmailGatewayError {
                        _ = try service.listDrafts(accountId: "personal", first: 0)
                    }
                    #expect(error.code == .invalidArgument)
                    #expect(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty)
                }
            }
        }

        @Test func senderSendsExistingDraftThroughProviderDraftSend() throws {
            try withDraftConfig { config, _ in
                TestGmailRequestCaptureProtocol.reset()
                TestGmailRequestCaptureProtocol.responseData = Data(#"{"id":"sent-id","threadId":"thread-1"}"#.utf8)
                URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
                defer {
                    URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
                    TestGmailRequestCaptureProtocol.reset()
                }

                let result = try GmailGatewayWriteService(config: config).sendDraft(
                    accountId: "personal",
                    draftId: "draft-1"
                )
                let body = try #require(TestGmailRequestCaptureProtocol.capturedHTTPBodies.last)
                let request = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

                #expect(result["operation"] as? String == "SEND_DRAFT")
                #expect(result["status"] as? String == "SENT")
                #expect(result["draftId"] as? String == "draft-1")
                #expect(result["messageId"] as? String == "sent-id")
                #expect(result["threadId"] as? String == "thread-1")
                #expect(request["id"] as? String == "draft-1")
                #expect(TestGmailRequestCaptureProtocol.capturedURLs.map(\.path) == ["/gmail/v1/users/me/drafts/send"])
            }
        }

        @Test func sendDraftRejectsBlankDraftIdBeforeProviderCall() throws {
            try withDraftConfig { config, _ in
                TestGmailRequestCaptureProtocol.reset()
                URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
                defer {
                    URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
                    TestGmailRequestCaptureProtocol.reset()
                }

                let error = try requireGmailGatewayError {
                    _ = try GmailGatewayWriteService(config: config).sendDraft(accountId: "personal", draftId: " ")
                }

                #expect(error.code == .invalidArgument)
                #expect(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty)
            }
        }

        // MARK: - Threaded draft creation (draft binary keeps these; they never send)

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
            TestGmailRequestCaptureProtocol.draftCreateResponseData = Data("""
        {
          "id": "draft-new",
          "message": { "id": "message-new", "threadId": "thread-1" }
        }
        """.utf8)
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
                  { "name": "From", "value": "Sender <sender@example.com>" },
                  { "name": "Message-ID", "value": "<draft-1@mail.example.com>" },
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

private func draftRoot(in query: String) -> String? {
    [
        "createReplyDraft", "createForwardDraft", "createDraft", "updateDraft", "deleteDraft",
        "sendMessage", "replyMessage", "forwardMessage", "sendDraft", "drafts", "draft"
    ].first { query.contains("\($0)(") || query.contains("\($0) {") }
}

private func draftProviderBody(for root: String) -> [String: Any]? {
    switch root {
    case "createDraft": ["message": ["raw": gatewayPlainMIME(to: "a@example.test", subject: nil, body: "x")]]
    case "createReplyDraft": ["message": ["raw": gatewayReplyMIME(), "threadId": "thread-id"]]
    case "createForwardDraft": ["message": ["raw": gatewayForwardMIME(), "threadId": "thread-id"]]
    case "updateDraft": ["id": "draft-1", "message": ["raw": gatewayPlainMIME(to: "a@example.test", subject: nil, body: "x"), "threadId": "thread-id"]]
    case "sendMessage": ["raw": gatewayPlainMIME(to: "a@example.test", subject: nil, body: "x")]
    case "replyMessage": ["raw": gatewayReplyMIME(), "threadId": "thread-id"]
    case "forwardMessage": ["raw": gatewayForwardMIME(), "threadId": "thread-id"]
    case "sendDraft": ["id": "draft-1"]
    default: nil
    }
}

private func draftEnvelope(root: String, status: String) -> [String: Any] {
    switch root {
    case "drafts": [root: ["totalCount": 0]]
    case "draft": [root: ["id": "draft-1"]]
    default: [root: ["status": status]]
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

private func createdDraftRawMessage() throws -> String {
    try updatedDraftRawMessage()
}

private func updatedDraftRawMessage() throws -> String {
    let message = try #require(try updatedDraftRequestBody()["message"] as? [String: Any])
    let raw = try #require(message["raw"] as? String)
    let data = try #require(dataFromBase64URLString(raw))
    return try #require(String(data: data, encoding: .utf8))
}

private func normalizedDraftMIME(_ raw: String) -> String {
    raw
        .replacingOccurrences(
            of: "gmail-gateway-alt-[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}",
            with: "<alternative>",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: "gmail-gateway-[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}",
            with: "<mixed>",
            options: .regularExpression
        )
}

private func expectedUpdatedDraftMIME(
    subject: String,
    textBody: String,
    htmlBody: String?,
    attachments: [(String, String)]
) -> String {
    var lines = [
        "From: person@example.com",
        "To: recipient@example.com",
        "Cc: copied@example.com",
        "Subject: \(subject)",
        "In-Reply-To: <origin@mail.example.com>",
        "References: <root@mail.example.com>",
        "MIME-Version: 1.0",
        "Content-Type: multipart/mixed; boundary=\"<mixed>\"",
        ""
    ]
    if let htmlBody {
        lines += [
            "--<mixed>",
            "Content-Type: multipart/alternative; boundary=\"<alternative>\"",
            "",
            "--<alternative>",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: 8bit",
            "",
            textBody,
            "--<alternative>",
            "Content-Type: text/html; charset=utf-8",
            "Content-Transfer-Encoding: 8bit",
            "",
            htmlBody,
            "--<alternative>--"
        ]
    } else {
        lines += [
            "--<mixed>",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: 8bit",
            "",
            textBody
        ]
    }
    for (filename, base64) in attachments {
        lines += [
            "--<mixed>",
            "Content-Type: text/plain; name=\"\(filename)\"",
            "Content-Disposition: attachment; filename=\"\(filename)\"",
            "Content-Transfer-Encoding: base64",
            "",
            base64
        ]
    }
    lines.append("--<mixed>--")
    return lines.joined(separator: "\r\n")
}
