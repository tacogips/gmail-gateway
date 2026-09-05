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
    struct MailboxGatewayTests {
        private func tokenStoreJSON(accessMode: String, scope: String) -> String {
            """
            {
              "accessMode": "\(accessMode)",
              "accessToken": "test-access-token",
              "refreshToken": null,
              "tokenType": "Bearer",
              "scope": "\(scope)",
              "expiresAt": "2999-01-01T00:00:00Z",
              "emailAddress": "person@example.com"
            }
            """
        }

        // MARK: - Access mode capability model

        @Test func accessModesGrantOnlyTheirOwnCapabilities() {
            #expect(AccessMode.read.capabilities == [.read])
            #expect(AccessMode.readSend.capabilities == [.read, .send])
            #expect(AccessMode.readModify.capabilities == [.read, .modify, .insert])
            #expect(AccessMode.full.capabilities == [.read, .send, .modify, .insert, .permanentDelete])

            // read_send must not be able to mutate stored mail, and read_modify must not send.
            #expect(!AccessMode.readSend.grants(.modify))
            #expect(!AccessMode.readSend.grants(.permanentDelete))
            #expect(!AccessMode.readModify.grants(.send))
            #expect(!AccessMode.readModify.grants(.permanentDelete))
            #expect(AccessMode.modesGranting(.permanentDelete) == [.full])
        }

        @Test func permanentDeleteRequiresFullAccessModeEvenWithReadModify() throws {
            try withMailboxConfig(accessMode: .readModify) { config, _ in
                TestGmailRequestCaptureProtocol.reset()
                URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
                defer {
                    URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
                    TestGmailRequestCaptureProtocol.reset()
                }

                let error = try requireGmailGatewayError {
                    _ = try GmailGatewayWriteService(config: config).deleteMessage(
                        accountId: "personal",
                        messageId: "message-1"
                    )
                }

                #expect(error.code == .accessModeInsufficient)
                #expect(error.details["requiredCapability"] == MailboxCapability.permanentDelete.rawValue)
                #expect(error.message.contains("full"))
                #expect(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty)
            }
        }

        @Test func mailboxMutationRejectsSendOnlyCredential() throws {
            try withMailboxConfig(accessMode: .readSend) { config, _ in
                let error = try requireGmailGatewayError {
                    _ = try GmailGatewayWriteService(config: config).setMessageTrashed(
                        accountId: "personal",
                        messageId: "message-1",
                        trashed: true
                    )
                }

                #expect(error.code == .accessModeInsufficient)
                #expect(error.details["requiredCapability"] == MailboxCapability.modify.rawValue)
            }
        }

        // MARK: - Binary capability boundaries

        @Test func catalogRuntimeEnforcesMailboxAndIngestOwnership() async throws {
            let fixture = try GatewayRuntimeFixture(accessMode: .readModify)
            defer { fixture.remove() }
            let cases: [(GmailGatewayCLIMode, String)] = [
                (.reader, "mutation { trashMessage(input: { accountId: \"personal\", messageId: \"m1\" }) { status } }"),
                (.draftGateway, "mutation { trashMessage(input: { accountId: \"personal\", messageId: \"m1\" }) { status } }"),
                (.mailboxThreads, "mutation { importMessage(input: { accountId: \"personal\", rfc822Path: \"/tmp/x.eml\" }) { status } }"),
                (.messageBox, "mutation { createLabel(input: { accountId: \"personal\", name: \"Work\" }) { status } }")
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

        @Test func mailboxAndIngestGraphQLDocumentsUseRequiredInputsAndReachTheirProviderBoundary() throws {
            let fixture = try GatewayRuntimeFixture(accessMode: .full)
            defer { fixture.remove() }
            let sourceDirectory = fixture.root.appendingPathComponent("send", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            let source = sourceDirectory.appendingPathComponent("message.eml")
            try Data("Subject: Runtime\r\n\r\nBody".utf8).write(to: source)
            GatewayRuntimeURLProtocol.reset()
            URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
                GatewayRuntimeURLProtocol.reset()
            }
            let provider = "https://gmail.googleapis.com"
            // Exact request/effect table: a mutation must make exactly this one provider call.
            // swiftlint:disable large_tuple line_length
            let cases: [(GmailGatewayCLIMode, String, String, String, String, [String])] = [
                (.mailboxThreads, "mutation { modifyThreadLabels(input: { accountId: \"personal\", threadId: \"thread-1\", addLabelIds: [\"Label_1\"] }) { status } }", "POST", "\(provider)/gmail/v1/users/me/threads/thread-1/modify", "LABELS_MODIFIED", ["addLabelIds"]),
                (.mailboxThreads, "mutation { modifyMessageLabels(input: { accountId: \"personal\", messageId: \"message-id\", addLabelIds: [\"Label_1\"] }) { status } }", "POST", "\(provider)/gmail/v1/users/me/messages/message-id/modify", "LABELS_MODIFIED", ["addLabelIds"]),
                (.mailboxThreads, "mutation { batchModifyMessageLabels(input: { accountId: \"personal\", messageIds: [\"message-id\"], addLabelIds: [\"Label_1\"] }) { status } }", "POST", "\(provider)/gmail/v1/users/me/messages/batchModify", "LABELS_MODIFIED", ["addLabelIds", "ids"]),
                (.mailboxThreads, "mutation { trashThread(input: { accountId: \"personal\", threadId: \"thread-1\" }) { status } }", "POST", "\(provider)/gmail/v1/users/me/threads/thread-1/trash", "TRASHED", []),
                (.mailboxThreads, "mutation { untrashMessage(input: { accountId: \"personal\", messageId: \"message-id\" }) { status } }", "POST", "\(provider)/gmail/v1/users/me/messages/message-id/untrash", "UNTRASHED", []),
                (.mailboxThreads, "mutation { deleteThread(input: { accountId: \"personal\", threadId: \"thread-1\" }) { status } }", "DELETE", "\(provider)/gmail/v1/users/me/threads/thread-1", "PERMANENTLY_DELETED", []),
                (.mailboxThreads, "mutation { deleteMessage(input: { accountId: \"personal\", messageId: \"message-id\" }) { status } }", "DELETE", "\(provider)/gmail/v1/users/me/messages/message-id", "PERMANENTLY_DELETED", []),
                (.mailboxThreads, "mutation { batchDeleteMessages(input: { accountId: \"personal\", messageIds: [\"message-id\"] }) { status } }", "POST", "\(provider)/gmail/v1/users/me/messages/batchDelete", "PERMANENTLY_DELETED", ["ids"]),
                (.mailboxThreads, "mutation { createLabel(input: { accountId: \"personal\", name: \"Work\" }) { status } }", "POST", "\(provider)/gmail/v1/users/me/labels", "LABEL_CREATED", ["name"]),
                (.mailboxThreads, "mutation { updateLabel(input: { accountId: \"personal\", labelId: \"Label_1\", name: \"Work\" }) { status } }", "PATCH", "\(provider)/gmail/v1/users/me/labels/Label_1", "LABEL_UPDATED", ["name"]),
                (.mailboxThreads, "mutation { deleteLabel(input: { accountId: \"personal\", labelId: \"Label_1\" }) { status } }", "DELETE", "\(provider)/gmail/v1/users/me/labels/Label_1", "LABEL_DELETED", []),
                (.messageBox, "mutation { importMessage(input: { accountId: \"personal\", rfc822Path: \"\(source.path)\", neverMarkSpam: true }) { status } }", "POST", "\(provider)/gmail/v1/users/me/messages/import?neverMarkSpam=true", "MESSAGE_IMPORTED", ["raw"]),
                (.messageBox, "mutation { insertMessage(input: { accountId: \"personal\", rfc822Path: \"\(source.path)\", deleted: false }) { status } }", "POST", "\(provider)/gmail/v1/users/me/messages?deleted=false", "MESSAGE_INSERTED", ["raw"])
            ]
            // swiftlint:enable large_tuple line_length
            for (mode, query, method, url, status, _) in cases {
                GatewayRuntimeURLProtocol.reset()
                let result = GmailGatewayCLI(mode: mode).run(
                    arguments: ["graphql", "--query", query],
                    environment: fixture.environment
                )
                #expect(result.exitCode == 0, "\(query): \(result.stdout)\(result.stderr)")
                let root = try #require(mailboxRoot(in: query))
                try assertCompleteSuccessEnvelope(result, expectedData: [root: ["status": status]])
                #expect(GatewayRuntimeURLProtocol.requests.map { "\($0.method) \($0.url)" } == ["\(method) \(url)"])
                let expectedBody = mailboxProviderBody(for: root)
                try assertCompleteProviderBodies(GatewayRuntimeURLProtocol.requests, finalBody: expectedBody)
            }
        }

        @Test func mailboxLabelAndIngestInvalidInputsFailBeforeProviderDispatch() throws {
            let fixture = try GatewayRuntimeFixture(accessMode: .readModify)
            defer { fixture.remove() }
            GatewayRuntimeURLProtocol.reset()
            URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
                GatewayRuntimeURLProtocol.reset()
            }
            let cases = [
                "mutation { createLabel(input: { accountId: \"personal\" }) { status } }",
                "mutation { updateLabel(input: { accountId: \"personal\", labelId: \"Label_1\" }) { status } }",
                "mutation { insertMessage(input: { accountId: \"personal\", rfc822Path: \"/tmp/x.eml\", threadId: \"t1\" }) { status } }"
            ]
            for query in cases {
                let mode: GmailGatewayCLIMode = query.contains("insertMessage") ? .messageBox : .mailboxThreads
                let result = GmailGatewayCLI(mode: mode).run(
                    arguments: ["graphql", "--query", query],
                    environment: fixture.environment
                )
                #expect(result.exitCode != 0)
                #expect(result.stdout.contains("errors"))
            }
            #expect(GatewayRuntimeURLProtocol.urls.isEmpty)
        }

        @Test func mailboxRuntimeRejectsUnknownInputFieldBeforeProviderDispatch() async throws {
            let fixture = try GatewayRuntimeFixture(accessMode: .readModify)
            defer { fixture.remove() }
            let envelope = await GmailGatewayGraphQLExecutor().run(
                query: "mutation { modifyMessageLabels(input: { accountId: \"personal\", messageId: \"m1\", unsupported: true }) { status } }",
                mode: .mailboxThreads,
                environment: fixture.environment
            )
            #expect(envelope.exitCode == 2)
            #expect(envelope.errors.first?.message.contains("unsupported") == true)
        }

        @Test func modifyThreadLabelsUnionsResultingLabelsAcrossThreadMessages() throws {
            try withMailboxConfig(accessMode: .readModify) { config, _ in
                try withMailboxResponses {
                    TestGmailRequestCaptureProtocol.responseData = Data("""
                    {
                      "id": "thread-1",
                      "messages": [
                        { "id": "m1", "labelIds": ["INBOX", "Label_1"] },
                        { "id": "m2", "labelIds": ["Label_1", "STARRED"] }
                      ]
                    }
                    """.utf8)

                    let result = try GmailGatewayWriteService(config: config).modifyThreadLabels(
                        accountId: "personal",
                        threadId: "thread-1",
                        addLabelIds: ["Label_1"],
                        removeLabelIds: []
                    )

                    #expect(result["threadId"] as? String == "thread-1")
                    #expect(result["labelIds"] as? [String] == ["INBOX", "Label_1", "STARRED"])
                }
            }
        }

        @Test func modifyLabelsRejectsEmptyChangeBeforeProviderCall() throws {
            try withMailboxConfig(accessMode: .readModify) { config, _ in
                try withMailboxResponses {
                    let error = try requireGmailGatewayError {
                        _ = try GmailGatewayWriteService(config: config).modifyMessageLabels(
                            accountId: "personal",
                            messageId: "message-1",
                            addLabelIds: [],
                            removeLabelIds: []
                        )
                    }

                    #expect(error.code == .invalidArgument)
                    #expect(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty)
                }
            }
        }

        @Test func batchModifyMessageLabelsSendsIdsAndReportsThem() throws {
            try withMailboxConfig(accessMode: .readModify) { config, _ in
                try withMailboxResponses {
                    let result = try GmailGatewayWriteService(config: config).batchModifyMessageLabels(
                        accountId: "personal",
                        messageIds: ["m1", "m2"],
                        addLabelIds: ["Label_1"],
                        removeLabelIds: []
                    )
                    let body = try lastRequestBody()

                    #expect(result["operation"] as? String == "BATCH_MODIFY_MESSAGE_LABELS")
                    #expect(result["messageIds"] as? [String] == ["m1", "m2"])
                    #expect(body["ids"] as? [String] == ["m1", "m2"])
                    #expect(
                        TestGmailRequestCaptureProtocol.capturedURLs.map(\.path)
                            == ["/gmail/v1/users/me/messages/batchModify"]
                    )
                }
            }
        }

        @Test func removeOnlyLabelMutationMapsTheCompleteProviderBody() throws {
            try withMailboxConfig(accessMode: .readModify) { config, _ in
                try withMailboxResponses {
                    let result = try GmailGatewayWriteService(config: config).modifyMessageLabels(
                        accountId: "personal",
                        messageId: "message-1",
                        addLabelIds: [],
                        removeLabelIds: ["UNREAD"]
                    )
                    let body = try lastRequestBody()
                    let canonicalBody = try canonicalJSON(body)
                    let expectedBody = try canonicalJSON(["removeLabelIds": ["UNREAD"]])

                    #expect(result["operation"] as? String == "MODIFY_MESSAGE_LABELS")
                    #expect(canonicalBody == expectedBody)
                    #expect(TestGmailRequestCaptureProtocol.capturedURLs.map(\.path) == [
                        "/gmail/v1/users/me/messages/message-1/modify"
                    ])
                }
            }
        }

        // MARK: - Trash, untrash, and permanent delete

        @Test func trashAndUntrashUseTheMatchingProviderEndpoints() throws {
            try withMailboxConfig(accessMode: .readModify) { config, _ in
                try withMailboxResponses {
                    let service = GmailGatewayWriteService(config: config)
                    let trashed = try service.setMessageTrashed(
                        accountId: "personal",
                        messageId: "message-1",
                        trashed: true
                    )
                    let untrashed = try service.setThreadTrashed(
                        accountId: "personal",
                        threadId: "thread-1",
                        trashed: false
                    )

                    #expect(trashed["operation"] as? String == "TRASH_MESSAGE")
                    #expect(trashed["status"] as? String == "TRASHED")
                    #expect(untrashed["operation"] as? String == "UNTRASH_THREAD")
                    #expect(untrashed["status"] as? String == "UNTRASHED")
                    #expect(TestGmailRequestCaptureProtocol.capturedURLs.map(\.path) == [
                        "/gmail/v1/users/me/messages/message-1/trash",
                        "/gmail/v1/users/me/threads/thread-1/untrash"
                    ])
                }
            }
        }

        @Test func permanentDeleteUsesDeleteAndBatchDeleteEndpoints() throws {
            try withMailboxConfig(accessMode: .full) { config, _ in
                try withMailboxResponses {
                    let service = GmailGatewayWriteService(config: config)
                    let deleted = try service.deleteMessage(accountId: "personal", messageId: "message-1")
                    let batch = try service.batchDeleteMessages(accountId: "personal", messageIds: ["m1", "m2"])

                    #expect(deleted["operation"] as? String == "DELETE_MESSAGE")
                    #expect(deleted["status"] as? String == "PERMANENTLY_DELETED")
                    #expect(batch["messageIds"] as? [String] == ["m1", "m2"])
                    #expect(TestGmailRequestCaptureProtocol.capturedMethods == ["DELETE", "POST"])
                    #expect(TestGmailRequestCaptureProtocol.capturedURLs.map(\.path) == [
                        "/gmail/v1/users/me/messages/message-1",
                        "/gmail/v1/users/me/messages/batchDelete"
                    ])
                }
            }
        }

        @Test func batchMutationsRejectEmptyIdListBeforeProviderCall() throws {
            try withMailboxConfig(accessMode: .full) { config, _ in
                try withMailboxResponses {
                    let error = try requireGmailGatewayError {
                        _ = try GmailGatewayWriteService(config: config).batchDeleteMessages(
                            accountId: "personal",
                            messageIds: []
                        )
                    }

                    #expect(error.code == .invalidArgument)
                    #expect(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty)
                }
            }
        }

        // MARK: - Label management

        @Test func createLabelPostsNameAndReturnsTheCreatedLabel() throws {
            try withMailboxConfig(accessMode: .readModify) { config, _ in
                try withMailboxResponses {
                    TestGmailRequestCaptureProtocol.responseData = Data("""
                    { "id": "Label_9", "name": "Work", "type": "user", "labelListVisibility": "labelShow" }
                    """.utf8)

                    let result = try GmailGatewayWriteService(config: config).createLabel(
                        accountId: "personal",
                        input: LabelWriteInput(name: "Work", labelListVisibility: "labelShow")
                    )
                    let label = try #require(result["label"] as? [String: Any])
                    let body = try lastRequestBody()

                    #expect(result["operation"] as? String == "CREATE_LABEL")
                    #expect(result["status"] as? String == "LABEL_CREATED")
                    #expect(result["labelId"] as? String == "Label_9")
                    #expect(label["name"] as? String == "Work")
                    #expect(body["name"] as? String == "Work")
                    #expect(TestGmailRequestCaptureProtocol.capturedMethods == ["POST"])
                }
            }
        }

        @Test func updateLabelPatchesOnlyTheNamedFields() throws {
            try withMailboxConfig(accessMode: .readModify) { config, _ in
                try withMailboxResponses {
                    TestGmailRequestCaptureProtocol.responseData = Data(
                        #"{"id":"Label_9","name":"Renamed","type":"user"}"#.utf8
                    )

                    _ = try GmailGatewayWriteService(config: config).updateLabel(
                        accountId: "personal",
                        labelId: "Label_9",
                        input: LabelWriteInput(name: "Renamed")
                    )
                    let body = try lastRequestBody()

                    #expect(TestGmailRequestCaptureProtocol.capturedMethods == ["PATCH"])
                    #expect(TestGmailRequestCaptureProtocol.capturedURLs.last?.path == "/gmail/v1/users/me/labels/Label_9")
                    #expect(body["name"] as? String == "Renamed")
                    #expect(body["labelListVisibility"] == nil)
                }
            }
        }

        @Test func labelMutationsRejectInvalidVisibilityAndEmptyPatches() throws {
            try withMailboxConfig(accessMode: .readModify) { config, _ in
                try withMailboxResponses {
                    let service = GmailGatewayWriteService(config: config)
                    let invalidVisibility = try requireGmailGatewayError {
                        _ = try service.createLabel(
                            accountId: "personal",
                            input: LabelWriteInput(name: "Work", labelListVisibility: "sometimes")
                        )
                    }
                    let emptyPatch = try requireGmailGatewayError {
                        _ = try service.updateLabel(
                            accountId: "personal",
                            labelId: "Label_9",
                            input: LabelWriteInput()
                        )
                    }

                    #expect(invalidVisibility.code == .invalidArgument)
                    #expect(emptyPatch.code == .invalidArgument)
                    #expect(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty)
                }
            }
        }

        // MARK: - Mail ingestion

        @Test func importMessageMapsAllImportFlagsAndItsCompletePayload() throws {
            try withMailboxConfig(accessMode: .readModify) { config, paths in
                let source = try writeIngestSource(paths: paths, contents: "Subject: Imported\r\n\r\nBody")
                try withMailboxResponses {
                    TestGmailRequestCaptureProtocol.responseData = Data(
                        #"{"id":"imported-id","threadId":"thread-9","labelIds":["INBOX"]}"#.utf8
                    )
                    let result = try GmailGatewayWriteService(config: config).importMessage(
                        input: MailboxIngestInput(
                            accountId: "personal",
                            rfc822Path: source.path,
                            labelIds: ["INBOX"],
                            internalDateSource: "DATE_HEADER",
                            neverMarkSpam: true,
                            processForCalendar: true,
                            deleted: false
                        )
                    )
                    let body = try lastRequestBody()
                    let queryItems = try #require(
                        TestGmailRequestCaptureProtocol.capturedURLs.last
                            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
                    )

                    #expect(result["operation"] as? String == "IMPORT_MESSAGE")
                    #expect(result["status"] as? String == "MESSAGE_IMPORTED")
                    #expect(body["labelIds"] as? [String] == ["INBOX"])
                    #expect(decodedRaw(body) == "Subject: Imported\r\n\r\nBody")
                    let normalizedItems = Set(queryItems.map { item in "\(item.name)=\(item.value ?? "")" })
                    #expect(normalizedItems == Set([
                        "internalDateSource=dateHeader", "neverMarkSpam=true", "processForCalendar=true", "deleted=false"
                    ]))
                }
            }
        }

        @Test func ingestMapsBothGraphQLEnumsToExactGmailInternalDateSourceValues() throws {
            try withMailboxConfig(accessMode: .readModify) { config, paths in
                let source = try writeIngestSource(paths: paths, contents: "Subject: Imported\r\n\r\nBody")
                let cases = [("RECEIVED_TIME", "receivedTime"), ("DATE_HEADER", "dateHeader")]
                for (input, expectedWireValue) in cases {
                    try withMailboxResponses {
                        _ = try GmailGatewayWriteService(config: config).insertMessage(
                            input: MailboxIngestInput(
                                accountId: "personal",
                                rfc822Path: source.path,
                                internalDateSource: input
                            )
                        )
                        let queryItems = try #require(
                            TestGmailRequestCaptureProtocol.capturedURLs.last
                                .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
                        )
                        #expect(queryItems == [URLQueryItem(name: "internalDateSource", value: expectedWireValue)])
                    }
                }
            }
        }

        @Test func ingestRejectsMissingAllowedSourceBeforeProviderDispatch() throws {
            try withMailboxConfig(accessMode: .readModify) { config, paths in
                let missing = URL(fileURLWithPath: paths.sendDir).appendingPathComponent("missing.eml")
                try withMailboxResponses {
                    let error = try requireGmailGatewayError {
                        _ = try GmailGatewayWriteService(config: config).importMessage(
                            input: MailboxIngestInput(accountId: "personal", rfc822Path: missing.path)
                        )
                    }
                    #expect(error.code == .attachmentNotFound)
                    #expect(error.details["rfc822Path"] == missing.path)
                    #expect(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty)
                }
            }
        }

        @Test func insertMessageOmitsImportOnlyFlags() throws {
            try withMailboxConfig(accessMode: .readModify) { config, paths in
                let source = try writeIngestSource(paths: paths, contents: "Subject: Inserted\r\n\r\nBody")
                try withMailboxResponses {
                    TestGmailRequestCaptureProtocol.responseData = Data(#"{"id":"inserted-id"}"#.utf8)

                    _ = try GmailGatewayWriteService(config: config).insertMessage(
                        input: MailboxIngestInput(
                            accountId: "personal",
                            rfc822Path: source.path,
                            neverMarkSpam: true,
                            processForCalendar: true,
                            deleted: false
                        )
                    )
                    let query = try #require(
                        TestGmailRequestCaptureProtocol.capturedURLs.last
                            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
                    )

                    #expect(TestGmailRequestCaptureProtocol.capturedURLs.last?.path == "/gmail/v1/users/me/messages")
                    #expect(query.contains { $0.name == "deleted" && $0.value == "false" })
                    #expect(!query.contains { $0.name == "neverMarkSpam" })
                    #expect(!query.contains { $0.name == "processForCalendar" })
                }
            }
        }

        @Test func ingestRejectsSourcesOutsideTheAllowedRoots() throws {
            try withMailboxConfig(accessMode: .readModify) { config, paths in
                let outside = URL(fileURLWithPath: paths.root).appendingPathComponent("outside.eml")
                try Data("Subject: Nope\r\n\r\n".utf8).write(to: outside)
                try withMailboxResponses {
                    let error = try requireGmailGatewayError {
                        _ = try GmailGatewayWriteService(config: config).importMessage(
                            input: MailboxIngestInput(accountId: "personal", rfc822Path: outside.path)
                        )
                    }

                    #expect(error.code == .configInvalid)
                    #expect(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty)
                }
            }
        }

        @Test func ingestRejectsUnsupportedInternalDateSource() throws {
            try withMailboxConfig(accessMode: .readModify) { config, paths in
                let source = try writeIngestSource(paths: paths, contents: "Subject: X\r\n\r\n")
                try withMailboxResponses {
                    let error = try requireGmailGatewayError {
                        _ = try GmailGatewayWriteService(config: config).importMessage(
                            input: MailboxIngestInput(
                                accountId: "personal",
                                rfc822Path: source.path,
                                internalDateSource: "YESTERDAY"
                            )
                        )
                    }

                    #expect(error.code == .invalidArgument)
                    #expect(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty)
                }
            }
        }

        // MARK: - Helpers

        private func withMailboxConfig(
            accessMode: AccessMode,
            _ operation: (GmailGatewayConfig, TestConfigPaths) throws -> Void
        ) throws {
            let paths = temporaryConfigPaths()
            defer {
                try? FileManager.default.removeItem(atPath: paths.root)
            }
            try FileManager.default.createDirectory(atPath: paths.sendDir, withIntermediateDirectories: true)
            let scope = accessMode == .full
                ? "https://mail.google.com/"
                : "https://www.googleapis.com/auth/gmail.modify"
            try operation(
                testConfig(
                    paths: paths,
                    accessMode: accessMode,
                    tokenStoreJSON: tokenStoreJSON(accessMode: accessMode.rawValue, scope: scope)
                ),
                paths
            )
        }

        private func writeIngestSource(paths: TestConfigPaths, contents: String) throws -> URL {
            let url = URL(fileURLWithPath: paths.sendDir).appendingPathComponent("source.eml")
            try Data(contents.utf8).write(to: url)
            return url
        }

        private func withMailboxResponses(_ operation: () throws -> Void) throws {
            TestGmailRequestCaptureProtocol.reset()
            TestGmailRequestCaptureProtocol.responseData = Data("""
            { "id": "message-1", "threadId": "thread-1", "labelIds": ["INBOX", "Label_1"] }
            """.utf8)
            URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
            defer {
                URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
                TestGmailRequestCaptureProtocol.reset()
            }
            try operation()
        }
    }
}

