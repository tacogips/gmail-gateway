import Foundation
import GatewaySDKKit
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GmailGatewayCore

// The declarative root matrix keeps each operation, document, and input together for auditability.
// swiftlint:disable line_length large_tuple

extension GmailRequestProtocolTests {
    @Suite(.serialized)
    struct GmailGatewayRuntimeMatrixTests {
        @Test func rootInvocationMatrixMatchesTheIndependentAcceptedOperationSet() {
            let expected = GmailGatewayAcceptedRuntimeContract.readOperations
                .union(GmailGatewayAcceptedRuntimeContract.draftOperations)
                .union(GmailGatewayAcceptedRuntimeContract.senderOperations)
                .union(GmailGatewayAcceptedRuntimeContract.mailboxOperations)
                .union(GmailGatewayAcceptedRuntimeContract.ingestOperations)
            #expect(Set(RootInvocation.all.map(\.name)) == expected)
        }

        @Test func everyRootAndModeReportsTheExactCapabilityOutcomeForEveryCLIForm() throws {
            for invocation in RootInvocation.all {
                let fixture = try GatewayRuntimeFixture(accessMode: invocation.accessMode)
                defer { fixture.remove() }
                let sourcePath = try makeRFC822Source(in: fixture, required: invocation.needsSource)
                URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
                defer {
                    URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
                    GatewayRuntimeURLProtocol.reset()
                }
                for mode in GmailGatewayCLIMode.all {
                    let isAuthorized = GmailGatewayAcceptedRuntimeContract.authorized(invocation.name, in: mode)
                    GatewayRuntimeURLProtocol.reset()
                    let literal = GmailGatewayCLI(mode: mode).run(
                        arguments: ["graphql", "--query", invocation.literal(sourcePath: sourcePath)],
                        environment: fixture.environment
                    )
                    try assertCapabilityOutcome(
                        literal,
                        invocation: invocation,
                        mode: mode,
                        authorized: isAuthorized,
                        form: "literal"
                    )

                    GatewayRuntimeURLProtocol.reset()
                    let built = try invocation.variableDocument(sourcePath: sourcePath)
                    let variables = try GatewayJSONValue.object(built.variables).jsonString(pretty: false)
                    let variable = GmailGatewayCLI(mode: mode).run(
                        arguments: ["graphql", "--query", built.document, "--variables", variables],
                        environment: fixture.environment
                    )
                    try assertCapabilityOutcome(
                        variable,
                        invocation: invocation,
                        mode: mode,
                        authorized: isAuthorized,
                        form: "raw variables"
                    )

                    GatewayRuntimeURLProtocol.reset()
                    let explicitQuery = GmailGatewayCLI(mode: mode).run(
                        arguments: ["graphql", "query", "--query", built.document, "--variables", variables],
                        environment: fixture.environment
                    )
                    try assertCapabilityOutcome(
                        explicitQuery,
                        invocation: invocation,
                        mode: mode,
                        authorized: isAuthorized,
                        form: "explicit query"
                    )

                    GatewayRuntimeURLProtocol.reset()
                    let operation = GmailGatewayCLI(mode: mode).run(
                        arguments: [
                            "graphql", "operation", invocation.name,
                            "--variables", variables,
                            "--select", invocation.operationSelection
                        ],
                        environment: fixture.environment
                    )
                    try assertCapabilityOutcome(
                        operation,
                        invocation: invocation,
                        mode: mode,
                        authorized: isAuthorized,
                        form: "operation"
                    )
                }
            }
        }

