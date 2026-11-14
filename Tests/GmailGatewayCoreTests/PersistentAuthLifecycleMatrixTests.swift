import Foundation
@testable import GmailGatewayCore
import XCTest

final class PersistentAuthLifecycleMatrixTests: XCTestCase {
    func testAllTargetModesCoverVaultLifecycleReplacementFailureAndStatusRedaction() async throws {
        let targets: [(GmailGatewayCLIMode, AccessMode)] = [
            (.reader, .read),
            (.draftGateway, .readSend),
            (.directSender, .readSend)
        ]
        for (mode, accessMode) in targets {
            let configURL = try makeVaultOnlyConfig(accessMode: accessMode)
            let root = configURL.deletingLastPathComponent()
            let clientPath = root.appendingPathComponent("client.json")
            defer { try? FileManager.default.removeItem(at: root) }
            let client = testClient()
            try client.legacyJSON().write(to: clientPath, atomically: true, encoding: .utf8)
            let token = GmailOAuthTokenStore(
                accessMode: accessMode,
                accessToken: "access-\(mode.executableName)",
                refreshToken: "refresh-token",
                tokenType: "Bearer",
                scope: gmailScopes(accessMode: accessMode).joined(separator: " "),
                expiresAt: nil,
                emailAddress: "person@example.com",
                clientFingerprint: nil
            )
            let store = TestSecureCredentialStore()
            let coordinator = GmailAuthCoordinator(
                config: try GmailGatewayConfigLoader.loadConfig(configPath: configURL.path, environment: [:]),
                environment: [:],
                policy: persistentPolicy(for: mode),
                store: store,
                loginResult: { _, _ in
                    GmailOAuthLoginResult(
                        tokenStore: token,
                        redirectURI: "http://127.0.0.1:1/oauth2callback"
                    )
                }
            )

            _ = try await coordinator.setup(
                credentialId: "gmail-personal",
                options: GmailOAuthSetupOptions(
                    clientSecretPath: clientPath.path,
                    replace: false,
                    confirmedCredentialId: nil
                )
            )
            await XCTAssertThrowsErrorAsync {
                _ = try await coordinator.setup(
                    credentialId: "gmail-personal",
                    options: GmailOAuthSetupOptions(
                        clientSecretPath: root.appendingPathComponent("must-not-read.json").path,
                        replace: true,
                        confirmedCredentialId: "wrong"
                    )
                )
            }
            let vault = GmailCredentialVault(store: store)
            let preserved = try await vault.profile(credentialId: "gmail-personal", accessMode: accessMode)
            XCTAssertEqual(preserved?.client, client)
            XCTAssertNil(preserved?.token)

            let login = try await coordinator.login(
                credentialId: "gmail-personal",
                options: GmailOAuthLoginOptions(openBrowser: false)
            )
            let status = try await coordinator.status(credentialId: "gmail-personal")
            let cli = GmailGatewayCLI(
                mode: mode,
                authPolicy: persistentPolicy(for: mode),
                secureCredentialStore: store
            )
            let renderedStatus = await cli.runPersistent(
                arguments: ["--config", configURL.path, "auth", "status", "--credential", "gmail-personal"],
                environment: [:]
            )
            let revoke = try await coordinator.revoke(
                credentialId: "gmail-personal",
                confirmedCredentialId: "gmail-personal"
            )
            let profileAfterRevoke = try await vault.profile(credentialId: "gmail-personal", accessMode: accessMode)

            XCTAssertEqual(login["persistenceBackend"] as? String, "KEYCHAIN", "\(mode)")
            XCTAssertEqual(status["tokenState"] as? String, AuthState.ready.rawValue, "\(mode)")
            XCTAssertEqual(renderedStatus.exitCode, GmailGatewayExitCode.success.rawValue, "\(mode)")
            XCTAssertFalse(renderedStatus.stdout.contains(client.clientSecret ?? "client-secret"), "\(mode)")
            XCTAssertFalse(renderedStatus.stdout.contains("gmail-profile:"), "\(mode)")
            XCTAssertEqual(revoke["revoked"] as? Bool, true, "\(mode)")
            XCTAssertEqual(profileAfterRevoke?.client, client, "\(mode)")
            XCTAssertNil(profileAfterRevoke?.token, "\(mode)")
        }
    }