private func mailboxRoot(in query: String) -> String? {
    [
        "modifyThreadLabels", "modifyMessageLabels", "batchModifyMessageLabels", "untrashThread",
        "untrashMessage", "trashThread", "trashMessage", "deleteThread", "deleteMessage",
        "batchDeleteMessages", "createLabel", "updateLabel", "deleteLabel", "importMessage", "insertMessage"
    ].first { query.contains("\($0)(") }
}

private func mailboxProviderBody(for root: String) -> [String: Any]? {
    switch root {
    case "modifyThreadLabels", "modifyMessageLabels": ["addLabelIds": ["Label_1"]]
    case "batchModifyMessageLabels": ["addLabelIds": ["Label_1"], "ids": ["message-id"]]
    case "trashThread", "untrashThread", "trashMessage", "untrashMessage": nil
    case "batchDeleteMessages": ["ids": ["message-id"]]
    case "createLabel", "updateLabel": ["name": "Work"]
    case "importMessage", "insertMessage": ["raw": "Subject: Runtime\r\n\r\nBody"]
    default: nil
    }
}
private func graphQLErrorCode(_ body: [String: Any]) -> String? {
    graphQLErrorExtensions(body)?["code"] as? String
}

private func graphQLErrorMessage(_ body: [String: Any]) -> String? {
    (body["errors"] as? [[String: Any]])?.first?["message"] as? String
}

private func graphQLErrorExtensions(_ body: [String: Any]) -> [String: Any]? {
    (body["errors"] as? [[String: Any]])?.first?["extensions"] as? [String: Any]
}

private func lastRequestBody() throws -> [String: Any] {
    let body = try #require(TestGmailRequestCaptureProtocol.capturedHTTPBodies.last)
    return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

private func decodedRaw(_ body: [String: Any]) -> String? {
    guard let raw = body["raw"] as? String,
          let data = dataFromBase64URLString(raw) else {
        return nil
    }
    return String(data: data, encoding: .utf8)
}
