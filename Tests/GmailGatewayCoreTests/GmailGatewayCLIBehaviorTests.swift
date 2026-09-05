import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GmailGatewayCore

private actor SerialCLIInvocation {
    func run(environment: [String: String]) -> GmailGatewayCommandResult {
        GmailGatewayCLI(mode: .reader).run(
            arguments: ["graphql", "query", "--query", "{ accounts { id } }"],
            environment: environment
        )
    }
}

private struct GraphQLMalformedInvocationCase {
    let mode: GmailGatewayCLIMode
    let arguments: [String]
    let unreadPath: String?
}

extension GmailRequestProtocolTests {
@Suite(.serialized) struct GmailGatewayCLIBehaviorTests {
@Test func graphQLCatalogInputFailuresUseOperationEnvelopesWithoutProviderDispatch() throws {
    for limit in ["nope", "0", "-1"] {
        let result = GmailGatewayCLI().run(
            arguments: ["graphql", "search", "threads", "--limit", limit],
            environment: [:]
        )
        #expect(result.exitCode == GmailGatewayExitCode.invalidCliUsage.rawValue)
        #expect(result.stderr.contains("--limit must be a positive integer"))
    }

    let fixture = try GatewayRuntimeFixture()
    defer { fixture.remove() }
    GatewayRuntimeURLProtocol.reset()
    URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
    defer {
        URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
        GatewayRuntimeURLProtocol.reset()
    }
    let cases: [(arguments: [String], code: String)] = [
        (["graphql", "operation", "threads"], "MISSING_VARIABLE"),
        (["graphql", "operation", "doesNotExist"], "UNKNOWN_OPERATION"),
        (["graphql", "operation", "accounts", "--select", "notAField"], "INVALID_SELECTION"),
        (["graphql", "search", "["], "INVALID_PATTERN")
    ]
    for entry in cases {
        GatewayRuntimeURLProtocol.reset()
        let result = GmailGatewayCLI(mode: .reader).run(
            arguments: entry.arguments,
            environment: fixture.environment
        )
        #expect(result.exitCode == GmailGatewayExitCode.invalidCliUsage.rawValue)
        #expect(result.stderr.isEmpty)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(Set(payload.keys) == Set(["data", "errors", "extensions"]))
        #expect(payload["data"] is NSNull)
        let extensions = try #require(payload["extensions"] as? [String: Any])
        #expect(Set(extensions.keys) == Set(["requestId"]))
        #expect(UUID(uuidString: try #require(extensions["requestId"] as? String)) != nil)
        let errors = try #require(payload["errors"] as? [[String: Any]])
        #expect(errors.count == 1)
        let error = try #require(errors.first)
        #expect(Set(error.keys) == Set(["code", "message"]))
        #expect(error["code"] as? String == entry.code)
        #expect(GatewayRuntimeURLProtocol.requests.isEmpty)
    }
}

@Test func graphQLSearchRejectsLimitWithoutAValue() {
    let result = GmailGatewayCLI().run(
        arguments: ["graphql", "search", "threads", "--limit"],
        environment: [:]
    )
    #expect(result.exitCode == GmailGatewayExitCode.invalidCliUsage.rawValue)
}

@Test func graphQLRejectsMalformedInvocationBeforeAnyDestructiveOperationDispatch() throws {
    let fixture = try GatewayRuntimeFixture(accessMode: .full)
    defer { fixture.remove() }
    GatewayRuntimeURLProtocol.reset()
    URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
    defer {
        URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
        GatewayRuntimeURLProtocol.reset()
    }

    let destructiveOperations: [(operation: String, mode: GmailGatewayCLIMode)] = [
        ("deleteDraft", .draftGateway),
        ("trashThread", .mailboxThreads),
        ("trashMessage", .mailboxThreads),
        ("deleteThread", .mailboxThreads),
        ("deleteMessage", .mailboxThreads),
        ("batchDeleteMessages", .mailboxThreads),
        ("deleteLabel", .mailboxThreads)
    ]
    let malformedArguments: (String) -> [[String]] = { operation in
        [
            ["graphql", "operation", operation, "unexpected"],
            ["graphql", "operation", operation, "--bogus"],
            ["graphql", "operation", operation, "--query", "{ accounts { id } }"],
            ["graphql", "operation", operation, "--variables", "{}", "--variables", "{}"]
        ]
    }
    for entry in destructiveOperations {
        for arguments in malformedArguments(entry.operation) {
            GatewayRuntimeURLProtocol.reset()
            let result = GmailGatewayCLI(mode: entry.mode).run(
                arguments: arguments,
                environment: fixture.environment
            )
            #expect(result.exitCode == GmailGatewayExitCode.invalidCliUsage.rawValue)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains(GmailGatewayErrorCode.invalidArgument.rawValue))
            #expect(GatewayRuntimeURLProtocol.requests.isEmpty)
        }
    }

    let schema = GmailGatewayCLI(mode: .reader).run(
        arguments: ["graphql", "schema", "unexpected", "--bogus"],
        environment: fixture.environment
    )
    #expect(schema.exitCode == GmailGatewayExitCode.invalidCliUsage.rawValue)
    #expect(schema.stdout.isEmpty)
}

@Test func graphQLRejectsMalformedInvocationAcrossEveryFormBeforeFilesOrEffects() throws {
    let fixture = try GatewayRuntimeFixture(accessMode: .full)
    defer { fixture.remove() }
    GatewayRuntimeURLProtocol.reset()
    URLProtocol.registerClass(GatewayRuntimeURLProtocol.self)
    defer {
        URLProtocol.unregisterClass(GatewayRuntimeURLProtocol.self)
        GatewayRuntimeURLProtocol.reset()
    }

    let destructiveDocument = "mutation { deleteDraft(input: { accountId: \"personal\", id: \"draft-1\" }) { id } }"
    let missingQueryFile = fixture.root.appendingPathComponent("must-not-read.graphql").path
    let missingVariablesFile = fixture.root.appendingPathComponent("must-not-read.json").path
    let cases: [GraphQLMalformedInvocationCase] = [
        .init(mode: .draftGateway, arguments: ["graphql", "--query", destructiveDocument, "unexpected"], unreadPath: nil),
        .init(mode: .draftGateway, arguments: ["graphql", "query", "unexpected", "--query", destructiveDocument], unreadPath: nil),
        .init(mode: .reader, arguments: ["graphql", "schema", "unexpected"], unreadPath: nil),
        .init(mode: .reader, arguments: ["graphql", "search", "MailAccount", "unexpected"], unreadPath: nil),
        .init(mode: .draftGateway, arguments: ["graphql", "operation", "deleteDraft", "unexpected"], unreadPath: nil),
        .init(mode: .draftGateway, arguments: ["graphql", "--query", destructiveDocument, "--select", "id"], unreadPath: nil),
        .init(mode: .draftGateway, arguments: ["graphql", "query", "--query", destructiveDocument, "--limit", "1"], unreadPath: nil),
        .init(mode: .reader, arguments: ["graphql", "schema", "--query", destructiveDocument], unreadPath: nil),
        .init(mode: .reader, arguments: ["graphql", "search", "MailAccount", "--variables", "{}"], unreadPath: nil),
        .init(mode: .draftGateway, arguments: ["graphql", "operation", "deleteDraft", "--query", destructiveDocument], unreadPath: nil),
        .init(mode: .draftGateway, arguments: ["graphql", "--query", destructiveDocument, "--query", destructiveDocument], unreadPath: nil),
        .init(mode: .draftGateway, arguments: ["graphql", "query", "--query", destructiveDocument, "--query", destructiveDocument], unreadPath: nil),
        .init(mode: .reader, arguments: ["graphql", "schema", "--pretty", "--pretty"], unreadPath: nil),
        .init(mode: .reader, arguments: ["graphql", "search", "MailAccount", "--limit", "1", "--limit", "2"], unreadPath: nil),
        .init(mode: .draftGateway, arguments: ["graphql", "operation", "deleteDraft", "--select", "id", "--select", "id"], unreadPath: nil),
        .init(mode: .draftGateway, arguments: ["graphql", "--query-file", missingQueryFile, "--select", "id"], unreadPath: missingQueryFile),
        .init(mode: .draftGateway, arguments: ["graphql", "query", "--query-file", missingQueryFile, "--limit", "1"], unreadPath: missingQueryFile),
        .init(mode: .reader, arguments: ["graphql", "schema", "--query-file", missingQueryFile], unreadPath: missingQueryFile),
        .init(mode: .reader, arguments: ["graphql", "search", "MailAccount", "--variables-file", missingVariablesFile], unreadPath: missingVariablesFile),
        .init(mode: .draftGateway, arguments: ["graphql", "operation", "deleteDraft", "--variables-file", missingVariablesFile, "--query", destructiveDocument], unreadPath: missingVariablesFile)
    ]

    for entry in cases {
        GatewayRuntimeURLProtocol.reset()
        let result = GmailGatewayCLI(mode: entry.mode).run(
            arguments: entry.arguments,
            environment: fixture.environment
        )
        #expect(result.exitCode == GmailGatewayExitCode.invalidCliUsage.rawValue)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains(GmailGatewayErrorCode.invalidArgument.rawValue))
        if let unreadPath = entry.unreadPath {
            #expect(!result.stderr.contains(unreadPath))
        }
        #expect(GatewayRuntimeURLProtocol.requests.isEmpty)
    }

    let missingFileCases: [(arguments: [String], message: String)] = [
        (["graphql", "--query-file", missingQueryFile], "Failed to read GraphQL query file"),
        (["graphql", "query", "--query-file", missingQueryFile], "Failed to read GraphQL query file"),
        (["graphql", "operation", "accounts", "--variables-file", missingVariablesFile], "Failed to read JSON variables file")
    ]
    for entry in missingFileCases {
        GatewayRuntimeURLProtocol.reset()
        let result = GmailGatewayCLI(mode: .reader).run(
            arguments: entry.arguments,
            environment: fixture.environment
        )
        #expect(result.exitCode == GmailGatewayExitCode.invalidCliUsage.rawValue)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains(entry.message))
        #expect(GatewayRuntimeURLProtocol.requests.isEmpty)
    }
}

@Test func graphQLVariablesFileAndInlineValueAreMutuallyExclusive() throws {
    let fixture = try GatewayRuntimeFixture()
    defer { fixture.remove() }
    let variablesURL = fixture.root.appendingPathComponent("variables.json")
    try Data(#"{"id":"personal"}"#.utf8).write(to: variablesURL)

    let result = GmailGatewayCLI().run(
        arguments: [
            "graphql", "--config", fixture.configPath,
            "--query", "query Account($id: ID!) { account(id: $id) { id } }",
            "--variables", #"{"id":"personal"}"#,
            "--variables-file", variablesURL.path
        ],
        environment: fixture.environment
    )
    #expect(result.exitCode == GmailGatewayExitCode.invalidCliUsage.rawValue)
    #expect(result.stderr.contains("Use only one of --variables or --variables-file"))
}

@Test func graphQLConfigFlagOverridesConflictingEnvironmentPath() throws {
    let fixture = try GatewayRuntimeFixture()
    defer { fixture.remove() }
    let environmentConfig = fixture.root.appendingPathComponent("environment.toml")
    let source = try String(contentsOfFile: fixture.configPath, encoding: .utf8)
    try Data(source.replacingOccurrences(of: "id = \"personal\"", with: "id = \"environment\"").utf8)
        .write(to: environmentConfig)
    var environment = fixture.environment
    environment["GMAIL_GATEWAY_CONFIG"] = environmentConfig.path
    let result = GmailGatewayCLI(mode: .reader).run(
        arguments: [
            "--config", fixture.configPath,
            "graphql", "--query", "{ account(id: \"personal\") { id } }"
        ],
        environment: environment
    )

    #expect(result.exitCode == 0)
    try assertCompleteSuccessEnvelope(result, expectedData: ["account": ["id": "personal"]])
}

@Test func graphQLVariablesRequireJSONObjectsForInlineAndFileForms() throws {
    let fixture = try GatewayRuntimeFixture()
    defer { fixture.remove() }
    let variablesURL = fixture.root.appendingPathComponent("variables.json")
    try Data("[]".utf8).write(to: variablesURL)

    for variables in ["{", "[]", "null"] {
        let result = GmailGatewayCLI().run(
            arguments: ["graphql", "--query", "{ accounts { id } }", "--variables", variables],
            environment: fixture.environment
        )
        #expect(result.exitCode == GmailGatewayExitCode.invalidCliUsage.rawValue)
        #expect(result.stderr.contains("variables"))
    }
    let fileResult = GmailGatewayCLI().run(
        arguments: ["graphql", "--query", "{ accounts { id } }", "--variables-file", variablesURL.path],
        environment: fixture.environment
    )
    #expect(fileResult.exitCode == GmailGatewayExitCode.invalidCliUsage.rawValue)
    #expect(fileResult.stderr.contains("variables"))
}

@Test func rawAndOperationPathsKeepVariablesAndPrettyEnvelopeBehaviorSeparate() throws {
    let fixture = try GatewayRuntimeFixture()
    defer { fixture.remove() }
    let cli = GmailGatewayCLI(mode: .reader)
    let raw = cli.run(
        arguments: ["graphql", "--query", "{ accounts { id } }", "--variables", "{}", "--pretty"],
        environment: fixture.environment
    )
    let operation = cli.run(
        arguments: ["graphql", "operation", "accounts", "--variables", "{}", "--pretty"],
        environment: fixture.environment
    )
    #expect(raw.exitCode == 0)
    #expect(operation.exitCode == 0)
    #expect(raw.stdout.contains("\n  \"data\""))
    #expect(operation.stdout.contains("\n  \"data\""))
}

@Test func graphQLCLIFormsAndCatalogOptionsWorkInEveryMode() throws {
    let fixture = try GatewayRuntimeFixture(accessMode: .full)
    defer { fixture.remove() }
    let variablesURL = fixture.root.appendingPathComponent("account-variables.json")
    try Data(#"{"id":"personal"}"#.utf8).write(to: variablesURL)

    for mode in [
        GmailGatewayCLIMode.reader, .draftGateway, .directSender, .mailboxThreads, .messageBox
    ] {
        let cli = GmailGatewayCLI(mode: mode)
        let explicitQuery = cli.run(
            arguments: [
                "graphql", "query", "--query", "query Account($id: ID!) { account(id: $id) { id } }",
                "--variables-file", variablesURL.path
            ],
            environment: fixture.environment
        )
        let operation = cli.run(
            arguments: [
                "graphql", "operation", "account", "--variables-file", variablesURL.path,
                "--select", "id"
            ],
            environment: fixture.environment
        )
        let schema = cli.run(arguments: ["graphql", "schema"], environment: [:])
        let search = cli.run(
            arguments: [
                "graphql", "search", "MailAccount", "--kinds", "object",
                "--include-referenced-types", "--limit", "10"
            ],
            environment: [:]
        )

        #expect(explicitQuery.exitCode == 0, "(mode.gatewayTier): \(explicitQuery.stderr)")
        #expect(operation.exitCode == 0, "(mode.gatewayTier): \(operation.stderr)")
        try assertCompleteSuccessEnvelope(explicitQuery, expectedData: ["account": ["id": "personal"]])
        try assertCompleteSuccessEnvelope(operation, expectedData: ["account": ["id": "personal"]])
        #expect(schema.exitCode == 0)
        #expect(schema.stdout.contains("type Query"))
        #expect(search.exitCode == 0)
        #expect(search.stdout.contains("MailAccount"))
    }
}

@Test func graphQLCLISynchronousBridgeCompletesFromSerialAndConcurrentCallers() async throws {
    let fixture = try GatewayRuntimeFixture()
    defer { fixture.remove() }
    let serial = SerialCLIInvocation()
    let serialResult = await serial.run(environment: fixture.environment)
    #expect(serialResult.exitCode == 0)

    let results = await withTaskGroup(of: GmailGatewayCommandResult.self, returning: [GmailGatewayCommandResult].self) { group in
        for _ in 0..<8 {
            group.addTask {
                GmailGatewayCLI(mode: .reader).run(
                    arguments: ["graphql", "query", "--query", "{ accounts { id } }"],
                    environment: fixture.environment
                )
            }
        }
        var collected: [GmailGatewayCommandResult] = []
        for await result in group {
            collected.append(result)
        }
        return collected
    }
    #expect(results.count == 8)
    #expect(results.allSatisfy { $0.exitCode == 0 })
}
}
}
