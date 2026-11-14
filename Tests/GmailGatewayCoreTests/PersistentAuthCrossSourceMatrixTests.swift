import Foundation
@testable import GmailGatewayCore
import XCTest

final class PersistentAuthCrossSourceMatrixTests: XCTestCase {
    func testEveryAcceptedSourcePairResolvesThroughTheReaderCLI() async throws {
        TestGmailRequestCaptureProtocol.reset()
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }

        for sourceCase in CLIPersistentAuthSourcePair.allCombinations {
            let fixture = try await CLIPersistentAuthSourceFixture.make(sourceCase: sourceCase)
            defer { fixture.remove() }
            TestGmailRequestCaptureProtocol.reset()
            TestGmailRequestCaptureProtocol.profileResponseData = Data(#"{"emailAddress":"person@example.invalid"}"#.utf8)

            let result = await fixture.cli.runPersistent(
                arguments: fixture.profileArguments,
                environment: fixture.environment
            )

            XCTAssertEqual(result.exitCode, GmailGatewayExitCode.success.rawValue, sourceCase.name)
            XCTAssertTrue(result.stdout.contains("person@example.invalid"), sourceCase.name)
            XCTAssertEqual(TestGmailRequestCaptureProtocol.capturedURLs.map(\.host), ["gmail.googleapis.com"], sourceCase.name)
        }
    }

    func testEverySelectedMismatchFailsThroughTheReaderCLIBeforeTransport() async throws {
        TestGmailRequestCaptureProtocol.reset()
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }

        for sourceCase in CLIPersistentAuthSourcePair.allCombinations {
            let fixture = try await CLIPersistentAuthSourceFixture.make(
                sourceCase: sourceCase,
                selectedTokenFingerprint: "mismatched-client",
                seedLowerPriorityVaultToken: sourceCase.token.hasLowerPriorityVaultFallback
            )
            defer { fixture.remove() }
            TestGmailRequestCaptureProtocol.reset()
            let writesBefore = await fixture.store.dataWriteCount()

            let result = await fixture.cli.runPersistent(
                arguments: fixture.profileArguments,
                environment: fixture.environment
            )

            try assertCLIGraphQLError(result, expectedCode: .authRequired, context: sourceCase.name)
            let writesAfter = await fixture.store.dataWriteCount()
            XCTAssertEqual(writesAfter, writesBefore, sourceCase.name)
            XCTAssertTrue(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty, sourceCase.name)
        }
    }

    func testInvalidExplicitClientDoesNotFallThroughToVaultThroughTheCLI() async throws {
        let fixture = try await CLIPersistentAuthSourceFixture.make(
            sourceCase: .init(name: "invalid environment client JSON", client: .environmentJSON, token: .vault),
            selectedClientJSON: "not-json"
        )
        defer { fixture.remove() }
        let writesBefore = await fixture.store.dataWriteCount()

        let result = await fixture.cli.runPersistent(
            arguments: fixture.profileArguments,
            environment: fixture.environment
        )

        try assertCLIGraphQLError(result, expectedCode: .configInvalid, context: "invalid explicit client")
        let writesAfter = await fixture.store.dataWriteCount()
        XCTAssertEqual(writesAfter, writesBefore)
    }
}

private struct CLIPersistentAuthSourcePair {
    let name: String
    let client: CLIPersistentAuthSourceLocation
    let token: CLIPersistentAuthSourceLocation

    static let allCombinations = CLIPersistentAuthSourceLocation.clientLocations.flatMap { client in
        CLIPersistentAuthSourceLocation.tokenLocations.map { token in
            CLIPersistentAuthSourcePair(
                name: "\(client.label) client with \(token.label) token",
                client: client,
                token: token
            )
        }
    }
}

private enum CLIPersistentAuthSourceLocation: Equatable {
    case environmentJSON
    case environmentPath
    case configuredPath
    case relocatedPath
    case vault
    case synthesizedFile

    static let clientLocations: [CLIPersistentAuthSourceLocation] = [
        .environmentJSON, .environmentPath, .configuredPath, .vault, .synthesizedFile
    ]
    static let tokenLocations: [CLIPersistentAuthSourceLocation] = [
        .environmentJSON, .environmentPath, .configuredPath, .relocatedPath, .vault, .synthesizedFile
    ]

    var label: String {
        switch self {
        case .environmentJSON: "environment JSON"
        case .environmentPath: "environment path"
        case .configuredPath: "configured path"
        case .relocatedPath: "relocated path"
        case .vault: "vault"
        case .synthesizedFile: "synthesized path"
        }
    }

    var hasLowerPriorityVaultFallback: Bool {
        switch self {
        case .environmentJSON, .environmentPath, .configuredPath, .relocatedPath: true
        case .vault, .synthesizedFile: false
        }
    }
}

private struct CLIPersistentAuthSourceFixture {
    let root: URL
    let environment: [String: String]
    let store: TestSecureCredentialStore
    let cli: GmailGatewayCLI
    let profileArguments: [String]