        @Test func runtimeRejectsValidationErrorsBeforeNetworkDispatch() throws {
            let fixture = try GatewayRuntimeFixture()
            defer { fixture.remove() }
            GatewayRuntimeURLProtocol.reset()
            URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
                GatewayRuntimeURLProtocol.reset()
            }
            let cli = GmailGatewayCLI(mode: .reader)
            let cases: [(name: String, code: String, query: String, variables: String)] = [
                ("syntax", "SYNTAX", "query { accounts { id }", "{}"),
                ("unknown field", "UNKNOWN_FIELD", "{ unknown { id } }", "{}"),
                ("unknown argument", "UNKNOWN_ARGUMENT", "{ accounts(nope: \"x\") { id } }", "{}"),
                ("missing argument", "MISSING_ARGUMENT", "{ account { id } }", "{}"),
                ("argument type", "ARGUMENT_TYPE", "{ threads(input: \"wrong\") { totalCount } }", "{}"),
                ("unknown variable", "UNKNOWN_VARIABLE", "{ accounts { id } }", #"{"extra":true}"#),
                ("unused variable", "UNUSED_VARIABLE", "query ($id: ID!) { accounts { id } }", #"{"id":"personal"}"#),
                ("undeclared variable", "UNDECLARED_VARIABLE", "query { account(id: $id) { id } }", "{}"),
                ("missing variable", "MISSING_VARIABLE", "query ($input: ThreadSearchInput!) { threads(input: $input) { totalCount } }", "{}"),
                ("variable type", "VARIABLE_TYPE", "query ($input: ThreadSearchInput!) { threads(input: $input) { totalCount } }", #"{"input":"wrong"}"#),
                // Parser-level duplicate declarations and depth limits deliberately take
                // SYNTAX precedence; direct validator cases below retain their stable codes.
                ("duplicate variable parser precedence", "SYNTAX", "query ($id: ID!, $id: ID!) { account(id: $id) { id } }", #"{"id":"personal"}"#),
                ("invalid selection", "INVALID_SELECTION", "{ accounts { id { nested } } }", "{}"),
                // The parser rejects a repeated argument before the validator can produce
                // DUPLICATE_ARGUMENT; retain that deterministic SYNTAX precedence explicitly.
                ("duplicate argument", "SYNTAX", "{ account(id: \"a\", id: \"b\") { id } }", "{}"),
                ("duplicate alias", "DUPLICATE_ALIAS", "{ same: accounts { id } same: accounts { id } }", "{}"),
                ("multiple mutations", "MULTIPLE_MUTATIONS", "mutation { createLabel(input: { accountId: \"personal\", name: \"A\" }) { status } deleteLabel(input: { accountId: \"personal\", labelId: \"Label_1\" }) { status } }", "{}")
            ]
            for entry in cases {
                GatewayRuntimeURLProtocol.reset()
                let result = cli.run(
                    arguments: ["graphql", "--query", entry.query, "--variables", entry.variables],
                    environment: fixture.environment
                )
                assertValidatorFailure(result, code: entry.code, name: entry.name)
            }
            let depthLimitDocument = "{ accounts { "
                + String(repeating: "id { ", count: 33)
                + "id"
                + String(repeating: " }", count: 33)
                + " } }"
            GatewayRuntimeURLProtocol.reset()
            let resourceLimit = cli.run(
                arguments: ["graphql", "--query", depthLimitDocument],
                environment: fixture.environment
            )
            assertValidatorFailure(resourceLimit, code: "SYNTAX", name: "parser resource limit")
            #expect(resourceLimit.stdout.contains("resource limit exceeded"))
            let unsupportedCases = [
                ("fragment", "query { accounts { id } } fragment AccountFields on MailAccount { id }", "fragments are not supported"),
                ("directive", "query { accounts @skip(if: true) { id } }", "directives are not supported"),
                ("subscription", "subscription { accounts { id } }", "subscriptions are not supported"),
                ("multiple operations", "query One { accounts { id } } query Two { accounts { id } }", "multiple operations are not supported"),
                ("introspection", "{ __schema { types { name } } }", "introspection is not supported")
            ]
            for (feature, document, message) in unsupportedCases {
                GatewayRuntimeURLProtocol.reset()
                let result = cli.run(
                    arguments: ["graphql", "--query", document],
                    environment: fixture.environment
                )
                let envelope = assertValidatorFailure(result, code: "SYNTAX", name: feature)
                #expect(envelope.errors.first?.message.hasSuffix(message) == true)
            }
        }

        @Test func validatorExposesStableDuplicateAndResourceCodesWhenInvokedWithAnAST() throws {
            let validator = GatewayGraphQLValidator(catalog: .gmailFull)
            let account = GatewayGraphQLDocument.Selection(
                name: "account",
                arguments: [.init(name: "id", value: .string("personal"))],
                selectionSet: [.init(name: "id")]
            )
            let duplicateVariable = GatewayGraphQLDocument(
                operationType: .query,
                variableDefinitions: [
                    .init(name: "id", type: .nonNull(.named("ID"))),
                    .init(name: "id", type: .nonNull(.named("ID")))
                ],
                selectionSet: [account]
            )
            let duplicateArgument = GatewayGraphQLDocument(
                operationType: .query,
                selectionSet: [
                    .init(
                        name: "account",
                        arguments: [
                            .init(name: "id", value: .string("personal")),
                            .init(name: "id", value: .string("personal"))
                        ],
                        selectionSet: [.init(name: "id")]
                    )
                ]
            )
            var deepSelection = GatewayGraphQLDocument.Selection(name: "id")
            for _ in 0...32 {
                deepSelection = .init(name: "id", selectionSet: [deepSelection])
            }
            let resourceLimit = GatewayGraphQLDocument(
                operationType: .query,
                selectionSet: [.init(name: "accounts", selectionSet: [deepSelection])]
            )
            #expect(try validationCode(from: validator, document: duplicateVariable) == "DUPLICATE_VARIABLE")
            #expect(try validationCode(from: validator, document: duplicateArgument) == "DUPLICATE_ARGUMENT")
            #expect(try validationCode(from: validator, document: resourceLimit) == "RESOURCE_LIMIT")
        }

        @Test func eachUnauthorizedRootReturnsCapabilityDeniedWithoutNetworkDispatch() throws {
            let fixture = try GatewayRuntimeFixture(accessMode: .full)
            defer { fixture.remove() }
            GatewayRuntimeURLProtocol.reset()
            URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
                GatewayRuntimeURLProtocol.reset()
            }
            for invocation in RootInvocation.all {
                for mode in GmailGatewayCLIMode.all where !GmailGatewayAcceptedRuntimeContract.authorized(invocation.name, in: mode) {
                    GatewayRuntimeURLProtocol.reset()
                    let result = GmailGatewayCLI(mode: mode).run(
                        arguments: ["graphql", "--query", invocation.literal(sourcePath: "/tmp/message.eml")],
                        environment: fixture.environment
                    )
                    #expect(result.exitCode == 1)
                    #expect(result.stdout.contains("\"CAPABILITY_DENIED\""))
                    #expect(result.stdout.contains("tier '\(mode.gatewayTier)'"))
                    #expect(GatewayRuntimeURLProtocol.urls.isEmpty)
                }
            }
        }

        @Test func runtimeSupportsMultipleQueryRootsAndProjectsMissingNestedKeysAsNull() throws {
            let fixture = try GatewayRuntimeFixture()
            defer { fixture.remove() }
            GatewayRuntimeURLProtocol.reset()
            URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
                GatewayRuntimeURLProtocol.reset()
            }
            let cli = GmailGatewayCLI(mode: .reader)
            let multipleRoots = cli.run(
                arguments: ["graphql", "--query", "{ accounts { id } account(id: \"personal\") { id } }"],
                environment: fixture.environment
            )
            #expect(multipleRoots.exitCode == 0)
            #expect(multipleRoots.stdout.contains("accounts"))
            #expect(multipleRoots.stdout.contains("account"))

            let projected = cli.run(
                arguments: ["graphql", "--query", "{ message(accountId: \"personal\", messageId: \"message-id\") { from { raw address } providerMetadata { gmail { attachmentId } } } }"],
                environment: fixture.environment
            )
            #expect(projected.exitCode == 0)
            #expect(projected.stdout.contains("Display Name <person@example.com>"))
            #expect(projected.stdout.contains("attachmentId"))
            #expect(projected.stdout.contains("null"))
        }

        @Test func executionWideProviderBudgetBoundsAliasedThreadAndDraftHydration() throws {
            let fixture = try GatewayRuntimeFixture(accessMode: .readSend)
            defer { fixture.remove() }
            GatewayRuntimeURLProtocol.reset()
            URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
                GatewayRuntimeURLProtocol.reset()
            }

            let threadsOverBudget = """
            { first: threads(input: { accountId: "personal", first: 500 }) { edges { node { messages { id } } } }
              second: threads(input: { accountId: "personal", first: 500 }) { edges { node { messages { id } } } } }
            """
            let readerResult = GmailGatewayCLI(mode: .reader).run(
                arguments: ["graphql", "--query", threadsOverBudget],
                environment: fixture.environment
            )
            #expect(readerResult.exitCode == 2)
            #expect(readerResult.stdout.contains("\"RESOURCE_LIMIT\""))
            #expect(GatewayRuntimeURLProtocol.requests.isEmpty)

            let draftsOverBudget = """
            { first: drafts(accountId: "personal", first: 500) { edges { node { id } } }
              second: drafts(accountId: "personal", first: 500) { edges { node { id } } } }
            """
            GatewayRuntimeURLProtocol.reset()
            let draftResult = GmailGatewayCLI(mode: .draftGateway).run(
                arguments: ["graphql", "--query", draftsOverBudget],
                environment: fixture.environment
            )
            #expect(draftResult.exitCode == 2)
            #expect(draftResult.stdout.contains("\"RESOURCE_LIMIT\""))
            #expect(GatewayRuntimeURLProtocol.requests.isEmpty)

            let mixedThreadHydration = """
            { detailed: threads(input: { accountId: "personal", first: 500 }) { edges { node { messages { id } } } }
              summary: threads(input: { accountId: "personal", first: 500 }) { totalCount } }
            """
            GatewayRuntimeURLProtocol.reset()
            let mixedThreadResult = GmailGatewayCLI(mode: .reader).run(
                arguments: ["graphql", "--query", mixedThreadHydration],
                environment: fixture.environment
            )
            #expect(mixedThreadResult.exitCode == 2)
            #expect(mixedThreadResult.stdout.contains("\"RESOURCE_LIMIT\""))
            #expect(GatewayRuntimeURLProtocol.requests.isEmpty)

            let mixedDraftHydration = """
            { detailed: drafts(accountId: "personal", first: 500) { edges { node { id } } }
              summary: drafts(accountId: "personal", first: 500) { totalCount } }
            """
            GatewayRuntimeURLProtocol.reset()
            let mixedDraftResult = GmailGatewayCLI(mode: .draftGateway).run(
                arguments: ["graphql", "--query", mixedDraftHydration],
                environment: fixture.environment
            )
            #expect(mixedDraftResult.exitCode == 2)
            #expect(mixedDraftResult.stdout.contains("\"RESOURCE_LIMIT\""))
            #expect(GatewayRuntimeURLProtocol.requests.isEmpty)

            let atBudget = """
            { threads(input: { accountId: "personal", first: 499 }) { edges { node { messages { id } } } }
              drafts(accountId: "personal", first: 499) { edges { node { id } } } }
            """
            GatewayRuntimeURLProtocol.reset()
            let accepted = GmailGatewayCLI(mode: .directSender).run(
                arguments: ["graphql", "--query", atBudget],
                environment: fixture.environment
            )
            #expect(accepted.exitCode == 0, "accepted at-budget query failed: \(accepted.stdout)")
            #expect(GatewayRuntimeURLProtocol.requests.count == 2)
            #expect(Set(GatewayRuntimeURLProtocol.urls.map(\.path)) == [
                "/gmail/v1/users/me/threads", "/gmail/v1/users/me/drafts"
            ])
        }

        @Test func providerAttemptBudgetRejectsRetryBeforeTheThirdHTTPAttempt() async throws {
            let fixture = try GatewayRuntimeFixture()
            defer { fixture.remove() }
            GatewayRuntimeURLProtocol.reset()
            GatewayRuntimeURLProtocol.responseStatusCodes = [500, 500, 200]
            URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
                GatewayRuntimeURLProtocol.reset()
            }

            let envelope = await GmailGatewayGraphQLExecutor(providerAttemptLimit: 2).run(
                query: "{ threads(input: { accountId: \"personal\" }) { totalCount } }",
                mode: .reader,
                environment: fixture.environment
            )

            #expect(envelope.exitCode == 1)
            #expect(envelope.errors.first?.code == "RESOURCE_LIMIT")
            #expect(GatewayRuntimeURLProtocol.requests.count == 2)
        }
    }
}

