@testable import GmailGatewayCore
import XCTest

final class PersistentAuthCoherenceTests: XCTestCase {
    func testStoredScopeAndAccessModeMismatchesReportScopeMismatchBeforeProviderOrLoginActivity() async throws {
        let cases: [(name: String, token: GmailOAuthTokenStore)] = [
            (
                "scope",
                GmailOAuthTokenStore(
                    accessMode: .read,
                    accessToken: "scope-mismatch-access-token",
                    refreshToken: "scope-mismatch-refresh-token",
                    tokenType: "Bearer",
                    scope: "https://www.googleapis.com/auth/gmail.readonly https://example.invalid/extra",
                    expiresAt: nil,
                    emailAddress: nil,
                    clientFingerprint: try gmailOAuthClientFingerprint(testClient()),
                    schemaVersion: 1,
                    provider: .gmail,
                    credentialId: "gmail-personal"
                )
            ),
            (
                "access mode",
                GmailOAuthTokenStore(
                    accessMode: .readSend,
                    accessToken: "mode-mismatch-access-token",
                    refreshToken: "mode-mismatch-refresh-token",
                    tokenType: "Bearer",
                    scope: gmailScopes(accessMode: .readSend).joined(separator: " "),
                    expiresAt: nil,
                    emailAddress: nil,
                    clientFingerprint: try gmailOAuthClientFingerprint(testClient()),
                    schemaVersion: 1,
                    provider: .gmail,
                    credentialId: "gmail-personal"
                )
            )
        ]
        TestGmailRequestCaptureProtocol.reset()
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }

        for testCase in cases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let tokenPath = root.appendingPathComponent("token.json").path
            try JSONEncoder().encode(testCase.token).write(to: URL(fileURLWithPath: tokenPath))
            let cliConfigURL = try writePersistentConfiguredCredentialConfig(
                at: root,
                client: testClient()
            )
            let config = try persistentConfiguredTokenPathConfig(tokenPath: tokenPath)
            let store = TestSecureCredentialStore()
            let loginResult = PersistentAuthLoginResultSpy()
            let coordinator = GmailAuthCoordinator(
                config: config,
                environment: [:],
                policy: .persistent(requiredAccessMode: .read),
                store: store,
                loginResult: { _, _ in
                    loginResult.recordCall()
                    throw PersistentAuthLoginResultSpy.Error.unexpectedInvocation
                }
            )

            let status = try await coordinator.status(credentialId: "gmail-personal")
            let readsBeforeProvider = await store.dataReadCount()
            let writesBeforeProvider = await store.dataWriteCount()
            do {
                _ = try await coordinator.hydratedConfig()
                XCTFail("Expected \(testCase.name) mismatch to block provider hydration")
            } catch let error as GmailGatewayError {
                XCTAssertEqual(error.code, .authRequired, testCase.name)
                XCTAssertEqual(error.exitCode, .graphqlExecutionError, testCase.name)
            }

            let readsAfterProvider = await store.dataReadCount()
            let writesAfterProvider = await store.dataWriteCount()
            XCTAssertEqual(status["tokenState"] as? String, AuthState.scopeMismatch.rawValue, testCase.name)
            XCTAssertEqual(loginResult.callCount(), 0, testCase.name)
            XCTAssertEqual(readsAfterProvider, readsBeforeProvider, testCase.name)
            XCTAssertEqual(writesAfterProvider, writesBeforeProvider, testCase.name)
            XCTAssertTrue(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty, testCase.name)