    static func make(
        sourceCase: CLIPersistentAuthSourcePair,
        selectedTokenFingerprint: String? = nil,
        seedLowerPriorityVaultToken: Bool = false,
        selectedClientJSON: String? = nil
    ) async throws -> CLIPersistentAuthSourceFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let client = testClient()
        let fingerprint = try gmailOAuthClientFingerprint(client)
        let token = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "matrix-access-token",
            refreshToken: "matrix-refresh-token",
            tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "),
            expiresAt: nil,
            emailAddress: "person@example.invalid",
            clientFingerprint: selectedTokenFingerprint ?? fingerprint,
            schemaVersion: 1,
            provider: .gmail,
            credentialId: "gmail-personal"
        )
        let clientPath = root.appendingPathComponent("client.json")
        let tokenPath = root.appendingPathComponent("token.json")
        let relocatedDirectory = root.appendingPathComponent("relocated", isDirectory: true)
        let xdgState = root.appendingPathComponent("state", isDirectory: true)
        let synthesizedTokenPath = URL(fileURLWithPath: GmailGatewayConfigLoader.resolveDefaultCredentialDirectory(
            environment: ["XDG_STATE_HOME": xdgState.path]
        )).appendingPathComponent("gmail-personal.json")
        try client.legacyJSON().write(to: clientPath, atomically: true, encoding: .utf8)
        try client.legacyJSON().write(
            to: root.appendingPathComponent("google-client.json"),
            atomically: true,
            encoding: .utf8
        )

        var environment = ["XDG_STATE_HOME": xdgState.path]
        let clientJSONName = GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
            credentialId: "gmail-personal", valueKey: "oauth_client_secret_json"
        )
        let clientPathName = GmailGatewayConfigLoader.getCredentialPathEnvVarName(
            credentialId: "gmail-personal", pathKey: "oauth_client_secret_path"
        )
        let tokenJSONName = GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
            credentialId: "gmail-personal", valueKey: "token_store_json"
        )
        let tokenPathName = GmailGatewayConfigLoader.getCredentialPathEnvVarName(
            credentialId: "gmail-personal", pathKey: "token_store_path"
        )
        if sourceCase.client == .environmentJSON {
            environment[clientJSONName] = try selectedClientJSON ?? client.legacyJSON()
        }
        if sourceCase.client == .environmentPath {
            environment[clientPathName] = clientPath.path
        }
        if sourceCase.token == .environmentJSON {
            environment[tokenJSONName] = try cliTokenJSON(token)
        }
        if sourceCase.token == .environmentPath {
            try JSONEncoder().encode(token).write(to: tokenPath)
            environment[tokenPathName] = tokenPath.path
        }
        if sourceCase.token == .relocatedPath {
            try FileManager.default.createDirectory(at: relocatedDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(token).write(to: relocatedDirectory.appendingPathComponent("gmail-personal.json"))
            environment["GMAIL_GATEWAY_CREDENTIAL_DIR"] = relocatedDirectory.path
        }
        if sourceCase.token == .synthesizedFile {
            try FileManager.default.createDirectory(at: synthesizedTokenPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(token).write(to: synthesizedTokenPath)
        }

        let config = root.appendingPathComponent("config.toml")
        let configuredClient = sourceCase.client == .configuredPath ? "oauth_client_secret_path = \"client.json\"\n" : ""
        let configuredToken: String
        if sourceCase.token == .configuredPath {
            try JSONEncoder().encode(token).write(to: tokenPath)
            configuredToken = "token_store_path = \"token.json\"\n"
        } else {
            configuredToken = ""
        }
        try """
        [storage]
        cache_dir = "cache"
        attachment_dir = "attachments"
        allowed_send_attachment_roots = ["send"]

        [[credentials]]
        id = "gmail-personal"
        provider = "gmail"
        access_mode = "read"
        \(configuredClient)\(configuredToken)
        [[accounts]]
        id = "personal"
        provider = "gmail"
        email_address = "person@example.invalid"
        credential_id = "gmail-personal"
        default_label_ids = ["INBOX"]
        """.write(to: config, atomically: true, encoding: .utf8)

        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        if sourceCase.client == .vault || sourceCase.token == .vault || seedLowerPriorityVaultToken {
            let vaultToken: GmailOAuthTokenStore?
            if sourceCase.token == .vault {
                vaultToken = token
            } else if seedLowerPriorityVaultToken {
                vaultToken = try coherentToken(client: client)
            } else {
                vaultToken = nil
            }
            if sourceCase.token == .vault, selectedTokenFingerprint != nil {
                await store.put(
                    try JSONEncoder().encode(testProfile(client: client, token: token)),
                    account: "gmail-profile:gmail-personal:read"
                )
            } else {
                try await vault.replaceProfile(testProfile(client: client, token: vaultToken))
            }
        }
        return CLIPersistentAuthSourceFixture(
            root: root,
            environment: environment,
            store: store,
            cli: GmailGatewayCLI(
                mode: .reader,
                authPolicy: .persistent(requiredAccessMode: .read),
                secureCredentialStore: store
            ),
            profileArguments: [
                "--config", config.path, "graphql", "--query",
                #"{ profile(accountId: "personal") { emailAddress } }"#
            ]
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func cliTokenJSON(_ token: GmailOAuthTokenStore) throws -> String {
    try XCTUnwrap(String(data: JSONEncoder().encode(token), encoding: .utf8))
}

private func assertCLIGraphQLError(
    _ result: GmailGatewayCommandResult,
    expectedCode: GmailGatewayErrorCode,
    context: String
) throws {
    XCTAssertEqual(result.exitCode, GmailGatewayExitCode.graphqlExecutionError.rawValue, context)
    XCTAssertEqual(result.stderr, "", context)
    let body = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
        context
    )
    let errors = try XCTUnwrap(body["errors"] as? [[String: Any]], context)
    XCTAssertEqual(errors.first?["code"] as? String, expectedCode.rawValue, context)
}
