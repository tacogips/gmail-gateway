import Foundation
import GatewaySDKKit
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GmailGatewayCore

private struct DefaultSelectionCase {
    let sdk: GmailGatewaySDK
    let operation: GatewayOperationRequest
    let expectedData: GatewayJSONValue
    let expectedEffects: [GatewayProviderEffect]
    let expectedBody: [String: Any]?
}

private struct StrictConfigurationCase {
    let configPath: String
    let environment: [String: String]
}

private struct EnvelopeParityCase {
    let name: String
    let document: String
    let environment: [String: String]
    let exitCode: Int32
}

private struct OperationEnvelopeParityCase {
    let request: GatewayOperationRequest
    let arguments: [String]
    let code: String
    let exitCode: Int32
}

extension GmailRequestProtocolTests {
    @Suite(.serialized)
    struct GmailGatewaySDKTests {
        @Test func senderAccountsAdvertiseSendCapabilityButReaderAccountsDoNot() async throws {
    let fixture = try GatewayRuntimeFixture(accessMode: .readSend)
    defer { fixture.remove() }
    let query = "{ accounts { capabilities { canRead canSend configuredAccessMode } } }"

    let reader = await GmailGatewaySDK(mode: .reader).execute(
        document: query,
        variables: [:],
        environment: fixture.environment
    )
    let sender = await GmailGatewaySDK(mode: .directSender).execute(
        document: query,
        variables: [:],
        environment: fixture.environment
    )

    #expect(reader.exitCode == 0)
    #expect(sender.exitCode == 0)
    #expect(bool(at: ["accounts", "0", "capabilities", "canSend"], in: reader) == false)
    #expect(bool(at: ["accounts", "0", "capabilities", "canSend"], in: sender) == true)
        }

        @Test func variablesDriveNestedThreadInputAndProjectionDoesNotExposeLocalPath() async throws {
    let fixture = try GatewayRuntimeFixture()
    defer { fixture.remove() }
    GatewayRuntimeURLProtocol.reset()
    URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
    defer {
        URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
        GatewayRuntimeURLProtocol.reset()
    }

    let envelope = await GmailGatewaySDK(mode: .reader).execute(
        document: "query Search($input: ThreadSearchInput!) { threads(input: $input) { totalCount } }",
        variables: ["input": .object(["accountId": .string("personal"), "first": .int(5)])],
        environment: fixture.environment
    )
    #expect(envelope.exitCode == 0)
    #expect(GatewayRuntimeURLProtocol.urls.map(\.path).contains("/gmail/v1/users/me/threads"))
        }

        @Test func normalizedAddressPreservesRawValueExactly() async throws {
    let fixture = try GatewayRuntimeFixture()
    defer { fixture.remove() }
    GatewayRuntimeURLProtocol.reset()
    URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
    defer {
        URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
        GatewayRuntimeURLProtocol.reset()
    }

    let envelope = await GmailGatewaySDK(mode: .reader).execute(
        document: "{ message(accountId: \"personal\", messageId: \"message-id\") { from { raw address } } }",
        variables: [:],
        environment: fixture.environment
    )
    #expect(envelope.exitCode == 0)
    #expect(string(at: ["message", "from", "0", "raw"], in: envelope) == "Display Name <person@example.com>")
    #expect(string(at: ["message", "from", "0", "address"], in: envelope) == "Display Name <person@example.com>")
        }

