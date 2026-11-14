import Foundation
import GoogleServiceGatewayCore
@testable import GmailGatewayCore
import XCTest

final class PersistentAuthReadRegressionTests: XCTestCase {
    func testLoginProfileIsReadableWithDefaultConfigAndGraphQLVariables() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
                           "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
                           "XDG_DATA_HOME": root.appendingPathComponent("data").path]
        let config = try GmailGatewayConfigLoader.loadConfig(environment: environment)
        let client = testClient()
        let store = FileCredentialStore(productDirectory: "gmail-gateway", environment: environment)
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: nil))
        let coordinator = GmailAuthCoordinator(
            config: config, environment: environment, policy: .persistent(requiredAccessMode: .read), store: store,
            loginResult: { _, _ in
                GmailOAuthLoginResult(tokenStore: try coherentToken(client: client), redirectURI: "http://127.0.0.1:1/oauth2callback")
            }
        )
        _ = try await coordinator.login(credentialId: "gmail-personal", options: GmailOAuthLoginOptions(openBrowser: false))
        TestGmailRequestCaptureProtocol.reset()
        TestGmailRequestCaptureProtocol.messageGetResponseData = Data(#"{"id":"message-1","threadId":"thread-1","payload":{"headers":[]}}"#.utf8)
        TestGmailRequestCaptureProtocol.threadGetResponseData = Data(#"{"id":"thread-1","messages":[]}"#.utf8)
        TestGmailRequestCaptureProtocol.profileResponseData = Data(#"{"emailAddress":"person@example.com"}"#.utf8)
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }
        let cli = GmailGatewayCLI(mode: .reader, authPolicy: .persistent(requiredAccessMode: .read), secureCredentialStore: store)
        for arguments in [
            ["graphql", "--query", #"{ profile(accountId: "personal") { emailAddress } }"#],
            ["graphql", "--query", #"query($account: ID!) { profile(accountId: $account) { emailAddress } }"#,
             "--variables", #"{"account":"personal"}"#],
            ["graphql", "operation", "profile", "--variables", #"{"accountId":"personal"}"#]
        ] {
            let result = await cli.runPersistent(arguments: arguments, environment: environment)
            XCTAssertEqual(result.exitCode, 0, result.stdout + result.stderr)
            XCTAssertTrue(result.stdout.contains("person@example.com"), result.stdout + result.stderr)
        }
    }

    func testLookupOperationsUsePersistedVaultAndAuthenticatedFallbackIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
                           "XDG_DATA_HOME": root.appendingPathComponent("data").path]
        let client = testClient()
        TestGmailRequestCaptureProtocol.reset()
        TestGmailRequestCaptureProtocol.messageGetResponseData = Data(#"{"id":"message-1","threadId":"thread-1","payload":{"headers":[]}}"#.utf8)
        TestGmailRequestCaptureProtocol.threadGetResponseData = Data(#"{"id":"thread-1","messages":[]}"#.utf8)
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }
        for mode in [GmailGatewayCLIMode.reader, .directSender, .draftGateway, .mailboxThreads, .messageBox] {
            let accessMode = mode.synthesizedAccessMode
            let store = TestSecureCredentialStore()
            let config = try GmailGatewayConfigLoader.loadConfig(environment: environment, synthesizedAccessMode: accessMode)
            try await GmailCredentialVault(store: store).replaceProfile(GmailCredentialProfileEnvelope(
                schemaVersion: 1, provider: .gmail, credentialId: "gmail-personal", accessMode: accessMode,
                expectedScopes: gmailScopes(accessMode: accessMode).sorted(), client: client, token: nil
            ))
            let coordinator = GmailAuthCoordinator(
                config: config, environment: environment, policy: .persistent(requiredAccessMode: accessMode), store: store,
                loginResult: { _, _ in
                    let token = GmailOAuthTokenStore(
                        accessMode: accessMode, accessToken: "access", refreshToken: "refresh", tokenType: "Bearer",
                        scope: gmailScopes(accessMode: accessMode).joined(separator: " "), expiresAt: nil,
                        emailAddress: "person@example.com", clientFingerprint: try gmailOAuthClientFingerprint(client)
                    )
                    return GmailOAuthLoginResult(tokenStore: token, redirectURI: "http://127.0.0.1:1/oauth2callback")
                }
            )
            _ = try await coordinator.login(credentialId: "gmail-personal", options: GmailOAuthLoginOptions(openBrowser: false))
            let cli = GmailGatewayCLI(mode: mode, authPolicy: .persistent(requiredAccessMode: accessMode), secureCredentialStore: store)
            for (operation, variables, expected) in [
                ("message", #"{"accountId":"personal","messageId":"message-1"}"#, "message-1"),
                ("thread", #"{"accountId":"personal","threadId":"thread-1"}"#, "thread-1"),
                ("messageFileSet", #"{"accountId":"personal","messageId":"message-1"}"#, "message-1")
            ] {
                let result = await cli.runPersistent(arguments: ["graphql", "operation", operation, "--variables", variables], environment: environment)
                XCTAssertEqual(result.exitCode, 0, "\(mode): " + result.stdout + result.stderr)
                XCTAssertTrue(result.stdout.contains(expected), result.stdout)
            }
            let hydrated = try await coordinator.hydratedConfig()
            XCTAssertEqual(hydrated.accounts.first?.emailAddress, "person@example.com")
            XCTAssertEqual(hydrated.accounts.first?.isFallback, true)
            let result = await cli.runPersistent(arguments: ["graphql", "--query",
                #"{ account(id: "personal") { emailAddress } message(accountId: "personal", messageId: "message-1") { id } }"#
            ], environment: environment)
            XCTAssertEqual(result.exitCode, 0, result.stdout + result.stderr)
            XCTAssertTrue(result.stdout.contains("person@example.com"), result.stdout)
            XCTAssertFalse(result.stdout.contains("example.invalid"), result.stdout)
        }
    }

    func testTokenFileOverrideSupportsMessageThreadAndFileLookups() async throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = testClient()
        let token = GmailOAuthTokenStore(
            accessMode: .read, accessToken: "access", refreshToken: "refresh", tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "), expiresAt: nil,
            emailAddress: "person@example.com", clientFingerprint: try gmailOAuthClientFingerprint(client),
            schemaVersion: 1, provider: .gmail, credentialId: "gmail-personal"
        )
        let path = root.appendingPathComponent("token.json").path
        try JSONEncoder().encode(token).write(to: URL(fileURLWithPath: path))
        let environment = [
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "XDG_DATA_HOME": root.appendingPathComponent("data").path,
            "GMAIL_GATEWAY_OAUTH_CLIENT_JSON": try client.legacyJSON(),
            "GMAIL_GATEWAY_TOKEN_STORE_PATH": path
        ]
        let config = try GmailGatewayConfigLoader.loadConfig(environment: environment)
        let directory = URL(fileURLWithPath: config.storage.attachmentDir)
            .appendingPathComponent("personal/message-1")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("body".utf8).write(to: directory.appendingPathComponent("body.txt"))
        TestGmailRequestCaptureProtocol.reset()
        TestGmailRequestCaptureProtocol.messageGetResponseData = Data(#"{"id":"message-1","threadId":"thread-1","payload":{"headers":[]}}"#.utf8)
        TestGmailRequestCaptureProtocol.threadGetResponseData = Data(#"{"id":"thread-1","messages":[]}"#.utf8)
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }
        let cli = GmailGatewayCLI(mode: .reader, authPolicy: .persistent(requiredAccessMode: .read), secureCredentialStore: TestSecureCredentialStore())
        for (operation, variables, expected) in [
            ("message", #"{"accountId":"personal","messageId":"message-1"}"#, "message-1"),
            ("thread", #"{"accountId":"personal","threadId":"thread-1"}"#, "thread-1"),
            ("messageFileSet", #"{"accountId":"personal","messageId":"message-1"}"#, "body.txt")
        ] {
            let result = await cli.runPersistent(arguments: ["graphql", "operation", operation, "--variables", variables], environment: environment)
            XCTAssertEqual(result.exitCode, 0, result.stdout + result.stderr)
            XCTAssertTrue(result.stdout.contains(expected), result.stdout)
        }
        let account = await cli.runPersistent(arguments: ["graphql", "--query",
            #"{ account(id: "personal") { emailAddress } }"#
        ], environment: environment)
        XCTAssertEqual(account.exitCode, 0, account.stdout + account.stderr)
        XCTAssertTrue(account.stdout.contains("person@example.com"), account.stdout)
    }

    #if os(macOS)
    func testSystemTemporaryAliasSupportsTokenReadWriteAndRemoval() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("token.json").path
        let token = try coherentToken(client: testClient())
        let credential = persistentConfig(tokenPath: path, fallback: true).credentials[0]
        try writeGmailOAuthTokenStore(token, to: path, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
        let read = try XCTUnwrap(readPersistentTokenFileData(path, credential: credential, exitCode: .graphqlExecutionError))
        XCTAssertEqual(try JSONDecoder().decode(GmailOAuthTokenStore.self, from: read.data).accessToken, token.accessToken)
        try removePersistentTokenFile(at: path, expectedState: .identity(read.identity), credential: credential, exitCode: .authenticationBootstrapError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
    #endif
}
