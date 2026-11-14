import Foundation
@testable import GmailGatewayCore
import XCTest

final class PersistentAuthResolutionTests: XCTestCase {
    func testEnvironmentSourcesHaveIndependentHighestPrecedence() async throws {
        let client = testClient()
        let token = try coherentToken(client: client)
        let clientJSON = try client.legacyJSON()
        let tokenData = try JSONEncoder().encode(token)
        let tokenJSON = try XCTUnwrap(String(bytes: tokenData, encoding: .utf8))
        let credentialID = "gmail-personal"
        let environment = [
            GmailGatewayConfigLoader.getCredentialJSONEnvVarName(credentialId: credentialID, valueKey: "oauth_client_secret_json"): clientJSON,
            GmailGatewayConfigLoader.getCredentialJSONEnvVarName(credentialId: credentialID, valueKey: "token_store_json"): tokenJSON
        ]
        let config = try GmailGatewayConfigLoader.loadConfig(environment: environment)
        let vault = GmailCredentialVault(store: TestSecureCredentialStore())
        let resolver = GmailAuthResolver(
            config: config,
            environment: environment,
            policy: .persistent(requiredAccessMode: .read),
            vault: vault
        )

        let clientValue = try await resolver.resolveClient(for: config.credentials[0])
        let tokenValue = try await resolver.resolveToken(for: config.credentials[0])
        let resolvedClient = try XCTUnwrap(clientValue)
        let resolvedToken = try XCTUnwrap(tokenValue)
        XCTAssertEqual(resolvedClient.kind, .environmentJSON)
        XCTAssertEqual(resolvedToken.source.kind, .environmentJSON)
        XCTAssertFalse(resolvedToken.source.writable)
    }

