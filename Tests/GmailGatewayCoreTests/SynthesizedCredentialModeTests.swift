import Foundation
@testable import GmailGatewayCore
import XCTest

final class SynthesizedCredentialModeTests: XCTestCase {
    func testImplicitProfilesMatchEveryExecutableAndSeparateFileTokens() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = defaultModeEnvironment(root)
        var paths = Set<String>()
        for mode in [GmailGatewayCLIMode.reader, .draftGateway, .mailboxThreads, .messageBox] {
            let config = try GmailGatewayConfigLoader.loadConfig(environment: environment, synthesizedAccessMode: mode.synthesizedAccessMode)
            let credential = try XCTUnwrap(config.credentials.first)
            XCTAssertEqual(credential.id, "gmail-personal")
            XCTAssertEqual(credential.accessMode, mode.synthesizedAccessMode)
            XCTAssertTrue(paths.insert(credential.tokenStorePath).inserted)
            if mode == .reader {
                XCTAssertTrue(credential.tokenStorePath.hasSuffix("/gmail-personal.json"))
                XCTAssertNotNil(credential.legacyDefaultTokenStorePath)
            } else { XCTAssertNil(credential.legacyDefaultTokenStorePath) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testDraftAndSenderLoginReachMissingClientRatherThanAccessModeMismatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for mode in [GmailGatewayCLIMode.reader, .draftGateway, .directSender] {
            let result = await GmailGatewayCLI(mode: mode, authPolicy: persistentPolicy(for: mode), secureCredentialStore: TestSecureCredentialStore())
                .runPersistent(arguments: ["auth", "login"], environment: defaultModeEnvironment(root))
            XCTAssertEqual(result.exitCode, 4, result.stderr)
            XCTAssertTrue(result.stderr.contains("OAuth application client"), result.stderr)
            XCTAssertTrue(result.stderr.contains("browser login cannot start"), result.stderr)
            XCTAssertFalse(result.stderr.contains("access mode does not match"), result.stderr)
        }
    }

    func testGraphQLResolverRetainsImplicitExecutableAccessMode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for mode in [GmailGatewayCLIMode.reader, .draftGateway, .mailboxThreads, .messageBox] {
            let result = await GmailGatewayGraphQLExecutor().run(
                query: "{ accounts { capabilities { configuredAccessMode } } }",
                mode: mode, environment: defaultModeEnvironment(root), configurationPolicy: .cliDefaults
            )
            let data = try JSONEncoder().encode(result)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let payload = try XCTUnwrap(object["data"] as? [String: Any])
            let accounts = try XCTUnwrap(payload["accounts"] as? [[String: Any]])
            let capabilities = try XCTUnwrap(accounts.first?["capabilities"] as? [String: Any])
            XCTAssertEqual(capabilities["configuredAccessMode"] as? String, mode.synthesizedAccessMode.graphQLValue)
        }
    }

    func testExplicitConfigurationKeepsItsAccessMode() async throws {
        let configURL = try makeVaultOnlyConfig(accessMode: .read)
        defer { try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent()) }
        let config = try GmailGatewayConfigLoader.loadConfig(configPath: configURL.path, environment: [:], synthesizedAccessMode: .readSend)
        XCTAssertEqual(config.credentials.first?.accessMode, .read)
        let result = await GmailGatewayCLI(mode: .draftGateway, authPolicy: persistentPolicy(for: .draftGateway), secureCredentialStore: TestSecureCredentialStore())
            .runPersistent(arguments: ["--config", configURL.path, "auth", "login"], environment: [:])
        XCTAssertTrue(result.stderr.contains("access mode does not match"), result.stderr)
    }

    func testImplicitReaderAndSendLoginsRetainIndependentVaultCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var environment = defaultModeEnvironment(root)
        let client = testClient()
        environment["GMAIL_GATEWAY_OAUTH_CLIENT_JSON"] = try client.legacyJSON()
        let store = TestSecureCredentialStore()
        for mode in [GmailGatewayCLIMode.reader, .draftGateway, .directSender] {
            let config = try GmailGatewayConfigLoader.loadConfig(environment: environment, synthesizedAccessMode: mode.synthesizedAccessMode)
            let accessMode = mode.synthesizedAccessMode
            let token = GmailOAuthTokenStore(accessMode: accessMode, accessToken: "token-" + mode.executableName,
                refreshToken: "refresh-token", tokenType: "Bearer", scope: gmailScopes(accessMode: accessMode).joined(separator: " "),
                expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)),
                emailAddress: "person@example.com", clientFingerprint: try gmailOAuthClientFingerprint(client))
            let coordinator = GmailAuthCoordinator(config: config, environment: environment, policy: persistentPolicy(for: mode), store: store,
                loginResult: { selected, _ in
                    XCTAssertEqual(selected.accessMode, accessMode)
                    return GmailOAuthLoginResult(tokenStore: token, redirectURI: "http://127.0.0.1:12345/oauth2callback")
                })
            _ = try await coordinator.login(credentialId: "gmail-personal", options: GmailOAuthLoginOptions(redirectURI: nil, openBrowser: false, timeoutSeconds: 1))
            let plainEnvironment = defaultModeEnvironment(root)
            let ordinaryConfig = try GmailGatewayConfigLoader.loadConfig(environment: plainEnvironment, synthesizedAccessMode: accessMode)
            let ordinaryCoordinator = GmailAuthCoordinator(config: ordinaryConfig, environment: plainEnvironment, policy: persistentPolicy(for: mode), store: store)
            let hydrated = try await ordinaryCoordinator.hydratedConfig()
            XCTAssertEqual(try validGmailAccessToken(credential: XCTUnwrap(hydrated.credentials.first), use: .read), token.accessToken)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ordinaryConfig.credentials[0].tokenStorePath))
        }
        let vault = GmailCredentialVault(store: store)
        let reader = try await vault.profile(credentialId: "gmail-personal", accessMode: .read)
        let sender = try await vault.profile(credentialId: "gmail-personal", accessMode: .readSend)
        XCTAssertEqual(reader?.token?.accessToken, "token-gmail-gateway-reader")
        XCTAssertEqual(sender?.token?.accessToken, "token-gmail-gateway-sender")
    }
}

private func defaultModeEnvironment(_ root: URL) -> [String: String] {
    ["XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
     "XDG_STATE_HOME": root.appendingPathComponent("state").path,
     "XDG_DATA_HOME": root.appendingPathComponent("data").path,
     "XDG_CACHE_HOME": root.appendingPathComponent("cache").path]
}