    func testAllTargetModesCoverSetupLoginStatusAndRevoke() async throws {
        let targets: [(GmailGatewayCLIMode, AccessMode)] = [
            (.reader, .read),
            (.draftGateway, .readSend),
            (.directSender, .readSend)
        ]
        for (mode, accessMode) in targets {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let clientPath = root.appendingPathComponent("client.json").path
            let tokenPath = root.appendingPathComponent("token.json").path
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let client = testClient()
            try client.legacyJSON().write(toFile: clientPath, atomically: true, encoding: .utf8)
            let credential = CredentialConfig(
                id: "gmail-personal", provider: .gmail, accessMode: accessMode,
                oauthClientSecretPath: clientPath, oauthClientSecretJSON: nil,
                tokenStorePath: tokenPath, tokenStoreJSON: nil,
                oauthClientSecretSource: .configuredPath, tokenStoreSource: .configuredPath
            )
            let config = GmailGatewayConfig(
                configPath: root.appendingPathComponent("config.toml").path,
                storage: StorageConfig(cacheDir: root.path, attachmentDir: root.path, allowedSendAttachmentRoots: []),
                credentials: [credential],
                accounts: [AccountConfig(id: "personal", provider: .gmail, emailAddress: "person@example.invalid", credentialId: credential.id, defaultLabelIds: [], isFallback: true)]
            )
            let token = GmailOAuthTokenStore(
                accessMode: accessMode, accessToken: "access-\(mode.executableName)", refreshToken: "refresh-token",
                tokenType: "Bearer", scope: gmailScopes(accessMode: accessMode).joined(separator: " "),
                expiresAt: nil, emailAddress: nil, clientFingerprint: nil
            )
            let coordinator = GmailAuthCoordinator(
                config: config, environment: [:], policy: persistentPolicy(for: mode), store: TestSecureCredentialStore(),
                loginResult: { _, _ in GmailOAuthLoginResult(tokenStore: token, redirectURI: "http://127.0.0.1:1/oauth2callback") }
            )

            _ = try await coordinator.setup(credentialId: credential.id, options: GmailOAuthSetupOptions(clientSecretPath: clientPath, replace: false, confirmedCredentialId: nil))
            let login = try await coordinator.login(credentialId: credential.id, options: GmailOAuthLoginOptions(openBrowser: false))
            let status = try await coordinator.status(credentialId: credential.id)
            let revoke = try await coordinator.revoke(credentialId: credential.id, confirmedCredentialId: credential.id)

            XCTAssertEqual(login["persistenceBackend"] as? String, "FILE")
            XCTAssertEqual(status["tokenState"] as? String, AuthState.ready.rawValue)
            XCTAssertEqual(revoke["revoked"] as? Bool, true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: tokenPath))
        }
    }

    func testConfiguredFileRevokeIsIdempotentAndPreservesVaultClient() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tokenPath = root.appendingPathComponent("nested/token.json").path
        defer { try? FileManager.default.removeItem(at: root) }
        let client = testClient()
        let token = try coherentToken(client: client)
        try writeGmailOAuthTokenStore(token, to: tokenPath, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: tokenPath).deletingLastPathComponent().path)
        let tokenAttributes = try FileManager.default.attributesOfItem(atPath: tokenPath)
        XCTAssertEqual(directoryAttributes[.posixPermissions] as? NSNumber, 0o700)
        XCTAssertEqual(tokenAttributes[.posixPermissions] as? NSNumber, 0o600)

        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: nil))
        let config = try persistentConfiguredTokenPathConfig(tokenPath: tokenPath)
        let coordinator = GmailAuthCoordinator(config: config, environment: [:], policy: .persistent(requiredAccessMode: .read), store: store)

        let first = try await coordinator.revoke(credentialId: "gmail-personal", confirmedCredentialId: "gmail-personal")
        let second = try await coordinator.revoke(credentialId: "gmail-personal", confirmedCredentialId: "gmail-personal")
        let retained = try await vault.profile(credentialId: "gmail-personal", accessMode: .read)

        XCTAssertEqual(first["revoked"] as? Bool, true)
        XCTAssertEqual(second["revoked"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tokenPath))
        XCTAssertEqual(retained?.client, client)
    }

    func testVaultRevokeClearsOnlyTokenAndIsIdempotent() async throws {
        let client = testClient()
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: try coherentToken(client: client)))
        let coordinator = GmailAuthCoordinator(
            config: persistentConfig(tokenPath: "/unused", fallback: true),
            environment: [:], policy: .persistent(requiredAccessMode: .read), store: store
        )

        let first = try await coordinator.revoke(credentialId: "gmail-personal", confirmedCredentialId: "gmail-personal")
        let second = try await coordinator.revoke(credentialId: "gmail-personal", confirmedCredentialId: "gmail-personal")
        let profile = try await vault.profile(credentialId: "gmail-personal", accessMode: .read)

        XCTAssertEqual(first["revoked"] as? Bool, true)
        XCTAssertEqual(second["revoked"] as? Bool, false)
        XCTAssertEqual(profile?.client, client)
        XCTAssertNil(profile?.token)
    }

    func testStatusIsLocalOnlyAndReportsIndependentSources() async throws {
        let client = testClient()
        let token = try coherentToken(client: client)
        let tokenJSON = try XCTUnwrap(String(data: JSONEncoder().encode(token), encoding: .utf8))
        let clientJSON = try client.legacyJSON()
        let credentialID = "gmail-personal"
        let environment = [
            GmailGatewayConfigLoader.getCredentialJSONEnvVarName(credentialId: credentialID, valueKey: "oauth_client_secret_json"): clientJSON,
            GmailGatewayConfigLoader.getCredentialJSONEnvVarName(credentialId: credentialID, valueKey: "token_store_json"): tokenJSON
        ]
        let config = try GmailGatewayConfigLoader.loadConfig(environment: environment)
        let coordinator = GmailAuthCoordinator(config: config, environment: environment, policy: .persistent(requiredAccessMode: .read), store: TestSecureCredentialStore())
        TestGmailRequestCaptureProtocol.reset()
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }

        let status = try await coordinator.status(credentialId: credentialID)

        XCTAssertEqual(status["clientSource"] as? String, GmailCredentialSourceKind.environmentJSON.rawValue)
        XCTAssertEqual(status["tokenSource"] as? String, GmailCredentialSourceKind.environmentJSON.rawValue)
        XCTAssertEqual(status["tokenState"] as? String, AuthState.ready.rawValue)
        XCTAssertTrue(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty)
    }

    func testModeGuardFailsBeforeVaultRead() async throws {
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: testClient(), token: nil))
        let readsBefore = await store.dataReadCount()
        let readSendCredential = CredentialConfig(
            id: "gmail-personal", provider: .gmail, accessMode: .readSend,
            oauthClientSecretPath: "/unused", oauthClientSecretJSON: nil,
            tokenStorePath: "/unused", tokenStoreJSON: nil
        )
        let config = GmailGatewayConfig(
            configPath: "/unused", storage: StorageConfig(cacheDir: "/tmp", attachmentDir: "/tmp", allowedSendAttachmentRoots: []),
            credentials: [readSendCredential],
            accounts: [AccountConfig(id: "personal", provider: .gmail, emailAddress: "person@example.com", credentialId: "gmail-personal", defaultLabelIds: [])]
        )
        let coordinator = GmailAuthCoordinator(config: config, environment: [:], policy: .persistent(requiredAccessMode: .read), store: store)

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.status(credentialId: "gmail-personal")
        }
        let readsAfter = await store.dataReadCount()
        XCTAssertEqual(readsAfter, readsBefore)
    }
}