    func testVaultTokenWinsOverSynthesizedLegacyFile() async throws {
        let client = testClient()
        let token = try coherentToken(client: client)
        let tokenPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: tokenPath) }
        try JSONEncoder().encode(try coherentToken(client: client)).write(to: tokenPath)
        let config = persistentConfig(tokenPath: tokenPath.path, fallback: true)
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: token))
        let resolver = GmailAuthResolver(
            config: config,
            environment: [:],
            policy: .persistent(requiredAccessMode: .read),
            vault: vault
        )

        let tokenValue = try await resolver.resolveToken(for: config.credentials[0])
        let resolved = try XCTUnwrap(tokenValue)
        XCTAssertEqual(resolved.source.kind, .secureVault)
    }

    func testHydrationRejectsMixedClientTokenFingerprint() async throws {
        let client = testClient()
        let token = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "access-token",
            refreshToken: "refresh-token",
            tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "),
            expiresAt: nil,
            emailAddress: nil,
            clientFingerprint: "different-client"
        )
        let config = persistentConfig(tokenPath: "/not-used", fallback: true)
        let store = TestSecureCredentialStore()
        await store.put(
            try JSONEncoder().encode(testProfile(client: client, token: token)),
            account: "gmail-profile:gmail-personal:read"
        )
        let coordinator = GmailAuthCoordinator(
            config: config,
            environment: [:],
            policy: .persistent(requiredAccessMode: .read),
            store: store
        )

        await XCTAssertThrowsErrorAsync { _ = try await coordinator.hydratedConfig() }
    }

    func testFingerprintMismatchStopsBeforeRefreshTransport() async throws {
        let client = testClient()
        let token = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "access-token",
            refreshToken: "refresh-token",
            tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "),
            expiresAt: "2020-01-01T00:00:00Z",
            emailAddress: nil,
            clientFingerprint: "different-client"
        )
        let store = TestSecureCredentialStore()
        await store.put(
            try JSONEncoder().encode(testProfile(client: client, token: token)),
            account: "gmail-profile:gmail-personal:read"
        )
        TestGmailRequestCaptureProtocol.reset()
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }
        let coordinator = GmailAuthCoordinator(
            config: persistentConfig(tokenPath: "/not-used", fallback: true),
            environment: [:],
            policy: .persistent(requiredAccessMode: .read),
            store: store
        )

        await XCTAssertThrowsErrorAsync { _ = try await coordinator.hydratedConfig() }

        XCTAssertTrue(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty)
    }

    func testHydrationRejectsTokenWithoutMatchingClient() async throws {
        let client = testClient()
        let token = try coherentToken(client: client)
        let tokenData = try JSONEncoder().encode(token)
        let tokenJSON = try XCTUnwrap(String(bytes: tokenData, encoding: .utf8))
        let coordinator = GmailAuthCoordinator(
            config: persistentConfig(tokenPath: "/not-used", fallback: true, tokenJSON: tokenJSON),
            environment: [:],
            policy: .persistent(requiredAccessMode: .read),
            store: TestSecureCredentialStore()
        )

        await XCTAssertThrowsErrorAsync { _ = try await coordinator.hydratedConfig() }
    }

    func testInlineTokenCannotBeRevoked() async throws {
        let client = testClient()
        let token = try coherentToken(client: client)
        let tokenData = try JSONEncoder().encode(token)
        let tokenJSON = try XCTUnwrap(String(bytes: tokenData, encoding: .utf8))
        let config = persistentConfig(
            tokenPath: "/not-used",
            fallback: true,
            tokenJSON: tokenJSON
        )
        let coordinator = GmailAuthCoordinator(
            config: config,
            environment: [:],
            policy: .persistent(requiredAccessMode: .read),
            store: TestSecureCredentialStore()
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.revoke(credentialId: "gmail-personal", confirmedCredentialId: "gmail-personal")
        }
    }

    func testPersistentDoctorInspectsVaultOnlyCredentials() async throws {
        let client = testClient()
        let coherent = try coherentToken(client: client)
        let token = GmailOAuthTokenStore(
            accessMode: coherent.accessMode,
            accessToken: coherent.accessToken,
            refreshToken: coherent.refreshToken,
            tokenType: coherent.tokenType,
            scope: coherent.scope,
            expiresAt: coherent.expiresAt,
            emailAddress: "person@example.com",
            clientFingerprint: coherent.clientFingerprint,
            schemaVersion: coherent.schemaVersion,
            provider: coherent.provider,
            credentialId: coherent.credentialId
        )
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: token))
        let configURL = try makeVaultOnlyConfig(accessMode: .read)
        defer { try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent()) }
        let cli = GmailGatewayCLI(
            mode: .reader,
            authPolicy: .persistent(requiredAccessMode: .read),
            secureCredentialStore: store
        )

        let result = await cli.runPersistent(arguments: ["--config", configURL.path, "doctor"], environment: [:])
        let reads = await store.dataReadCount()
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let credentials = try XCTUnwrap(output["credentials"] as? [[String: Any]])
        let credential = try XCTUnwrap(credentials.first)
        let oauthClient = try XCTUnwrap(credential["oauthClient"] as? [String: Any])
        let auth = try XCTUnwrap(credential["auth"] as? [String: Any])

        XCTAssertGreaterThan(reads, 0)
        XCTAssertEqual(result.exitCode, GmailGatewayExitCode.success.rawValue, result.stdout)
        XCTAssertEqual(oauthClient["source"] as? String, GmailCredentialSourceKind.secureVault.rawValue)
        XCTAssertEqual(auth["source"] as? String, GmailCredentialSourceKind.secureVault.rawValue)
    }

    func testPersistentDoctorRejectsWrongModeBeforeVaultRead() async throws {
        let client = testClient()
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: try coherentToken(client: client)))
        let configURL = try makeVaultOnlyConfig(accessMode: .read)
        defer { try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent()) }
        let cli = GmailGatewayCLI(
            mode: .directSender,
            authPolicy: .persistent(requiredAccessMode: .readSend),
            secureCredentialStore: store
        )

        let result = await cli.runPersistent(arguments: ["--config", configURL.path, "doctor"], environment: [:])
        let reads = await store.dataReadCount()
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let issues = try XCTUnwrap(output["issues"] as? [[String: Any]])

        XCTAssertEqual(reads, 0)
        XCTAssertEqual(result.exitCode, GmailGatewayExitCode.configurationError.rawValue)
        XCTAssertTrue(issues.contains { $0["code"] as? String == "ACCESS_MODE_MISMATCH" })
    }

    func testPersistentCachePruneDoesNotReadPersistentCredentials() async throws {
        let client = testClient()
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: try coherentToken(client: client)))
        let cli = GmailGatewayCLI(
            mode: .reader,
            authPolicy: .persistent(requiredAccessMode: .read),
            secureCredentialStore: store
        )

        let result = await cli.runPersistent(arguments: ["cache", "prune", "--all"], environment: [:])

        let reads = await store.dataReadCount()
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(result.exitCode, GmailGatewayExitCode.success.rawValue)
    }

    func testInvalidPersistentCommandDoesNotReadOrWriteCredentials() async throws {
        let client = testClient()
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: try coherentToken(client: client)))
        let readsBefore = await store.dataReadCount()
        let writesBefore = await store.dataWriteCount()
        let cli = GmailGatewayCLI(
            mode: .reader,
            authPolicy: .persistent(requiredAccessMode: .read),
            secureCredentialStore: store
        )

        let result = await cli.runPersistent(arguments: ["unknown-command"], environment: [:])
        let readsAfter = await store.dataReadCount()
        let writesAfter = await store.dataWriteCount()

        XCTAssertEqual(result.exitCode, GmailGatewayExitCode.invalidCliUsage.rawValue)
        XCTAssertEqual(readsAfter, readsBefore)
        XCTAssertEqual(writesAfter, writesBefore)
    }

    func testMissingRelocatedTokenFallsBackToVault() async throws {
        let client = testClient()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let credential = CredentialConfig(
            id: "gmail-personal", provider: .gmail, accessMode: .read,
            oauthClientSecretPath: root.appendingPathComponent("client.json").path,
            oauthClientSecretJSON: nil,
            tokenStorePath: root.appendingPathComponent("relocated-token.json").path,
            tokenStoreJSON: nil,
            oauthClientSecretSource: .synthesizedDefault,
            tokenStoreSource: .relocatedPath
        )
        let config = GmailGatewayConfig(
            configPath: root.appendingPathComponent("config.toml").path,
            storage: StorageConfig(cacheDir: root.path, attachmentDir: root.path, allowedSendAttachmentRoots: []),
            credentials: [credential],
            accounts: [AccountConfig(id: "personal", provider: .gmail, emailAddress: "person@example.com", credentialId: credential.id, defaultLabelIds: [])]
        )
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: try coherentToken(client: client)))
        let resolver = GmailAuthResolver(config: config, environment: [:], policy: .persistent(requiredAccessMode: .read), vault: vault)

        let resolvedToken = try await resolver.resolveToken(for: credential)
        let resolved = try XCTUnwrap(resolvedToken)

        XCTAssertEqual(resolved.source.kind, .secureVault)
    }

    func testSynthesizedLegacyTokenIsRetainedAsLoginDestination() async throws {
        let client = testClient()
        let tokenPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: tokenPath) }
        try JSONEncoder().encode(try coherentToken(client: client)).write(to: tokenPath)
        let config = persistentConfig(tokenPath: tokenPath.path, fallback: true)
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: nil))
        let resolver = GmailAuthResolver(config: config, environment: [:], policy: .persistent(requiredAccessMode: .read), vault: vault)

        let destination = try await resolver.loginDestination(for: config.credentials[0], client: client)

        guard case let .file(path, _) = destination else {
            return XCTFail("Expected legacy synthesized token destination")
        }
        XCTAssertEqual(path, tokenPath.path)
    }

    func testLoginDestinationRejectsMismatchedVaultClient() async throws {
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: testClient(), token: nil))
        let differentClient = GmailOAuthClientRecord(
            kind: "installed", clientId: "different.apps.googleusercontent.com", clientSecret: "different-secret",
            projectId: "different-project", authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenEndpoint: "https://oauth2.googleapis.com/token", redirectURIs: ["http://127.0.0.1:8080/oauth2callback"]
        )
        let config = persistentConfig(tokenPath: "/not-used", fallback: true)
        let resolver = GmailAuthResolver(config: config, environment: [:], policy: .persistent(requiredAccessMode: .read), vault: vault)

        await XCTAssertThrowsErrorAsync { _ = try await resolver.loginDestination(for: config.credentials[0], client: differentClient) }
    }

    func testStatusReportsInvalidExpiryAndActualVaultTokenState() async throws {
        let client = testClient()
        let token = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "access-token",
            refreshToken: "refresh-token",
            tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "),
            expiresAt: "not-a-date",
            emailAddress: nil,
            clientFingerprint: try gmailOAuthClientFingerprint(client),
            schemaVersion: 1,
            provider: .gmail,
            credentialId: "gmail-personal"
        )
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: token))
        let coordinator = GmailAuthCoordinator(
            config: persistentConfig(tokenPath: "/not-used", fallback: true),
            environment: [:],
            policy: .persistent(requiredAccessMode: .read),
            store: store
        )

        let status = try await coordinator.status(credentialId: "gmail-personal")

        XCTAssertEqual(status["tokenState"] as? String, AuthState.invalid.rawValue)
        XCTAssertEqual(status["persistentTokenExists"] as? Bool, true)
    }

    func testVaultRefreshPersistsTheReturnedToken() async throws {
        let client = testClient()
        let token = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "old-access-token",
            refreshToken: "refresh-token",
            tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "),
            expiresAt: "2020-01-01T00:00:00Z",
            emailAddress: nil,
            clientFingerprint: try gmailOAuthClientFingerprint(client),
            schemaVersion: 1,
            provider: .gmail,
            credentialId: "gmail-personal"
        )
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: token))
        TestGmailRequestCaptureProtocol.reset()
        TestGmailRequestCaptureProtocol.responseData = Data(#"{"access_token":"new-access-token","expires_in":3600}"#.utf8)
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }
        let coordinator = GmailAuthCoordinator(
            config: persistentConfig(tokenPath: "/not-used", fallback: true),
            environment: [:],
            policy: .persistent(requiredAccessMode: .read),
            store: store
        )

        _ = try await coordinator.hydratedConfig()

        let refreshed = try await vault.profile(credentialId: "gmail-personal", accessMode: .read)
        XCTAssertEqual(refreshed?.token?.accessToken, "new-access-token")
        XCTAssertEqual(refreshed?.token?.refreshToken, token.refreshToken)
        XCTAssertEqual(refreshed?.token?.scope, token.scope)
        XCTAssertEqual(TestGmailRequestCaptureProtocol.capturedURLs.first?.host, "oauth2.googleapis.com")
    }

    func testRefreshRejectsIncompatibleReturnedScopesBeforeVaultWrite() async throws {
        let client = testClient()
        let token = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "old-access-token",
            refreshToken: "refresh-token",
            tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "),
            expiresAt: "2020-01-01T00:00:00Z",
            emailAddress: nil,
            clientFingerprint: try gmailOAuthClientFingerprint(client),
            schemaVersion: 1,
            provider: .gmail,
            credentialId: "gmail-personal"
        )
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: token))
        let writesBefore = await store.dataWriteCount()
        TestGmailRequestCaptureProtocol.reset()
        TestGmailRequestCaptureProtocol.responseData = Data(#"{"access_token":"new-access-token","scope":"https://www.googleapis.com/auth/gmail.send","expires_in":3600}"#.utf8)
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }
        let coordinator = GmailAuthCoordinator(
            config: persistentConfig(tokenPath: "/not-used", fallback: true),
            environment: [:], policy: .persistent(requiredAccessMode: .read), store: store
        )

        await XCTAssertThrowsErrorAsync { _ = try await coordinator.hydratedConfig() }
        let retained = try await vault.profile(credentialId: "gmail-personal", accessMode: .read)
        let writesAfter = await store.dataWriteCount()

        XCTAssertEqual(retained?.token?.accessToken, token.accessToken)
        XCTAssertEqual(writesAfter, writesBefore)
    }

    func testPathSourceKindsRemainIndependent() async throws {
        let client = testClient()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clientPath = root.appendingPathComponent("client.json")
        let tokenPath = root.appendingPathComponent("token.json")
        try client.legacyJSON().write(to: clientPath, atomically: true, encoding: .utf8)
        try JSONEncoder().encode(try coherentToken(client: client)).write(to: tokenPath)
        let credential = CredentialConfig(
            id: "gmail-personal",
            provider: .gmail,
            accessMode: .read,
            oauthClientSecretPath: clientPath.path,
            oauthClientSecretJSON: nil,
            tokenStorePath: tokenPath.path,
            tokenStoreJSON: nil,
            oauthClientSecretSource: .environmentPath,
            tokenStoreSource: .relocatedPath
        )
        let config = GmailGatewayConfig(
            configPath: root.appendingPathComponent("config.toml").path,
            storage: StorageConfig(cacheDir: root.path, attachmentDir: root.path, allowedSendAttachmentRoots: []),
            credentials: [credential],
            accounts: [AccountConfig(id: "personal", provider: .gmail, emailAddress: "person@example.com", credentialId: credential.id, defaultLabelIds: [])]
        )
        let resolver = GmailAuthResolver(
            config: config,
            environment: [:],
            policy: .persistent(requiredAccessMode: .read),
            vault: GmailCredentialVault(store: TestSecureCredentialStore())
        )

        let clientValue = try await resolver.resolveClient(for: credential)
        let tokenValue = try await resolver.resolveToken(for: credential)
        let resolvedClient = try XCTUnwrap(clientValue)
        let resolvedToken = try XCTUnwrap(tokenValue)

        XCTAssertEqual(resolvedClient.kind, .environmentPath)
        XCTAssertEqual(resolvedToken.source.kind, .relocatedPath)
    }

    func testExplicitInvalidTokenAndClientSourcesDoNotFallBackToVault() async throws {
        let client = testClient()
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: try coherentToken(client: client)))
        let credential = CredentialConfig(
            id: "gmail-personal", provider: .gmail, accessMode: .read,
            oauthClientSecretPath: "/missing-explicit-client.json", oauthClientSecretJSON: nil,
            tokenStorePath: "/missing-explicit-token.json", tokenStoreJSON: "not-json",
            oauthClientSecretSource: .configuredPath, tokenStoreSource: .configuredPath
        )
        let config = GmailGatewayConfig(
            configPath: "/unused", storage: StorageConfig(cacheDir: "/tmp", attachmentDir: "/tmp", allowedSendAttachmentRoots: []),
            credentials: [credential],
            accounts: [AccountConfig(id: "personal", provider: .gmail, emailAddress: "person@example.com", credentialId: credential.id, defaultLabelIds: [])]
        )
        let resolver = GmailAuthResolver(config: config, environment: [:], policy: .persistent(requiredAccessMode: .read), vault: vault)

        await XCTAssertThrowsErrorAsync { _ = try await resolver.resolveClient(for: credential) }
        await XCTAssertThrowsErrorAsync { _ = try await resolver.resolveToken(for: credential) }
    }

    func testIncompatibleFileTokensArePreservedBeforeLoginAndRevokeAcrossFileSources() async throws {
        let sourceKinds: [GmailCredentialSourceKind] = [
            .environmentPath,
            .configuredPath,
            .relocatedPath,
            .synthesizedDefault
        ]
        let mismatches: [(name: String, token: GmailOAuthTokenStore)] = [
            (
                "access mode",
                GmailOAuthTokenStore(
                    accessMode: .readSend,
                    accessToken: "read-send-access-token",
                    refreshToken: "read-send-refresh-token",
                    tokenType: "Bearer",
                    scope: gmailScopes(accessMode: .readSend).joined(separator: " "),
                    expiresAt: nil,
                    emailAddress: nil,
                    clientFingerprint: nil,
                    schemaVersion: 1,
                    provider: .gmail,
                    credentialId: "gmail-personal"
                )
            ),
            (
                "scope",
                GmailOAuthTokenStore(
                    accessMode: .read,
                    accessToken: "extra-scope-access-token",
                    refreshToken: "extra-scope-refresh-token",
                    tokenType: "Bearer",
                    scope: "https://www.googleapis.com/auth/gmail.readonly https://example.invalid/extra",
                    expiresAt: nil,
                    emailAddress: nil,
                    clientFingerprint: nil,
                    schemaVersion: 1,
                    provider: .gmail,
                    credentialId: "gmail-personal"
                )
            ),
            (
                "client fingerprint",
                GmailOAuthTokenStore(
                    accessMode: .read,
                    accessToken: "other-client-access-token",
                    refreshToken: "other-client-refresh-token",
                    tokenType: "Bearer",
                    scope: gmailScopes(accessMode: .read).joined(separator: " "),
                    expiresAt: nil,
                    emailAddress: nil,
                    clientFingerprint: "different-client-fingerprint",
                    schemaVersion: 1,
                    provider: .gmail,
                    credentialId: "gmail-personal"
                )
            )
        ]

        for sourceKind in sourceKinds {
            for mismatch in mismatches {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                defer { try? FileManager.default.removeItem(at: root) }
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let client = testClient()
                let clientPath = root.appendingPathComponent("client.json")
                let tokenPath = root.appendingPathComponent("token.json")
                try client.legacyJSON().write(to: clientPath, atomically: true, encoding: .utf8)
                let originalTokenData = try JSONEncoder().encode(mismatch.token)
                try originalTokenData.write(to: tokenPath)
                let credential = CredentialConfig(
                    id: "gmail-personal",
                    provider: .gmail,
                    accessMode: .read,
                    oauthClientSecretPath: clientPath.path,
                    oauthClientSecretJSON: nil,
                    tokenStorePath: tokenPath.path,
                    tokenStoreJSON: nil,
                    oauthClientSecretSource: .configuredPath,
                    tokenStoreSource: sourceKind
                )
                let config = GmailGatewayConfig(
                    configPath: root.appendingPathComponent("config.toml").path,
                    storage: StorageConfig(cacheDir: root.path, attachmentDir: root.path, allowedSendAttachmentRoots: []),
                    credentials: [credential],
                    accounts: [
                        AccountConfig(
                            id: "personal",
                            provider: .gmail,
                            emailAddress: "person@example.com",
                            credentialId: credential.id,
                            defaultLabelIds: [],
                            isFallback: true
                        )
                    ]
                )
                let loginSpy = FileTokenLoginInvocationSpy()
                let coordinator = GmailAuthCoordinator(
                    config: config,
                    environment: [:],
                    policy: .persistent(requiredAccessMode: .read),
                    store: TestSecureCredentialStore(),
                    loginResult: { _, _ in
                        loginSpy.recordCall()
                        return GmailOAuthLoginResult(
                            tokenStore: try coherentToken(client: client),
                            redirectURI: "http://127.0.0.1:1/oauth2callback"
                        )
                    }
                )

                let status = try await coordinator.status(credentialId: credential.id)
                XCTAssertEqual(status["tokenState"] as? String, AuthState.scopeMismatch.rawValue, "\(sourceKind.rawValue): \(mismatch.name)")

                do {
                    _ = try await coordinator.login(
                        credentialId: credential.id,
                        options: GmailOAuthLoginOptions(openBrowser: false)
                    )
                    XCTFail("Expected login to preserve \(sourceKind.rawValue) \(mismatch.name) token")
                } catch let error as GmailGatewayError {
                    XCTAssertEqual(error.code, .authRequired)
                    XCTAssertEqual(error.exitCode, .authenticationBootstrapError)
                    if mismatch.name != "client fingerprint" {
                        XCTAssertEqual(error.details["state"], AuthState.scopeMismatch.rawValue)
                    }
                }
                XCTAssertEqual(loginSpy.callCount(), 0, "\(sourceKind.rawValue): \(mismatch.name)")
                XCTAssertEqual(try Data(contentsOf: tokenPath), originalTokenData, "\(sourceKind.rawValue): \(mismatch.name)")

                do {
                    _ = try await coordinator.revoke(
                        credentialId: credential.id,
                        confirmedCredentialId: credential.id
                    )
                    XCTFail("Expected revoke to preserve \(sourceKind.rawValue) \(mismatch.name) token")
                } catch let error as GmailGatewayError {
                    XCTAssertEqual(error.code, .authRequired)
                    XCTAssertEqual(error.exitCode, .authenticationBootstrapError)
                    if mismatch.name != "client fingerprint" {
                        XCTAssertEqual(error.details["state"], AuthState.scopeMismatch.rawValue)
                    }
                }
                XCTAssertEqual(try Data(contentsOf: tokenPath), originalTokenData, "\(sourceKind.rawValue): \(mismatch.name)")
            }
        }
    }

    func testLegacyFileTokensRemainEligibleForMigrationAcrossFileSources() async throws {
        let sourceKinds: [GmailCredentialSourceKind] = [
            .environmentPath,
            .configuredPath,
            .relocatedPath,
            .synthesizedDefault
        ]
        let client = testClient()
        let legacyToken = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "legacy-access-token",
            refreshToken: "legacy-refresh-token",
            tokenType: "Bearer",
            scope: nil,
            expiresAt: nil,
            emailAddress: nil,
            clientFingerprint: nil
        )

        for sourceKind in sourceKinds {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let tokenPath = root.appendingPathComponent("legacy-token.json")
            try JSONEncoder().encode(legacyToken).write(to: tokenPath)
            let credential = CredentialConfig(
                id: "gmail-personal",
                provider: .gmail,
                accessMode: .read,
                oauthClientSecretPath: root.appendingPathComponent("client.json").path,
                oauthClientSecretJSON: nil,
                tokenStorePath: tokenPath.path,
                tokenStoreJSON: nil,
                oauthClientSecretSource: .synthesizedDefault,
                tokenStoreSource: sourceKind
            )
            let config = GmailGatewayConfig(
                configPath: root.appendingPathComponent("config.toml").path,
                storage: StorageConfig(cacheDir: root.path, attachmentDir: root.path, allowedSendAttachmentRoots: []),
                credentials: [credential],
                accounts: []
            )
            let resolver = GmailAuthResolver(
                config: config,
                environment: [:],
                policy: .persistent(requiredAccessMode: .read),
                vault: GmailCredentialVault(store: TestSecureCredentialStore())
            )

            let destination = try await resolver.loginDestination(for: credential, client: client)
            guard case let .file(path, _) = destination else {
                return XCTFail("Expected legacy \(sourceKind.rawValue) token to remain a login file destination")
            }
            XCTAssertEqual(path, tokenPath.path)
        }
    }

    func testLoginDestinationUsesEveryWritableSourceKind() async throws {
        let client = testClient()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for kind in [GmailCredentialSourceKind.environmentPath, .configuredPath, .relocatedPath] {
            let credential = CredentialConfig(
                id: "gmail-personal", provider: .gmail, accessMode: .read,
                oauthClientSecretPath: root.appendingPathComponent("client-\(kind.rawValue).json").path, oauthClientSecretJSON: nil,
                tokenStorePath: root.appendingPathComponent("token-\(kind.rawValue).json").path, tokenStoreJSON: nil,
                oauthClientSecretSource: .synthesizedDefault, tokenStoreSource: kind
            )
            let config = GmailGatewayConfig(
                configPath: root.appendingPathComponent("config.toml").path,
                storage: StorageConfig(cacheDir: root.path, attachmentDir: root.path, allowedSendAttachmentRoots: []),
                credentials: [credential],
                accounts: [
                    AccountConfig(
                        id: "personal",
                        provider: .gmail,
                        emailAddress: "person@example.com",
                        credentialId: credential.id,
                        defaultLabelIds: []
                    )
                ]
            )
            let resolver = GmailAuthResolver(config: config, environment: [:], policy: .persistent(requiredAccessMode: .read), vault: GmailCredentialVault(store: TestSecureCredentialStore()))
            let destination = try await resolver.loginDestination(for: credential, client: client)
            guard case let .file(path, _) = destination else { return XCTFail("Expected file destination for \(kind)") }
            XCTAssertEqual(path, credential.tokenStorePath)
        }
    }
}

