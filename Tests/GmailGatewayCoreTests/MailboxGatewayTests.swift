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

        @Test func mailboxMutationsAreRejectedOutsideTheThreadsBinary() throws {
            let query = #"mutation { trashMessage(accountId: "personal", messageId: "m1") { status } }"#
            try withMailboxConfig(accessMode: .readModify) { config, _ in
                let reader = try executeReaderGraphQL(config: config, query: query)
                let draft = try executeWriteGraphQL(config: config, query: query, mode: .draftDefault)
                let sender = try executeWriteGraphQL(config: config, query: query, mode: .directSend)
                let messageBox = try executeMessageBoxGraphQL(config: config, query: query)

                for result in [reader, draft, sender, messageBox] {
                    #expect(result.exitCode == .graphqlExecutionError)
                    #expect(
                        graphQLErrorCode(result.body) == GmailGatewayErrorCode.mailboxMutationNotSupported.rawValue
                    )
                }
                #expect(graphQLErrorMessage(reader.body)?.contains("gmail-gateway-threads") == true)
            }
        }

        @Test func ingestMutationsAreRejectedOutsideTheMessageBoxBinary() throws {
            let query = #"mutation { insertMessage(accountId: "personal", rfc822Path: "/tmp/x.eml") { status } }"#
            try withMailboxConfig(accessMode: .readModify) { config, _ in
                let reader = try executeReaderGraphQL(config: config, query: query)
                let draft = try executeWriteGraphQL(config: config, query: query, mode: .draftDefault)
                let threads = try executeMailboxGraphQL(config: config, query: query)

                for result in [reader, draft, threads] {
                    #expect(result.exitCode == .graphqlExecutionError)
                    #expect(graphQLErrorCode(result.body) == GmailGatewayErrorCode.mailIngestNotSupported.rawValue)
                }
                #expect(graphQLErrorMessage(threads.body)?.contains("gmail-gateway-message-box") == true)
            }
        }

        @Test func threadsAndMessageBoxRejectDraftAndSendMutations() throws {
            let queries = [
                #"mutation { sendMessage(accountId: "personal", to: ["a@example.com"], textBody: "B") { status } }"#,
                #"mutation { createDraft(accountId: "personal", to: ["a@example.com"], textBody: "B") { status } }"#,
                #"mutation { sendDraft(accountId: "personal", draftId: "d1") { status } }"#
            ]
            try withMailboxConfig(accessMode: .full) { config, _ in
                for query in queries {
                    let threads = try executeMailboxGraphQL(config: config, query: query)
                    let messageBox = try executeMessageBoxGraphQL(config: config, query: query)

                    for result in [threads, messageBox] {
                        #expect(result.exitCode == .graphqlExecutionError)
                        #expect(graphQLErrorCode(result.body) == GmailGatewayErrorCode.sendDisabledInReader.rawValue)
                    }
                }
            }
        }

        @Test func threadsBinaryStillServesTheSharedReadSurface() throws {
            try withMailboxConfig(accessMode: .readModify) { config, _ in
                let result = try executeMailboxGraphQL(
                    config: config,
                    query: #"query { accounts { id emailAddress } }"#
                )
                let data = try #require(result.body["data"] as? [String: Any])

                #expect(result.exitCode == .success)
                #expect((data["accounts"] as? [[String: Any]])?.count == 1)
            }
        }

        // MARK: - Label changes

        @Test func modifyMessageLabelsPostsAddAndRemoveLists() throws {
            try withMailboxConfig(accessMode: .readModify) { config, _ in
                try withMailboxResponses {
                    let result = try executeMailboxGraphQL(
                        config: config,
                        query: #"mutation { modifyMessageLabels(accountId: "personal", messageId: "message-1", addLabelIds: ["Label_1"], removeLabelIds: ["UNREAD"]) { status labelIds } }"#
                    )
                    let data = try #require(result.body["data"] as? [String: Any])
                    let payload = try #require(data["modifyMessageLabels"] as? [String: Any])
                    let body = try lastRequestBody()

                    #expect(result.exitCode == .success)
                    #expect(payload["operation"] as? String == "MODIFY_MESSAGE_LABELS")
                    #expect(payload["status"] as? String == "LABELS_MODIFIED")
                    #expect(payload["messageId"] as? String == "message-1")
                    #expect(payload["labelIds"] as? [String] == ["INBOX", "Label_1"])
                    #expect(body["addLabelIds"] as? [String] == ["Label_1"])
                    #expect(body["removeLabelIds"] as? [String] == ["UNREAD"])
                    #expect(
                        TestGmailRequestCaptureProtocol.capturedURLs.map(\.path)
                            == ["/gmail/v1/users/me/messages/message-1/modify"]
                    )
                }
            }
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

        @Test func importMessageUploadsTheFileAndPassesImportOnlyFlags() throws {
            try withMailboxConfig(accessMode: .readModify) { config, paths in
                let source = try writeIngestSource(paths: paths, contents: "Subject: Imported\r\n\r\nBody")
                try withMailboxResponses {
                    TestGmailRequestCaptureProtocol.responseData = Data(
                        #"{"id":"imported-id","threadId":"thread-9","labelIds":["INBOX"]}"#.utf8
                    )

                    let result = try executeMessageBoxGraphQL(
                        config: config,
                        query: """
                        mutation {
                          importMessage(
                            accountId: "personal",
                            rfc822Path: "\(source.path)",
                            labelIds: ["INBOX"],
                            internalDateSource: DATE_HEADER,
                            neverMarkSpam: true,
                            processForCalendar: false
                          ) { status operation messageId }
                        }
                        """
                    )
                    let data = try #require(result.body["data"] as? [String: Any])
                    let payload = try #require(data["importMessage"] as? [String: Any])
                    let body = try lastRequestBody()
                    let query = try #require(
                        TestGmailRequestCaptureProtocol.capturedURLs.last
                            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
                    )

                    #expect(result.exitCode == .success)
                    #expect(payload["operation"] as? String == "IMPORT_MESSAGE")
                    #expect(payload["status"] as? String == "MESSAGE_IMPORTED")
                    #expect(payload["messageId"] as? String == "imported-id")
                    #expect(body["labelIds"] as? [String] == ["INBOX"])
                    #expect(decodedRaw(body) == "Subject: Imported\r\n\r\nBody")
                    #expect(query.contains { $0.name == "internalDateSource" && $0.value == "DATE_HEADER" })
                    #expect(query.contains { $0.name == "neverMarkSpam" && $0.value == "true" })
                    #expect(TestGmailRequestCaptureProtocol.capturedURLs.last?.path
                        == "/gmail/v1/users/me/messages/import")
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

        @Test func ingestRejectsMissingSourceAndUnsupportedFields() throws {
            try withMailboxConfig(accessMode: .readModify) { config, paths in
                let missing = URL(fileURLWithPath: paths.sendDir).appendingPathComponent("missing.eml")
                try withMailboxResponses {
                    let error = try requireGmailGatewayError {
                        _ = try GmailGatewayWriteService(config: config).importMessage(
                            input: MailboxIngestInput(accountId: "personal", rfc822Path: missing.path)
                        )
                    }

                    #expect(error.code == .attachmentNotFound)
                }

                let result = try executeMessageBoxGraphQL(
                    config: config,
                    query: #"mutation { insertMessage(accountId: "personal", rfc822Path: "/x.eml", threadId: "t1") { status } }"#
                )

                #expect(graphQLErrorCode(result.body) == GmailGatewayErrorCode.invalidArgument.rawValue)
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