        @Test func defaultOperationSelectionsSupportThreadsLabelsAndCreateDraft() async throws {
            let fixture = try GatewayRuntimeFixture(accessMode: .readSend)
            defer { fixture.remove() }
            GatewayRuntimeURLProtocol.reset()
            URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
                GatewayRuntimeURLProtocol.reset()
            }
            let reader = GmailGatewaySDK(mode: .reader)
            let sender = GmailGatewaySDK(mode: .directSender)
            let requests: [DefaultSelectionCase] = [
                .init(
                    sdk: reader,
                    operation: .init(operation: "threads", variables: ["input": .object(["accountId": .string("personal")])], selection: .default),
                    expectedData: .object(["threads": .object([
                        "edges": .array([]),
                        "pageInfo": .object(["hasNextPage": .bool(false), "endCursor": .null]),
                        "totalCount": .int(0)
                    ])]),
                    expectedEffects: [.init(url: "https://gmail.googleapis.com/gmail/v1/users/me/threads?maxResults=20&labelIds=INBOX", method: "GET")],
                    expectedBody: nil
                ),
                .init(
                    sdk: reader,
                    operation: .init(operation: "labels", variables: ["accountId": .string("personal")], selection: .default),
                    expectedData: .object(["labels": .array([.object([
                        "id": .string("Label_1"), "accountId": .string("personal"), "name": .string("Work"),
                        "type": .string("user"), "messageListVisibility": .null, "labelListVisibility": .null
                    ])])]),
                    expectedEffects: [.init(url: "https://gmail.googleapis.com/gmail/v1/users/me/labels", method: "GET")],
                    expectedBody: nil
                ),
                .init(
                    sdk: sender,
                    operation: .init(operation: "createDraft", variables: ["input": .object(["accountId": .string("personal"), "to": .array([.string("a@example.test")]), "textBody": .string("x")])], selection: .default),
                    expectedData: .object(["createDraft": .object([
                        "operation": .string("CREATE_DRAFT"), "accountId": .string("personal"), "provider": .string("GMAIL"),
                        "draftId": .string("draft-1"), "messageId": .string("message-id"), "threadId": .string("thread-id"),
                        "status": .string("DRAFT_CREATED"), "rejectedAttachments": .array([])
                    ])]),
                    expectedEffects: [.init(url: "https://gmail.googleapis.com/gmail/v1/users/me/drafts", method: "POST")],
                    expectedBody: ["message": ["raw": gatewayPlainMIME(to: "a@example.test", subject: nil, body: "x")]]
                )
            ]
            for entry in requests {
                GatewayRuntimeURLProtocol.reset()
                let result = await entry.sdk.invoke(entry.operation, environment: fixture.environment)
                #expect(result.exitCode == 0, "\(entry.operation.operation): \(result.rawOutput)")
                #expect(result.errors.isEmpty, "\(entry.operation.operation): \(result.errors)")
                #expect(result.data == entry.expectedData, "\(entry.operation.operation) must return its exact default projection")
                #expect(
                    GatewayRuntimeURLProtocol.requests.map { GatewayProviderEffect(url: $0.url, method: $0.method) } == entry.expectedEffects,
                    "\(entry.operation.operation) must have only its expected provider effects"
                )
                let requestCapture = try #require(GatewayRuntimeURLProtocol.requests.last)
                #expect(
                    try decodedCanonicalProviderBody(requestCapture) == (try entry.expectedBody.map(canonicalJSON)),
                    "\(entry.operation.operation) must have its exact provider body"
                )
            }
        }

        @Test func sdkInvokeMatchesCLIOperationAuthorizationAndBuilderEnvelopes() async throws {
            let fixture = try GatewayRuntimeFixture(accessMode: .readSend)
            defer { fixture.remove() }
            GatewayRuntimeURLProtocol.reset()
            URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
                GatewayRuntimeURLProtocol.reset()
            }

            let sendVariables: [String: GatewayJSONValue] = ["input": .object([
                "accountId": .string("personal"),
                "to": .array([.string("a@example.test")]),
                "textBody": .string("x")
            ])]
            let cases: [OperationEnvelopeParityCase] = [
                .init(
                    request: .init(operation: "sendMessage", variables: sendVariables, selection: .fields(["status"])),
                    arguments: ["graphql", "operation", "sendMessage", "--variables", #"{"input":{"accountId":"personal","to":["a@example.test"],"textBody":"x"}}"#, "--select", "status"],
                    code: "CAPABILITY_DENIED",
                    exitCode: GmailGatewayExitCode.generalError.rawValue
                ),
                .init(
                    request: .init(operation: "threads"),
                    arguments: ["graphql", "operation", "threads"],
                    code: "MISSING_VARIABLE",
                    exitCode: GmailGatewayExitCode.invalidCliUsage.rawValue
                ),
                .init(
                    request: .init(operation: "accounts", selection: .fields(["notAField"])),
                    arguments: ["graphql", "operation", "accounts", "--select", "notAField"],
                    code: "INVALID_SELECTION",
                    exitCode: GmailGatewayExitCode.invalidCliUsage.rawValue
                )
            ]

            for entry in cases {
                GatewayRuntimeURLProtocol.reset()
                let sdk = await GmailGatewaySDK(mode: .reader).invoke(entry.request, environment: fixture.environment)
                let cli = GmailGatewayCLI(mode: .reader).run(
                    arguments: entry.arguments,
                    environment: fixture.environment
                )
                let cliEnvelope = GatewayEnvelope(parsingCLIOutput: cli.stdout, exitCode: cli.exitCode)

                #expect(sdk.exitCode == entry.exitCode)
                #expect(cli.exitCode == entry.exitCode)
                #expect(sdk.errors.map(\.code) == [entry.code])
                #expect(cliEnvelope.errors.map(\.code) == [entry.code])
                #expect(sdk.requestId != nil)
                #expect(cliEnvelope.requestId != nil)
                #expect(try GmailGatewayGraphQLEnvelopeSerializer.output(sdk, pretty: false) == sdk.rawOutput)
                #expect(try envelopeWithoutRequestId(sdk.rawOutput) == envelopeWithoutRequestId(cli.stdout))
                #expect(GatewayRuntimeURLProtocol.requests.isEmpty)
            }
        }

        @Test func sdkDoesNotReadAmbientHomeConfigurationWhenEnvironmentIsEmpty() async {
            GatewayRuntimeURLProtocol.reset()
            URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
                GatewayRuntimeURLProtocol.reset()
            }

            let result = await GmailGatewaySDK(mode: .reader).execute(
                document: "{ threads(input: { accountId: \"personal\" }) { totalCount } }",
                variables: [:],
                environment: [:]
            )

            #expect(result.exitCode == 1)
            #expect(result.errors.first?.code == "CONFIG_INVALID")
            #expect(GatewayRuntimeURLProtocol.requests.isEmpty)
        }

        @Test func sdkStrictEnvironmentRejectsUnsafeConfigurationPathsWithoutDispatch() async throws {
            let fixture = try GatewayRuntimeFixture()
            defer { fixture.remove() }
            let source = try String(contentsOfFile: fixture.configPath, encoding: .utf8)
            let cases: [StrictConfigurationCase] = [
                .init(configPath: "config.toml", environment: fixture.environment),
                .init(configPath: "~/config.toml", environment: fixture.environment),
                try strictConfigurationCase(
                    name: "home-expanded-cache",
                    source: source,
                    replacing: "cache_dir = \"cache\"",
                    with: "cache_dir = \"~/cache\"",
                    fixture: fixture
                ),
                try strictConfigurationCase(
                    name: "home-expanded-attachment",
                    source: source,
                    replacing: "attachment_dir = \"attachments\"",
                    with: "attachment_dir = \"~/attachments\"",
                    fixture: fixture
                ),
                try strictConfigurationCase(
                    name: "home-expanded-send-root",
                    source: source,
                    replacing: "allowed_send_attachment_roots = [\"send\"]",
                    with: "allowed_send_attachment_roots = [\"~/send\"]",
                    fixture: fixture
                ),
                try strictConfigurationCase(
                    name: "home-expanded-client-secret",
                    source: source,
                    replacing: "oauth_client_secret_path = \"client.json\"",
                    with: "oauth_client_secret_path = \"~/client.json\"",
                    fixture: fixture
                ),
                try strictConfigurationCase(
                    name: "home-expanded-token-store",
                    source: source,
                    replacing: "token_store_path = \"token.json\"",
                    with: "token_store_path = \"~/token.json\"",
                    fixture: fixture
                )
            ]
            GatewayRuntimeURLProtocol.reset()
            URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
                GatewayRuntimeURLProtocol.reset()
            }

            for entry in cases {
                GatewayRuntimeURLProtocol.reset()
                var environment = entry.environment
                environment["GMAIL_GATEWAY_CONFIG"] = entry.configPath
                let result = await GmailGatewaySDK(mode: .reader).execute(
                    document: "{ threads(input: { accountId: \"personal\" }) { totalCount } }",
                    variables: [:],
                    environment: environment
                )
                #expect(result.exitCode == GmailGatewayExitCode.generalError.rawValue)
                #expect(result.errors.first?.code == "CONFIG_INVALID")
                #expect(GatewayRuntimeURLProtocol.requests.isEmpty)
            }
        }

        @Test func graphQLPreflightFailuresPreserveEnvelopeMetadata() async throws {
            let fixture = try GatewayRuntimeFixture()
            defer { fixture.remove() }
            GatewayRuntimeURLProtocol.reset()
            URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
                GatewayRuntimeURLProtocol.reset()
            }

            let sdk = GmailGatewaySDK(mode: .reader)
            let cases = [
                ("query { accounts { id }", "SYNTAX", nil),
                ("{ unknown { id } }", "UNKNOWN_FIELD", ["unknown"]),
                ("""
                { first: threads(input: { accountId: "personal", first: 500 }) { edges { node { messages { id } } } }
                  second: threads(input: { accountId: "personal", first: 500 }) { edges { node { messages { id } } } } }
                """, "RESOURCE_LIMIT", nil)
            ]
            for (document, code, path) in cases {
                GatewayRuntimeURLProtocol.reset()
                let envelope = await sdk.execute(document: document, variables: [:], environment: fixture.environment)
                try assertPreflightEnvelope(envelope, code: code, path: path)
                #expect(GatewayRuntimeURLProtocol.requests.isEmpty)
            }

            let result = GmailGatewayCLI(mode: .reader).run(
                arguments: ["graphql", "--query", "{ unknown { id } }"],
                environment: fixture.environment
            )
            #expect(result.exitCode == 2)
            let cliEnvelope = GatewayEnvelope(parsingCLIOutput: result.stdout, exitCode: result.exitCode)
            try assertPreflightEnvelope(cliEnvelope, code: "UNKNOWN_FIELD", path: ["unknown"])
            #expect(GatewayRuntimeURLProtocol.requests.isEmpty)
        }

        @Test func sdkCancellationPreservesMutationOutcomesAndStopsFurtherProviderWork() async throws {
            let fixture = try GatewayRuntimeFixture(accessMode: .readSend)
            defer { fixture.remove() }
            GatewayRuntimeURLProtocol.reset()
            GatewayRuntimeURLProtocol.responseDelay = 0.25
            GatewayRuntimeURLProtocol.responseStatusCodes = [500]
            URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
                GatewayRuntimeURLProtocol.reset()
            }

            let sendMessageDocument = "mutation { sendMessage(input: { accountId: \"personal\", to: [\"a@example.test\"], textBody: \"x\" }) { status } }"

            let retryTask = Task {
                await GmailGatewaySDK(mode: .reader).execute(
                    document: "{ threads(input: { accountId: \"personal\" }) { totalCount } }",
                    variables: [:],
                    environment: fixture.environment
                )
            }
            try await waitForProviderRequests(count: 1)
            retryTask.cancel()
            let retryResult = await retryTask.value
            #expect(retryResult.errors.first?.code == GmailGatewayErrorCode.cancelled.rawValue)
            try await Task.sleep(for: .milliseconds(350))
            #expect(GatewayRuntimeURLProtocol.requests.count == 1)

            GatewayRuntimeURLProtocol.reset()
            GatewayRuntimeURLProtocol.responseStatusCodes = [500]
            let retryBackoffTask = Task {
                await GmailGatewaySDK(mode: .reader).execute(
                    document: "{ threads(input: { accountId: \"personal\" }) { totalCount } }",
                    variables: [:],
                    environment: fixture.environment
                )
            }
            try await waitForProviderRequests(count: 1)
            try await waitForProviderResponses(count: 1)
            try await Task.sleep(for: .milliseconds(10))
            retryBackoffTask.cancel()
            let retryBackoffResult = await retryBackoffTask.value
            #expect(retryBackoffResult.errors.map(\.code) == [GmailGatewayErrorCode.cancelled.rawValue])
            try await Task.sleep(for: .milliseconds(100))
            #expect(GatewayRuntimeURLProtocol.requests.count == 1)

            GatewayRuntimeURLProtocol.reset()
            GatewayRuntimeURLProtocol.responseDelay = 0.25
            let definitiveMutationTask = Task {
                await GmailGatewaySDK(mode: .directSender).execute(
                    document: sendMessageDocument,
                    variables: [:],
                    environment: fixture.environment
                )
            }
            try await waitForProviderRequests(count: 1)
            definitiveMutationTask.cancel()
            let definitiveMutationResult = await definitiveMutationTask.value
            #expect(definitiveMutationResult.exitCode == 0)
            #expect(definitiveMutationResult.errors.isEmpty)
            #expect(string(at: ["sendMessage", "status"], in: definitiveMutationResult) == "SENT")
            #expect(GatewayRuntimeURLProtocol.requests.count == 1)
            #expect(GatewayRuntimeURLProtocol.requests.first?.url.hasSuffix("/gmail/v1/users/me/messages/send") == true)

            for statusCode in [403, 500] {
                GatewayRuntimeURLProtocol.reset()
                GatewayRuntimeURLProtocol.responseDelay = 0.25
                GatewayRuntimeURLProtocol.responseStatusCodes = [statusCode]
                let failedMutationTask = Task {
                    await GmailGatewaySDK(mode: .directSender).execute(
                        document: sendMessageDocument,
                        variables: [:],
                        environment: fixture.environment
                    )
                }
                try await waitForProviderRequests(count: 1)
                failedMutationTask.cancel()
                let failedMutationResult = await failedMutationTask.value
                #expect(failedMutationResult.exitCode == GmailGatewayExitCode.generalError.rawValue)
                guard case .object(let failedMutationData)? = failedMutationResult.data else {
                    #expect(Bool(false), "Provider failure must return its null root field")
                    return
                }
                #expect(failedMutationData["sendMessage"] == .null)
                #expect(failedMutationResult.errors.map(\.code) == [GmailGatewayErrorCode.providerApiError.rawValue])
                #expect(!failedMutationResult.errors.map(\.code).contains(GmailGatewayErrorCode.cancelled.rawValue))
                #expect(!failedMutationResult.errors.map(\.code).contains(GmailGatewayErrorCode.mutationOutcomeUnknown.rawValue))
                #expect(GatewayRuntimeURLProtocol.requests.count == 1)
                #expect(GatewayRuntimeURLProtocol.requests.first?.method == "POST")
                #expect(GatewayRuntimeURLProtocol.requests.first?.url.hasSuffix("/gmail/v1/users/me/messages/send") == true)
            }

            GatewayRuntimeURLProtocol.reset()
            GatewayRuntimeURLProtocol.responseDelay = 0.25
            GatewayRuntimeURLProtocol.responseLostAfterProviderAcceptance = true
            let unknownMutationTask = Task {
                await GmailGatewaySDK(mode: .directSender).execute(
                    document: sendMessageDocument,
                    variables: [:],
                    environment: fixture.environment
                )
            }
            try await waitForProviderRequests(count: 1)
            unknownMutationTask.cancel()
            let unknownMutationResult = await unknownMutationTask.value
            #expect(unknownMutationResult.exitCode == 1)
            guard case .object(let unknownMutationData)? = unknownMutationResult.data else {
                #expect(Bool(false), "Unknown mutation outcome must return its null root field")
                return
            }
            #expect(unknownMutationData["sendMessage"] == .null)
            #expect(unknownMutationResult.errors.map(\.code) == [GmailGatewayErrorCode.mutationOutcomeUnknown.rawValue])
            #expect(GatewayRuntimeURLProtocol.requests.count == 1)
            #expect(GatewayRuntimeURLProtocol.requests.first?.url.hasSuffix("/gmail/v1/users/me/messages/send") == true)

            GatewayRuntimeURLProtocol.reset()
            GatewayRuntimeURLProtocol.responseDelay = 0.25
            GatewayRuntimeURLProtocol.responseLostAfterProviderAcceptance = true
            let uncancelledLostMutationResult = await GmailGatewaySDK(mode: .directSender).execute(
                document: sendMessageDocument,
                variables: [:],
                environment: fixture.environment
            )
            #expect(uncancelledLostMutationResult.exitCode == 1)
            guard case .object(let uncancelledLostMutationData)? = uncancelledLostMutationResult.data else {
                #expect(Bool(false), "Uncancelled lost mutation outcome must return its null root field")
                return
            }
            #expect(uncancelledLostMutationData["sendMessage"] == .null)
            #expect(uncancelledLostMutationResult.errors.map(\.code) == [GmailGatewayErrorCode.mutationOutcomeUnknown.rawValue])
            #expect(GatewayRuntimeURLProtocol.requests.count == 1)
            #expect(GatewayRuntimeURLProtocol.requests.first?.method == "POST")
            #expect(GatewayRuntimeURLProtocol.requests.first?.url.hasSuffix("/gmail/v1/users/me/messages/send") == true)

            GatewayRuntimeURLProtocol.reset()
            GatewayRuntimeURLProtocol.responseDelay = 0.25
            let updateTask = Task {
                await GmailGatewaySDK(mode: .draftGateway).execute(
                    document: "mutation { updateDraft(input: { accountId: \"personal\", draftId: \"draft-1\", textBody: \"x\" }) { status } }",
                    variables: [:],
                    environment: fixture.environment
                )
            }
            try await waitForProviderRequests(count: 1)
            updateTask.cancel()
            let updateResult = await updateTask.value
            #expect(updateResult.exitCode == 1)
            guard case .object(let updateData)? = updateResult.data else {
                #expect(Bool(false), "Cancelled mutation must return its null root field")
                return
            }
            #expect(updateData["updateDraft"] == .null)
            #expect(updateResult.errors.map(\.code) == [GmailGatewayErrorCode.cancelled.rawValue])
            try await Task.sleep(for: .milliseconds(350))
            #expect(GatewayRuntimeURLProtocol.requests.count == 1)
            #expect(GatewayRuntimeURLProtocol.requests.first?.method == "GET")
            #expect(GatewayRuntimeURLProtocol.requests.first?.url.contains("/gmail/v1/users/me/drafts/draft-1") == true)
            #expect(!GatewayRuntimeURLProtocol.methods.contains("PUT"))
            #expect(GatewayRuntimeURLProtocol.stoppedRequestCount >= 1)
        }

        @Test func dispatchedMutationResponseDeadlineBoundsStalledAndDripFedTransfers() async throws {
            GmailDeadlineURLProtocol.reset()
            URLProtocol.registerClass(GmailDeadlineURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(GmailDeadlineURLProtocol.self)
                GmailDeadlineURLProtocol.reset()
            }

            for mode in [GmailDeadlineURLProtocol.Mode.stalled, .dripFed] {
                GmailDeadlineURLProtocol.reset()
                GmailDeadlineURLProtocol.mode = mode
                var request = URLRequest(url: URL(string: "https://gmail-deadline.test/test")!)
                request.httpMethod = "POST"
                request.timeoutInterval = 0.05

                let clock = ContinuousClock()
                let started = clock.now
                let deadlineTask = Task.detached { () -> GmailGatewayError? in
                    do {
                        _ = try performGmailHTTPRequest(
                            request,
                            context: "Gmail deadline test",
                            effect: .gmailMutation
                        )
                        return nil
                    } catch let error as GmailGatewayError {
                        return error
                    } catch {
                        return GmailGatewayError(
                            "Unexpected deadline-test error",
                            code: .unexpectedError,
                            exitCode: .generalError
                        )
                    }
                }
                let error = await deadlineTask.value

                let elapsed = started.duration(to: clock.now)
                let gatewayError = try #require(error)
                #expect(gatewayError.code == GmailGatewayErrorCode.mutationOutcomeUnknown)
                #expect(elapsed < .seconds(1))
                #expect(GmailDeadlineURLProtocol.requestCount == 1)
                try await waitForDeadlineProviderStop()
                #expect(GmailDeadlineURLProtocol.stoppedRequestCount == 1)
            }
        }

        @Test func definitiveMutationResponsesWithUndecodableBodiesRemainSuccessful() async throws {
            let fixture = try GatewayRuntimeFixture(accessMode: .readSend)
            defer { fixture.remove() }
            URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
                GatewayRuntimeURLProtocol.reset()
            }

            let document = "mutation { sendMessage(input: { accountId: \"personal\", to: [\"a@example.test\"], textBody: \"x\" }) { status } }"
            let invalidBodies = [
                ("empty", Data()),
                ("truncated", Data("{\"id\":".utf8)),
                ("non-object", Data("[]".utf8))
            ]
            for (name, responseData) in invalidBodies {
                GatewayRuntimeURLProtocol.reset()
                GatewayRuntimeURLProtocol.data = responseData
                let sdk = await GmailGatewaySDK(mode: .directSender).execute(
                    document: document,
                    variables: [:],
                    environment: fixture.environment
                )
                #expect(sdk.exitCode == 0, "SDK \(name) response must preserve definitive mutation success")
                #expect(sdk.errors.isEmpty)
                #expect(string(at: ["sendMessage", "status"], in: sdk) == "SENT")
                #expect(GatewayRuntimeURLProtocol.requests.count == 1)
                #expect(!sdk.errors.map(\.code).contains(GmailGatewayErrorCode.providerApiError.rawValue))
                #expect(!sdk.errors.map(\.code).contains(GmailGatewayErrorCode.cancelled.rawValue))
                #expect(!sdk.errors.map(\.code).contains(GmailGatewayErrorCode.mutationOutcomeUnknown.rawValue))

                GatewayRuntimeURLProtocol.reset()
                GatewayRuntimeURLProtocol.data = responseData
                let cli = GmailGatewayCLI(mode: .directSender).run(
                    arguments: ["graphql", "--query", document],
                    environment: fixture.environment
                )
                #expect(cli.exitCode == 0, "CLI \(name) response must preserve definitive mutation success")
                try assertCompleteSuccessEnvelope(cli, expectedData: ["sendMessage": ["status": "SENT"]])
                #expect(GatewayRuntimeURLProtocol.requests.count == 1)
                let envelope = GatewayEnvelope(parsingCLIOutput: cli.stdout, exitCode: cli.exitCode)
                #expect(!envelope.errors.map(\.code).contains(GmailGatewayErrorCode.providerApiError.rawValue))
                #expect(!envelope.errors.map(\.code).contains(GmailGatewayErrorCode.cancelled.rawValue))
                #expect(!envelope.errors.map(\.code).contains(GmailGatewayErrorCode.mutationOutcomeUnknown.rawValue))
            }
        }

        @Test func definitiveMutationHeadersSurviveResponsePlusTransportError() async throws {
            let fixture = try GatewayRuntimeFixture(accessMode: .readSend)
            defer { fixture.remove() }
            URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
                GatewayRuntimeURLProtocol.reset()
            }

            let document = "mutation { sendMessage(input: { accountId: \"personal\", to: [\"a@example.test\"], textBody: \"x\" }) { status } }"
            for statusCode in [200, 403, 500] {
                GatewayRuntimeURLProtocol.reset()
                GatewayRuntimeURLProtocol.responseStatusCodes = [statusCode]
                GatewayRuntimeURLProtocol.responseFailsAfterHTTPResponse = true
                let result = await GmailGatewaySDK(mode: .directSender).execute(
                    document: document,
                    variables: [:],
                    environment: fixture.environment
                )

                #expect(GatewayRuntimeURLProtocol.requests.count == 1)
                #expect(GatewayRuntimeURLProtocol.requests.first?.method == "POST")
                #expect(GatewayRuntimeURLProtocol.requests.first?.url.hasSuffix("/gmail/v1/users/me/messages/send") == true)
                #expect(!result.errors.map(\.code).contains(GmailGatewayErrorCode.cancelled.rawValue))
                #expect(!result.errors.map(\.code).contains(GmailGatewayErrorCode.mutationOutcomeUnknown.rawValue))

                if statusCode == 200 {
                    #expect(result.exitCode == 0)
                    #expect(result.errors.isEmpty)
                    #expect(string(at: ["sendMessage", "status"], in: result) == "SENT")
                } else {
                    #expect(result.exitCode == GmailGatewayExitCode.generalError.rawValue)
                    guard case .object(let data)? = result.data else {
                        #expect(Bool(false), "Definitive HTTP failure must return its null mutation root")
                        return
                    }
                    #expect(data["sendMessage"] == .null)
                    #expect(result.errors.map(\.code) == [GmailGatewayErrorCode.providerApiError.rawValue])
                }
            }
        }

        @Test func sdkCancellationDuringOAuthRefreshReturnsCancelledWithoutGmailDispatch() async throws {
            let fixture = try GatewayRuntimeFixture()
            defer { fixture.remove() }
            let tokenVariable = GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
                credentialId: "gmail-personal",
                valueKey: "token_store_json"
            )
            var environment = fixture.environment
            environment[tokenVariable] = """
            {"accessMode":"read","accessToken":"expired","refreshToken":"refresh","expiresAt":"2000-01-01T00:00:00Z"}
            """
            let oauthClient = """
            {"installed":{"client_id":"test-client","token_uri":"https://gmail.googleapis.com/oauth/token"}}
            """
            try Data(oauthClient.utf8).write(to: fixture.root.appendingPathComponent("client.json"))

            GatewayRuntimeURLProtocol.reset()
            GatewayRuntimeURLProtocol.responseDelay = 0.25
            URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
                GatewayRuntimeURLProtocol.reset()
            }

            let task = Task {
                await GmailGatewaySDK(mode: .reader).execute(
                    document: "{ threads(input: { accountId: \"personal\" }) { totalCount } }",
                    variables: [:],
                    environment: environment
                )
            }
            try await waitForProviderRequests(count: 1)
            task.cancel()
            let result = await task.value

            #expect(result.exitCode == 1)
            #expect(result.errors.map(\.code) == [GmailGatewayErrorCode.cancelled.rawValue])
            #expect(!result.errors.map(\.code).contains(GmailGatewayErrorCode.mutationOutcomeUnknown.rawValue))
            #expect(GatewayRuntimeURLProtocol.requests.count == 1)
            #expect(GatewayRuntimeURLProtocol.requests.first?.url.hasSuffix("/oauth/token") == true)
            #expect(!GatewayRuntimeURLProtocol.urls.contains { $0.path.hasPrefix("/gmail/v1/") })
            #expect(GatewayRuntimeURLProtocol.stoppedRequestCount >= 1)
        }

        @Test func sdkAndCLIShareCanonicalRawGraphQLEnvelopes() async throws {
            let fixture = try GatewayRuntimeFixture()
            defer { fixture.remove() }
            GatewayRuntimeURLProtocol.reset()
            URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
                GatewayRuntimeURLProtocol.reset()
            }

            let resourceLimit = """
            { first: threads(input: { accountId: "personal", first: 500 }) { edges { node { messages { id } } } }
              second: threads(input: { accountId: "personal", first: 500 }) { edges { node { messages { id } } } } }
            """
            let missingTokenEnvironment = ["GMAIL_GATEWAY_CONFIG": fixture.configPath]
            let cases: [EnvelopeParityCase] = [
                .init(name: "success", document: "{ threads(input: { accountId: \"personal\" }) { totalCount } }", environment: fixture.environment, exitCode: 0),
                .init(name: "validation", document: "{ unknown { id } }", environment: fixture.environment, exitCode: 2),
                .init(name: "resolver", document: "{ threads(input: { accountId: \"personal\" }) { totalCount } }", environment: missingTokenEnvironment, exitCode: 1),
                .init(name: "resource-limit", document: resourceLimit, environment: fixture.environment, exitCode: 2)
            ]

            for entry in cases {
                GatewayRuntimeURLProtocol.reset()
                let sdk = await GmailGatewaySDK(mode: .reader).execute(
                    document: entry.document,
                    variables: [:],
                    environment: entry.environment
                )
                #expect(sdk.exitCode == entry.exitCode)
                #expect(sdk.rawOutput.hasSuffix("\n"))
                #expect(!sdk.rawOutput.hasSuffix("\n\n"))
                #expect(
                    try GmailGatewayGraphQLEnvelopeSerializer.output(sdk, pretty: false) == sdk.rawOutput,
                    "SDK \(entry.name) output must already be canonical"
                )

                GatewayRuntimeURLProtocol.reset()
                let cli = GmailGatewayCLI(mode: .reader).run(
                    arguments: ["graphql", "--query", entry.document],
                    environment: entry.environment
                )
                #expect(cli.exitCode == entry.exitCode)
                #expect(cli.stdout.hasSuffix("\n"))
                #expect(!cli.stdout.hasSuffix("\n\n"))
                let cliEnvelope = GatewayEnvelope(parsingCLIOutput: cli.stdout, exitCode: cli.exitCode)
                #expect(
                    try GmailGatewayGraphQLEnvelopeSerializer.output(cliEnvelope, pretty: false) == cli.stdout,
                    "CLI \(entry.name) output must be canonical"
                )
                #expect(
                    try envelopeWithoutRequestId(sdk.rawOutput) == envelopeWithoutRequestId(cli.stdout),
                    "SDK and CLI \(entry.name) envelopes must differ only by request ID"
                )
            }

            let pretty = GmailGatewayCLI(mode: .reader).run(
                arguments: ["graphql", "--pretty", "--query", "{ threads(input: { accountId: \"personal\" }) { totalCount } }"],
                environment: fixture.environment
            )
            #expect(pretty.exitCode == 0)
            #expect(pretty.stdout.hasSuffix("\n"))
            #expect(!pretty.stdout.hasSuffix("\n\n"))
        }
    }
}