private extension GmailGatewayCLIMode {
    static let all: [Self] = [.reader, .draftGateway, .directSender, .mailboxThreads, .messageBox]
}

private func assertCapabilityOutcome(
    _ result: GmailGatewayCommandResult,
    invocation: RootInvocation,
    mode: GmailGatewayCLIMode,
    authorized: Bool,
    form: String
) throws {
    if !authorized {
        #expect(result.exitCode == 1, "\(invocation.name) \(form) must be denied by \(mode.gatewayTier)")
        #expect(result.stdout.contains("\"CAPABILITY_DENIED\""))
        #expect(result.stdout.contains("tier '\(mode.gatewayTier)'"))
        #expect(GatewayRuntimeURLProtocol.urls.isEmpty)
        #expect(GatewayRuntimeURLProtocol.methods.isEmpty)
        #expect(GatewayRuntimeURLProtocol.bodies.isEmpty)
        return
    }

    #expect(result.exitCode == 0, "\(invocation.name) \(form) must succeed in \(mode.gatewayTier): \(result.stdout)\(result.stderr)")
    try assertCompleteSuccessEnvelope(result, expectedData: invocation.expectedEnvelopeData)
    guard invocation.expectsNetwork else {
        #expect(GatewayRuntimeURLProtocol.urls.isEmpty)
        return
    }
    let actualEffects = GatewayRuntimeURLProtocol.requests.map { request in
        GatewayProviderEffect(url: request.url, method: request.method)
    }
    #expect(
        actualEffects == invocation.expectedEffects,
        "\(invocation.name) \(form) provider sequence must match exactly; got \(actualEffects)"
    )
    #expect(GatewayRuntimeURLProtocol.requests.count == invocation.expectedEffects.count)
    try assertCompleteProviderBodies(
        GatewayRuntimeURLProtocol.requests,
        finalBody: invocation.expectedBody
    )
}