private final class FileTokenLoginInvocationSpy: @unchecked Sendable {
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

func persistentConfig(tokenPath: String, fallback: Bool, tokenJSON: String? = nil) -> GmailGatewayConfig {
    let credential = CredentialConfig(
        id: "gmail-personal",
        provider: .gmail,
        accessMode: .read,
        oauthClientSecretPath: "/not-used-client",
        oauthClientSecretJSON: nil,
        tokenStorePath: tokenPath,
        tokenStoreJSON: tokenJSON,
        oauthClientSecretSource: .synthesizedDefault,
        tokenStoreSource: .synthesizedDefault
    )
    return GmailGatewayConfig(
        configPath: "/not-used-config",
        storage: StorageConfig(cacheDir: "/tmp", attachmentDir: "/tmp", allowedSendAttachmentRoots: []),
        credentials: [credential],
        accounts: [AccountConfig(
            id: "personal",
            provider: .gmail,
            emailAddress: "personal@example.invalid",
            credentialId: credential.id,
            defaultLabelIds: [],
            isFallback: fallback
        )]
    )
}

func coherentToken(client: GmailOAuthClientRecord) throws -> GmailOAuthTokenStore {
    GmailOAuthTokenStore(
        accessMode: .read,
        accessToken: "access-token",
        refreshToken: "refresh-token",
        tokenType: "Bearer",
        scope: gmailScopes(accessMode: .read).joined(separator: " "),
        expiresAt: nil,
        emailAddress: nil,
        clientFingerprint: try gmailOAuthClientFingerprint(client),
        schemaVersion: 1,
        provider: .gmail,
        credentialId: "gmail-personal"
    )
}

func testProfile(client: GmailOAuthClientRecord, token: GmailOAuthTokenStore?) -> GmailCredentialProfileEnvelope {
    GmailCredentialProfileEnvelope(
        schemaVersion: 1,
        provider: .gmail,
        credentialId: "gmail-personal",
        accessMode: .read,
        expectedScopes: gmailScopes(accessMode: .read).sorted(),
        client: client,
        token: token,
        revision: "new:\(UUID().uuidString)"
    )
}