            let cli = GmailGatewayCLI(
                mode: .reader,
                authPolicy: .persistent(requiredAccessMode: .read),
                secureCredentialStore: store
            )
            let provider = await cli.runPersistent(
                arguments: [
                    "--config", cliConfigURL.path, "graphql", "--query",
                    #"{ profile(accountId: "personal") { emailAddress } }"#
                ],
                environment: [:]
            )
            let readsAfterCommand = await store.dataReadCount()
            let writesAfterCommand = await store.dataWriteCount()
            try assertGraphQLErrorOutput(
                provider,
                expectedCode: GmailGatewayErrorCode.authRequired,
                context: testCase.name
            )
            XCTAssertEqual(loginResult.callCount(), 0, testCase.name)
            XCTAssertEqual(readsAfterCommand, readsBeforeProvider, testCase.name)
            XCTAssertEqual(writesAfterCommand, writesBeforeProvider, testCase.name)
            XCTAssertTrue(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty, testCase.name)
        }
    }

    func testPersistentGraphQLHydrationFailuresUseGraphQLErrorOutput() async throws {
        let client = testClient()
        let token = try coherentToken(client: client)
        let fingerprintMismatch = GmailOAuthTokenStore(
            accessMode: token.accessMode,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            tokenType: token.tokenType,
            scope: token.scope,
            expiresAt: token.expiresAt,
            emailAddress: token.emailAddress,
            clientFingerprint: "incompatible-client-fingerprint",
            schemaVersion: token.schemaVersion,
            provider: token.provider,
            credentialId: token.credentialId
        )
        let scopeMismatch = GmailOAuthTokenStore(
            accessMode: token.accessMode,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            tokenType: token.tokenType,
            scope: "https://www.googleapis.com/auth/gmail.readonly https://example.invalid/extra",
            expiresAt: token.expiresAt,
            emailAddress: token.emailAddress,
            clientFingerprint: token.clientFingerprint,
            schemaVersion: token.schemaVersion,
            provider: token.provider,
            credentialId: token.credentialId
        )
        let principalMismatch = GmailOAuthTokenStore(
            accessMode: token.accessMode,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            tokenType: token.tokenType,
            scope: token.scope,
            expiresAt: token.expiresAt,
            emailAddress: "wrong-account@example.invalid",
            clientFingerprint: token.clientFingerprint,
            schemaVersion: token.schemaVersion,
            provider: token.provider,
            credentialId: token.credentialId
        )
        let expiredToken = GmailOAuthTokenStore(
            accessMode: token.accessMode,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            tokenType: token.tokenType,
            scope: token.scope,
            expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60)),
            emailAddress: "personal@example.invalid",
            clientFingerprint: token.clientFingerprint,
            schemaVersion: token.schemaVersion,
            provider: token.provider,
            credentialId: token.credentialId
        )
        let cases = [
            PersistentGraphQLHydrationFailure("fingerprint", fingerprintMismatch, .authRequired, refreshFailure: false),
            PersistentGraphQLHydrationFailure("scope", scopeMismatch, .authRequired, refreshFailure: false),
            PersistentGraphQLHydrationFailure("principal", principalMismatch, .authRequired, refreshFailure: false),
            PersistentGraphQLHydrationFailure("refresh", expiredToken, .providerApiError, refreshFailure: true)
        ]
        TestGmailRequestCaptureProtocol.reset()
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }

        for testCase in cases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(testCase.token).write(to: root.appendingPathComponent("token.json"))
            let configURL = try writePersistentConfiguredCredentialConfig(at: root, client: client)
            TestGmailRequestCaptureProtocol.reset()
            if testCase.refreshFailure {
                TestGmailRequestCaptureProtocol.responseStatusCode = 400
                TestGmailRequestCaptureProtocol.responseData = Data(#"{"error":{"message":"refresh-failure-sentinel"}}"#.utf8)
            }

            let result = await GmailGatewayCLI(
                mode: .reader,
                authPolicy: .persistent(requiredAccessMode: .read),
                secureCredentialStore: TestSecureCredentialStore()
            ).runPersistent(
                arguments: [
                    "--config", configURL.path, "graphql", "--query",
                    #"{ profile(accountId: "personal") { emailAddress } }"#
                ],
                environment: [:]
            )

            try assertGraphQLErrorOutput(result, expectedCode: testCase.expectedCode, context: testCase.name)
            XCTAssertFalse(result.stdout.contains("refresh-failure-sentinel"), testCase.name)
            if testCase.refreshFailure {
                XCTAssertEqual(TestGmailRequestCaptureProtocol.capturedURLs.map(\.host), ["oauth2.googleapis.com"])
            } else {
                XCTAssertTrue(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty, testCase.name)
            }
        }
    }

    func testLoginScopeMismatchCallsInjectedLoginOnceAndPreservesVaultWithoutTransport() async throws {
        let client = testClient()
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        let existing = try coherentToken(client: client)
        try await vault.replaceProfile(testProfile(client: client, token: existing))
        let loginResult = PersistentAuthLoginResultSpy()
        let rejectedLoginToken = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "rejected-login-access-token",
            refreshToken: "rejected-login-refresh-token",
            tokenType: "Bearer",
            scope: "https://www.googleapis.com/auth/gmail.readonly https://example.invalid/extra",
            expiresAt: nil,
            emailAddress: nil,
            clientFingerprint: nil
        )
        let coordinator = GmailAuthCoordinator(
            config: persistentConfig(tokenPath: "/unused", fallback: true),
            environment: [:],
            policy: .persistent(requiredAccessMode: .read),
            store: store,
            loginResult: { _, _ in
                loginResult.recordCall()
                return GmailOAuthLoginResult(
                    tokenStore: rejectedLoginToken,
                    redirectURI: "http://127.0.0.1:1/oauth2callback"
                )
            }
        )
        TestGmailRequestCaptureProtocol.reset()
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }
        let writesBeforeLogin = await store.dataWriteCount()

        do {
            _ = try await coordinator.login(
                credentialId: "gmail-personal",
                options: GmailOAuthLoginOptions(openBrowser: false)
            )
            XCTFail("Expected login scope mismatch to reject")
        } catch let error as GmailGatewayError {
            XCTAssertEqual(error.code, .authRequired)
            XCTAssertEqual(error.exitCode, .authenticationBootstrapError)
        }

        let retained = try await vault.profile(credentialId: "gmail-personal", accessMode: .read)
        let writesAfterLogin = await store.dataWriteCount()
        XCTAssertEqual(loginResult.callCount(), 1)
        XCTAssertEqual(writesAfterLogin, writesBeforeLogin)
        XCTAssertEqual(retained?.token?.accessToken, existing.accessToken)
        XCTAssertTrue(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty)
    }

    func testExactScopeSetIsRequiredBeforeProviderUse() throws {
        let client = testClient()
        var token = try coherentToken(client: client)
        token = GmailOAuthTokenStore(
            accessMode: token.accessMode,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            tokenType: token.tokenType,
            scope: "https://www.googleapis.com/auth/gmail.readonly extra",
            expiresAt: token.expiresAt,
            emailAddress: token.emailAddress,
            clientFingerprint: token.clientFingerprint
        )

        XCTAssertThrowsError(try validatePersistentToken(
            token,
            client: client,
            credential: persistentConfig(tokenPath: "/unused", fallback: true).credentials[0],
            accounts: []
        ))
    }

    func testPrincipalAndFingerprintMustMatchConfiguredCredential() throws {
        let client = testClient()
        let config = persistentConfig(tokenPath: "/unused", fallback: false)
        let credential = config.credentials[0]
        let token = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "access-token",
            refreshToken: "refresh-token",
            tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "),
            expiresAt: nil,
            emailAddress: "other@example.invalid",
            clientFingerprint: try gmailOAuthClientFingerprint(client)
        )

        XCTAssertThrowsError(try validatePersistentToken(token, client: client, credential: credential, accounts: config.accounts))
    }

    func testConstantTimeComparisonRejectsDifferentFingerprints() {
        XCTAssertTrue(constantTimeEqual("same", "same"))
        XCTAssertFalse(constantTimeEqual("same", "different"))
    }

    func testLoginPrincipalIsValidatedBeforePersistence() throws {
        let client = testClient()
        let config = persistentConfig(tokenPath: "/unused", fallback: false)
        let loginToken = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "access-token",
            refreshToken: "refresh-token",
            tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "),
            expiresAt: nil,
            emailAddress: "wrong-account@example.invalid",
            clientFingerprint: nil
        )

        XCTAssertThrowsError(try validatedPersistentLoginToken(
            loginToken,
            credential: config.credentials[0],
            client: client,
            accounts: config.accounts
        ))
    }

    func testLoginUsesRequestedScopesWhenProviderOmitsScopeAndRequiresRefreshToken() throws {
        let client = testClient()
        let config = persistentConfig(tokenPath: "/unused", fallback: true)
        let omittedScope = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "access-token",
            refreshToken: "refresh-token",
            tokenType: "Bearer",
            scope: nil,
            expiresAt: nil,
            emailAddress: nil,
            clientFingerprint: nil
        )
        let validated = try validatedPersistentLoginToken(
            omittedScope,
            credential: config.credentials[0],
            client: client,
            accounts: config.accounts
        )
        XCTAssertEqual(validated.scope, gmailScopes(accessMode: .read).joined(separator: " "))

        let missingRefresh = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "access-token",
            refreshToken: nil,
            tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "),
            expiresAt: nil,
            emailAddress: nil,
            clientFingerprint: nil
        )
        XCTAssertThrowsError(try validatedPersistentLoginToken(
            missingRefresh,
            credential: config.credentials[0],
            client: client,
            accounts: config.accounts
        ))
    }
}