struct GatewayProviderEffect: Equatable, CustomStringConvertible {
    let url: String
    let method: String

    var description: String { "\(method) \(url)" }
}

private func makeRFC822Source(in fixture: GatewayRuntimeFixture, required: Bool) throws -> String {
    guard required else { return "" }
    let directory = fixture.root.appendingPathComponent("send", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("message.eml")
    try Data("Subject: Runtime\r\n\r\nBody".utf8).write(to: source)
    return source.path
}

private func validationCode(
    from validator: GatewayGraphQLValidator,
    document: GatewayGraphQLDocument
) throws -> String {
    do {
        _ = try validator.validate(document)
        Issue.record("Expected validator failure")
        return ""
    } catch let GatewaySDKError.validation(code, _, _) {
        return code
    }
}

@discardableResult
private func assertValidatorFailure(
    _ result: GmailGatewayCommandResult,
    code: String,
    name: String
) -> GatewayEnvelope {
    #expect(result.exitCode == GmailGatewayExitCode.invalidCliUsage.rawValue, "\(name) must be an invalid-usage failure")
    #expect(result.stderr.isEmpty, "\(name) must serialize its GraphQL failure on stdout")
    let envelope = GatewayEnvelope(parsingCLIOutput: result.stdout, exitCode: result.exitCode)
    #expect(envelope.exitCode == GmailGatewayExitCode.invalidCliUsage.rawValue)
    #expect(envelope.data == nil)
    #expect(envelope.errors.map(\.code) == [code], "\(name) must emit exactly \(code)")
    #expect(envelope.requestId != nil, "\(name) must include a request ID")
    #expect(GatewayRuntimeURLProtocol.requests.isEmpty, "\(name) must not dispatch a provider request")
    #expect(GatewayRuntimeURLProtocol.urls.isEmpty, "\(name) must not capture a provider URL")
    #expect(GatewayRuntimeURLProtocol.methods.isEmpty, "\(name) must not capture a provider method")
    #expect(GatewayRuntimeURLProtocol.bodies.isEmpty, "\(name) must not capture a provider body")
    return envelope
}

struct RootInvocation {
    let name: String
    let mode: GmailGatewayCLIMode
    let accessMode: AccessMode
    let document: String
    let value: GatewayJSONValue
    let expectsNetwork: Bool
    let needsSource: Bool
    /// Test-owned GraphQL argument declarations.  These must not come from the
    /// production catalog: this matrix is intended to detect schema drift.
    let variableTypes: [String: String]

    var expectedEffects: [GatewayProviderEffect] {
        let provider = "https://gmail.googleapis.com"
        func effect(_ method: String, _ path: String, _ query: String = "") -> GatewayProviderEffect {
            GatewayProviderEffect(url: provider + path + query, method: method)
        }
        switch name {
        case "threads": return [effect("GET", expectedPath, "?maxResults=1&labelIds=INBOX")]
        case "thread", "message", "messageFileSet", "attachment", "draft":
            return [effect("GET", expectedPath, "?format=full")]
        case "drafts": return [effect("GET", expectedPath, "?maxResults=1")]
        case "createReplyDraft":
            return [effect("GET", "/gmail/v1/users/me/messages/message-id", "?format=full"), effect("POST", "/gmail/v1/users/me/drafts")]
        case "createForwardDraft":
            return [effect("GET", "/gmail/v1/users/me/messages/message-id", "?format=full"), effect("GET", "/gmail/v1/users/me/messages/message-id", "?format=full"), effect("POST", "/gmail/v1/users/me/drafts")]
        case "replyMessage":
            return [effect("GET", "/gmail/v1/users/me/messages/message-id", "?format=full"), effect("POST", "/gmail/v1/users/me/messages/send")]
        case "forwardMessage":
            return [effect("GET", "/gmail/v1/users/me/messages/message-id", "?format=full"), effect("GET", "/gmail/v1/users/me/messages/message-id", "?format=full"), effect("POST", "/gmail/v1/users/me/messages/send")]
        case "updateDraft":
            return [effect("GET", expectedPath, "?format=full"), effect("PUT", expectedPath)]
        case "importMessage", "insertMessage":
            return [effect(expectedMethod, expectedPath, "?internalDateSource=dateHeader")]
        default: return [effect(expectedMethod, expectedPath)]
        }
    }

    var expectedBody: [String: Any]? {
        switch name {
        case "createDraft": return ["message": ["raw": gatewayPlainMIME(to: "a@example.test", subject: nil, body: "x")]]
        case "createReplyDraft": return ["message": ["raw": gatewayReplyMIME(), "threadId": "thread-id"]]
        case "createForwardDraft": return ["message": ["raw": gatewayForwardMIME(), "threadId": "thread-id"]]
        case "updateDraft": return ["id": "draft-1", "message": ["raw": gatewayPlainMIME(to: "a@example.test", subject: "x", body: "x"), "threadId": "thread-id"]]
        case "sendDraft": return ["id": "draft-1"]
        case "modifyThreadLabels", "modifyMessageLabels": return ["addLabelIds": ["Label_1"]]
        case "batchModifyMessageLabels": return ["addLabelIds": ["Label_1"], "ids": ["message-id"]]
        case "batchDeleteMessages": return ["ids": ["message-id"]]
        case "createLabel", "updateLabel": return ["name": "Work"]
        case "trashThread", "untrashThread", "trashMessage", "untrashMessage": return nil
        case "importMessage", "insertMessage": return ["raw": "Subject: Runtime\r\n\r\nBody"]
        case "sendMessage": return ["raw": gatewayPlainMIME(to: "a@example.test", subject: nil, body: "x")]
        case "replyMessage": return ["raw": gatewayReplyMIME(), "threadId": "thread-id"]
        case "forwardMessage": return ["raw": gatewayForwardMIME(), "threadId": "thread-id"]
        default: return nil
        }
    }

    var expectedEnvelopeData: [String: Any] {
        [name: expectedResponseValue]
    }

    private var expectedResponseValue: Any {
        switch name {
        case "accounts": [["id": "personal"]]
        case "account": ["id": "personal"]
        case "threads", "drafts": ["totalCount": 0]
        case "thread": ["id": "thread-1"]
        case "message": ["id": "message-id"]
        case "messageFileSet": ["hasFiles": false]
        case "attachment": ["id": "attachment-id"]
        case "labels": [["id": "Label_1"]]
        case "profile": ["accountId": "personal"]
        case "draft": ["id": "draft-1"]
        default: ["status": expectedStatus]
        }
    }

    var expectedStatus: String {
        switch name {
        case "createDraft", "createReplyDraft", "createForwardDraft": return "DRAFT_CREATED"
        case "updateDraft": return "DRAFT_UPDATED"
        case "deleteDraft": return "DRAFT_DELETED"
        case "sendMessage", "replyMessage", "forwardMessage", "sendDraft": return "SENT"
        case "modifyThreadLabels", "modifyMessageLabels", "batchModifyMessageLabels": return "LABELS_MODIFIED"
        case "trashThread", "trashMessage": return "TRASHED"
        case "untrashThread", "untrashMessage": return "UNTRASHED"
        case "deleteThread", "deleteMessage", "batchDeleteMessages": return "PERMANENTLY_DELETED"
        case "createLabel": return "LABEL_CREATED"
        case "updateLabel": return "LABEL_UPDATED"
        case "deleteLabel": return "LABEL_DELETED"
        case "importMessage": return "MESSAGE_IMPORTED"
        case "insertMessage": return "MESSAGE_INSERTED"
        default: return "\"data\""
        }
    }

    func literal(sourcePath: String) -> String {
        document.replacingOccurrences(of: "SOURCE", with: sourcePath)
    }

    func variables(sourcePath: String) -> GatewayJSONValue {
        replaceSource(in: value, sourcePath: sourcePath)
    }

    func variableDocument(sourcePath: String) throws -> GatewayBuiltDocument {
        guard case .object(let values) = variables(sourcePath: sourcePath) else {
            throw GatewaySDKError.invalidJSON("matrix values must be an object")
        }
        let declarations = variableTypes.keys.sorted().map { name in
            "$\(name): \(variableTypes[name] ?? "")"
        }
        let arguments = variableTypes.keys.sorted().map { "\($0): $\($0)" }
        let operation = document.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("mutation") ? "mutation" : "query"
        let header = declarations.isEmpty ? "" : " Matrix(\(declarations.joined(separator: ", ")))"
        let call = arguments.isEmpty ? name : "\(name)(\(arguments.joined(separator: ", ")))"
        return GatewayBuiltDocument(
            document: "\(operation)\(header) { \(call) \(variableSelection) }",
            variables: values
        )
    }

    private var variableSelection: String {
        guard let opening = document.lastIndex(of: "{"),
              let closing = document[opening...].firstIndex(of: "}") else {
            return "{ status }"
        }
        return String(document[opening...closing])
    }

    var operationSelection: String {
        variableSelection
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .dropFirst()
            .dropLast()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var expectedPath: String {
        switch name {
        case "threads": "/gmail/v1/users/me/threads"
        case "thread": "/gmail/v1/users/me/threads/thread-1"
        case "message", "messageFileSet", "attachment": "/gmail/v1/users/me/messages/message-id"
        case "labels": "/gmail/v1/users/me/labels"
        case "profile": "/gmail/v1/users/me/profile"
        case "drafts", "createDraft": "/gmail/v1/users/me/drafts"
        case "createReplyDraft", "createForwardDraft", "replyMessage", "forwardMessage": "/gmail/v1/users/me/messages/message-id"
        case "draft", "updateDraft", "deleteDraft": "/gmail/v1/users/me/drafts/draft-1"
        case "sendMessage": "/gmail/v1/users/me/messages/send"
        case "sendDraft": "/gmail/v1/users/me/drafts/send"
        case "modifyThreadLabels": "/gmail/v1/users/me/threads/thread-1/modify"
        case "trashThread": "/gmail/v1/users/me/threads/thread-1/trash"
        case "untrashThread": "/gmail/v1/users/me/threads/thread-1/untrash"
        case "deleteThread": "/gmail/v1/users/me/threads/thread-1"
        case "modifyMessageLabels": "/gmail/v1/users/me/messages/message-id/modify"
        case "trashMessage": "/gmail/v1/users/me/messages/message-id/trash"
        case "untrashMessage": "/gmail/v1/users/me/messages/message-id/untrash"
        case "deleteMessage": "/gmail/v1/users/me/messages/message-id"
        case "batchModifyMessageLabels": "/gmail/v1/users/me/messages/batchModify"
        case "batchDeleteMessages": "/gmail/v1/users/me/messages/batchDelete"
        case "createLabel": "/gmail/v1/users/me/labels"
        case "updateLabel", "deleteLabel": "/gmail/v1/users/me/labels/Label_1"
        case "importMessage": "/gmail/v1/users/me/messages/import"
        case "insertMessage": "/gmail/v1/users/me/messages"
        default: ""
        }
    }

    var expectedMethod: String {
        switch name {
        case "threads", "thread", "message", "messageFileSet", "attachment", "labels", "profile", "drafts", "draft", "createReplyDraft", "createForwardDraft", "replyMessage", "forwardMessage": "GET"
        case "updateDraft": "PUT"
        case "updateLabel": "PATCH"
        case "deleteDraft", "deleteLabel", "deleteThread", "deleteMessage": "DELETE"
        default: "POST"
        }
    }

    static let all: [Self] = [
        root("accounts", .reader, .read, "{ accounts { id } }", [:], network: false),
        root("account", .reader, .read, "{ account(id: \"personal\") { id } }", ["id": .string("personal")], network: false),
        input("threads", .reader, .read, "ThreadSearchInput", "{ threads(input: { accountId: \"personal\", first: 1 }) { totalCount } }", ["accountId": .string("personal"), "first": .int(1)]),
        root("thread", .reader, .read, "{ thread(accountId: \"personal\", threadId: \"thread-1\") { id } }", ["accountId": .string("personal"), "threadId": .string("thread-1")]),
        root("message", .reader, .read, "{ message(accountId: \"personal\", messageId: \"message-id\") { id } }", ["accountId": .string("personal"), "messageId": .string("message-id")]),
        root("messageFileSet", .reader, .read, "{ messageFileSet(accountId: \"personal\", messageId: \"message-id\") { hasFiles } }", ["accountId": .string("personal"), "messageId": .string("message-id")]),
        root("attachment", .reader, .read, "{ attachment(accountId: \"personal\", messageId: \"message-id\", attachmentId: \"attachment-id\") { id } }", ["accountId": .string("personal"), "messageId": .string("message-id"), "attachmentId": .string("attachment-id")]),
        root("labels", .reader, .read, "{ labels(accountId: \"personal\") { id } }", ["accountId": .string("personal")]),
        root("profile", .reader, .read, "{ profile(accountId: \"personal\") { accountId } }", ["accountId": .string("personal")]),
        root("drafts", .draftGateway, .readSend, "{ drafts(accountId: \"personal\", first: 1) { totalCount } }", ["accountId": .string("personal"), "first": .int(1)]),
        root("draft", .draftGateway, .readSend, "{ draft(accountId: \"personal\", draftId: \"draft-1\") { id } }", ["accountId": .string("personal"), "draftId": .string("draft-1")]),
        input("createDraft", .draftGateway, .readSend, "SendMessageInput", "mutation { createDraft(input: { accountId: \"personal\", to: [\"a@example.test\"], textBody: \"x\" }) { status } }", mail()),
        input("createReplyDraft", .draftGateway, .readSend, "ReplyMessageInput", "mutation { createReplyDraft(input: { accountId: \"personal\", messageId: \"message-id\", textBody: \"x\" }) { status } }", reply()),
        input("createForwardDraft", .draftGateway, .readSend, "ForwardMessageInput", "mutation { createForwardDraft(input: { accountId: \"personal\", messageId: \"message-id\", to: [\"a@example.test\"] }) { status } }", forward()),
        input("updateDraft", .draftGateway, .readSend, "UpdateDraftInput", "mutation { updateDraft(input: { accountId: \"personal\", draftId: \"draft-1\", to: [\"a@example.test\"], subject: \"x\", textBody: \"x\" }) { status } }", ["accountId": .string("personal"), "draftId": .string("draft-1"), "to": .array([.string("a@example.test")]), "subject": .string("x"), "textBody": .string("x")]),
        input("deleteDraft", .draftGateway, .readSend, "DeleteDraftInput", "mutation { deleteDraft(input: { accountId: \"personal\", draftId: \"draft-1\" }) { status } }", ["accountId": .string("personal"), "draftId": .string("draft-1")]),
        input("sendMessage", .directSender, .readSend, "SendMessageInput", "mutation { sendMessage(input: { accountId: \"personal\", to: [\"a@example.test\"], textBody: \"x\" }) { status } }", mail()),
        input("replyMessage", .directSender, .readSend, "ReplyMessageInput", "mutation { replyMessage(input: { accountId: \"personal\", messageId: \"message-id\", textBody: \"x\" }) { status } }", reply()),
        input("forwardMessage", .directSender, .readSend, "ForwardMessageInput", "mutation { forwardMessage(input: { accountId: \"personal\", messageId: \"message-id\", to: [\"a@example.test\"] }) { status } }", forward()),
        input("sendDraft", .directSender, .readSend, "SendDraftInput", "mutation { sendDraft(input: { accountId: \"personal\", draftId: \"draft-1\" }) { status } }", ["accountId": .string("personal"), "draftId": .string("draft-1")]),
        input("modifyThreadLabels", .mailboxThreads, .readModify, "ModifyThreadLabelsInput", "mutation { modifyThreadLabels(input: { accountId: \"personal\", threadId: \"thread-1\", addLabelIds: [\"Label_1\"] }) { status } }", ["accountId": .string("personal"), "threadId": .string("thread-1"), "addLabelIds": .array([.string("Label_1")])]),
        input("modifyMessageLabels", .mailboxThreads, .readModify, "ModifyMessageLabelsInput", "mutation { modifyMessageLabels(input: { accountId: \"personal\", messageId: \"message-id\", addLabelIds: [\"Label_1\"] }) { status } }", ["accountId": .string("personal"), "messageId": .string("message-id"), "addLabelIds": .array([.string("Label_1")])]),
        input("batchModifyMessageLabels", .mailboxThreads, .readModify, "BatchModifyMessageLabelsInput", "mutation { batchModifyMessageLabels(input: { accountId: \"personal\", messageIds: [\"message-id\"], addLabelIds: [\"Label_1\"] }) { status } }", ["accountId": .string("personal"), "messageIds": .array([.string("message-id")]), "addLabelIds": .array([.string("Label_1")])]),
        input("trashThread", .mailboxThreads, .readModify, "ThreadMailboxActionInput", "mutation { trashThread(input: { accountId: \"personal\", threadId: \"thread-1\" }) { status } }", ["accountId": .string("personal"), "threadId": .string("thread-1")]),
        input("untrashThread", .mailboxThreads, .readModify, "ThreadMailboxActionInput", "mutation { untrashThread(input: { accountId: \"personal\", threadId: \"thread-1\" }) { status } }", ["accountId": .string("personal"), "threadId": .string("thread-1")]),
        input("trashMessage", .mailboxThreads, .readModify, "MessageMailboxActionInput", "mutation { trashMessage(input: { accountId: \"personal\", messageId: \"message-id\" }) { status } }", ["accountId": .string("personal"), "messageId": .string("message-id")]),
        input("untrashMessage", .mailboxThreads, .readModify, "MessageMailboxActionInput", "mutation { untrashMessage(input: { accountId: \"personal\", messageId: \"message-id\" }) { status } }", ["accountId": .string("personal"), "messageId": .string("message-id")]),
        input("deleteThread", .mailboxThreads, .full, "ThreadMailboxActionInput", "mutation { deleteThread(input: { accountId: \"personal\", threadId: \"thread-1\" }) { status } }", ["accountId": .string("personal"), "threadId": .string("thread-1")]),
        input("deleteMessage", .mailboxThreads, .full, "MessageMailboxActionInput", "mutation { deleteMessage(input: { accountId: \"personal\", messageId: \"message-id\" }) { status } }", ["accountId": .string("personal"), "messageId": .string("message-id")]),
        input("batchDeleteMessages", .mailboxThreads, .full, "BatchDeleteMessagesInput", "mutation { batchDeleteMessages(input: { accountId: \"personal\", messageIds: [\"message-id\"] }) { status } }", ["accountId": .string("personal"), "messageIds": .array([.string("message-id")])]),
        input("createLabel", .mailboxThreads, .readModify, "CreateLabelInput", "mutation { createLabel(input: { accountId: \"personal\", name: \"Work\" }) { status } }", ["accountId": .string("personal"), "name": .string("Work")]),
        input("updateLabel", .mailboxThreads, .readModify, "UpdateLabelInput", "mutation { updateLabel(input: { accountId: \"personal\", labelId: \"Label_1\", name: \"Work\" }) { status } }", ["accountId": .string("personal"), "labelId": .string("Label_1"), "name": .string("Work")]),
        input("deleteLabel", .mailboxThreads, .readModify, "DeleteLabelInput", "mutation { deleteLabel(input: { accountId: \"personal\", labelId: \"Label_1\" }) { status } }", ["accountId": .string("personal"), "labelId": .string("Label_1")]),
        ingest("importMessage"), ingest("insertMessage")
    ]

    private static func root(_ name: String, _ mode: GmailGatewayCLIMode, _ access: AccessMode, _ document: String, _ values: [String: GatewayJSONValue], network: Bool = true) -> Self {
        .init(name: name, mode: mode, accessMode: access, document: document, value: .object(values), expectsNetwork: network, needsSource: false, variableTypes: rootVariableTypes(for: name))
    }

    private static func input(_ name: String, _ mode: GmailGatewayCLIMode, _ access: AccessMode, _ inputType: String, _ document: String, _ values: [String: GatewayJSONValue]) -> Self {
        .init(name: name, mode: mode, accessMode: access, document: document, value: .object(["input": .object(values)]), expectsNetwork: true, needsSource: false, variableTypes: ["input": "\(inputType)!"])
    }

    private static func ingest(_ name: String) -> Self {
        .init(name: name, mode: .messageBox, accessMode: .readModify, document: "mutation { \(name)(input: { accountId: \"personal\", rfc822Path: \"SOURCE\", internalDateSource: DATE_HEADER }) { status } }", value: .object(["input": .object(["accountId": .string("personal"), "rfc822Path": .string("SOURCE"), "internalDateSource": .string("DATE_HEADER")])]), expectsNetwork: true, needsSource: true, variableTypes: ["input": "MailboxIngestInput!"])
    }

    private static func rootVariableTypes(for operation: String) -> [String: String] {
        switch operation {
        case "account": ["id": "ID!"]
        case "thread": ["accountId": "ID!", "threadId": "ID!"]
        case "message", "messageFileSet": ["accountId": "ID!", "messageId": "ID!"]
        case "attachment": ["accountId": "ID!", "messageId": "ID!", "attachmentId": "ID!"]
        case "labels", "profile": ["accountId": "ID!"]
        case "drafts": ["accountId": "ID!", "first": "Int"]
        case "draft": ["accountId": "ID!", "draftId": "ID!"]
        default: [:]
        }
    }
    private static func mail() -> [String: GatewayJSONValue] { ["accountId": .string("personal"), "to": .array([.string("a@example.test")]), "textBody": .string("x")] }
    private static func reply() -> [String: GatewayJSONValue] { ["accountId": .string("personal"), "messageId": .string("message-id"), "textBody": .string("x")] }
    private static func forward() -> [String: GatewayJSONValue] { ["accountId": .string("personal"), "messageId": .string("message-id"), "to": .array([.string("a@example.test")])] }
}

private func replaceSource(in value: GatewayJSONValue, sourcePath: String) -> GatewayJSONValue {
    switch value {
    case .string("SOURCE"): .string(sourcePath)
    case .array(let values): .array(values.map { replaceSource(in: $0, sourcePath: sourcePath) })
    case .object(let values): .object(values.mapValues { replaceSource(in: $0, sourcePath: sourcePath) })
    default: value
    }
}

// swiftlint:enable line_length large_tuple