private func waitForProviderRequests(count: Int) async throws {
    for _ in 0..<100 {
        if GatewayRuntimeURLProtocol.requests.count >= count { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw GmailGatewayError(
        "Timed out waiting for provider request",
        code: .unexpectedError,
        exitCode: .generalError
    )
}

private func waitForProviderResponses(count: Int) async throws {
    for _ in 0..<100 {
        if GatewayRuntimeURLProtocol.completedResponseCount >= count { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw GmailGatewayError(
        "Timed out waiting for provider response",
        code: .unexpectedError,
        exitCode: .generalError
    )
}

private func waitForDeadlineProviderStop() async throws {
    for _ in 0..<100 {
        if GmailDeadlineURLProtocol.stoppedRequestCount >= 1 { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw GmailGatewayError(
        "Timed out waiting for cancelled deadline-test provider request",
        code: .unexpectedError,
        exitCode: .generalError
    )
}

private final class GmailDeadlineURLProtocol: URLProtocol {
    enum Mode: Equatable {
        case stalled
        case dripFed
    }

    nonisolated(unsafe) static var mode: Mode = .stalled
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var stoppedRequestCount = 0

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "gmail-deadline.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1
        guard Self.mode == .dripFed else { return }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://gmail-deadline.test/")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        drip()
    }

    override func stopLoading() {
        Self.stoppedRequestCount += 1
    }

    static func reset() {
        mode = .stalled
        requestCount = 0
        stoppedRequestCount = 0
    }

    private func drip() {
        client?.urlProtocol(self, didLoad: Data(" ".utf8))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.005) { [weak self] in
            guard Self.stoppedRequestCount == 0 else { return }
            self?.drip()
        }
    }
}

extension GmailDeadlineURLProtocol: @unchecked Sendable {}

private func assertPreflightEnvelope(_ envelope: GatewayEnvelope, code: String, path: [String]?) throws {
    #expect(envelope.exitCode == 2)
    #expect(envelope.data == nil)
    #expect(envelope.errors.map(\.code) == [code])
    #expect(envelope.errors.first?.path == path)
    let requestId = try #require(envelope.requestId)
    let raw = try GatewayJSONValue.parse(envelope.rawOutput)
    guard case .object(let root) = raw else {
        #expect(Bool(false), "preflight raw output must be a GraphQL envelope")
        return
    }
    #expect(root["data"] == .null)
    guard case .object(let extensions) = root["extensions"] else {
        #expect(Bool(false), "preflight raw output must include extensions")
        return
    }
    #expect(extensions["requestId"] == .string(requestId))
    guard case .array(let errors) = root["errors"],
          case .object(let firstError) = errors.first else {
        #expect(Bool(false), "preflight raw output must include one error")
        return
    }
    let rawCode: GatewayJSONValue?
    if let code = firstError["code"] {
        rawCode = code
    } else if case .object(let extensions) = firstError["extensions"] {
        rawCode = extensions["code"]
    } else {
        rawCode = nil
    }
    #expect(rawCode == .string(code))
    if let path {
        #expect(firstError["path"] == .array(path.map(GatewayJSONValue.string)))
    } else {
        #expect(firstError["path"] == nil)
    }
}

private func strictConfigurationCase(
    name: String,
    source: String,
    replacing original: String,
    with replacement: String,
    fixture: GatewayRuntimeFixture
) throws -> StrictConfigurationCase {
    let path = fixture.root.appendingPathComponent("\(name).toml")
    try Data(source.replacingOccurrences(of: original, with: replacement).utf8).write(to: path)
    return .init(configPath: path.path, environment: fixture.environment)
}

private func envelopeWithoutRequestId(_ rawOutput: String) throws -> GatewayJSONValue {
    guard case .object(var envelope) = try GatewayJSONValue.parse(rawOutput) else {
        throw EnvelopeParityError.invalidJSON
    }
    if case .object(var extensions)? = envelope["extensions"] {
        extensions.removeValue(forKey: "requestId")
        if extensions.isEmpty {
            envelope.removeValue(forKey: "extensions")
        } else {
            envelope["extensions"] = .object(extensions)
        }
    }
    return .object(envelope)
}

private enum EnvelopeParityError: Error {
    case invalidJSON
}

private func bool(at path: [String], in envelope: GatewayEnvelope) -> Bool? {
    var value = envelope.data
    for component in path {
        if let index = Int(component), case .array(let values)? = value {
            value = values.indices.contains(index) ? values[index] : nil
        } else if case .object(let object)? = value {
            value = object[component]
        } else {
            return nil
        }
    }
    guard case .bool(let result)? = value else { return nil }
    return result
}

private func string(at path: [String], in envelope: GatewayEnvelope) -> String? {
    var value = envelope.data
    for component in path {
        if let index = Int(component), case .array(let values)? = value {
            value = values.indices.contains(index) ? values[index] : nil
        } else if case .object(let object)? = value {
            value = object[component]
        } else {
            return nil
        }
    }
    guard case .string(let result)? = value else { return nil }
    return result
}