private struct PersistentGraphQLHydrationFailure {
    let name: String
    let token: GmailOAuthTokenStore
    let expectedCode: GmailGatewayErrorCode
    let refreshFailure: Bool

    init(
        _ name: String,
        _ token: GmailOAuthTokenStore,
        _ expectedCode: GmailGatewayErrorCode,
        refreshFailure: Bool
    ) {
        self.name = name
        self.token = token
        self.expectedCode = expectedCode
        self.refreshFailure = refreshFailure
    }
}

private func assertGraphQLErrorOutput(
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
    XCTAssertTrue(body["data"] is NSNull, context)
    let errors = try XCTUnwrap(body["errors"] as? [[String: Any]], context)
    XCTAssertEqual(errors.first?["code"] as? String, expectedCode.rawValue, context)
}

private func writePersistentConfiguredCredentialConfig(
    at root: URL,
    client: GmailOAuthClientRecord
) throws -> URL {
    let clientPath = root.appendingPathComponent("client.json")
    try client.legacyJSON().write(to: clientPath, atomically: true, encoding: .utf8)
    let configPath = root.appendingPathComponent("config.toml")
    let source = """
    [storage]
    cache_dir = "cache"
    attachment_dir = "attachments"
    allowed_send_attachment_roots = ["send"]

    [[credentials]]
    id = "gmail-personal"
    provider = "gmail"
    access_mode = "read"
    oauth_client_secret_path = "client.json"
    token_store_path = "token.json"

    [[accounts]]
    id = "personal"
    provider = "gmail"
    email_address = "personal@example.invalid"
    credential_id = "gmail-personal"
    default_label_ids = ["INBOX"]
    """
    try source.write(to: configPath, atomically: true, encoding: .utf8)
    return configPath
}

private final class PersistentAuthLoginResultSpy: @unchecked Sendable {
    enum Error: Swift.Error {
        case unexpectedInvocation
    }

    private let lock = NSLock()
    private var calls = 0

    func recordCall() {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}
