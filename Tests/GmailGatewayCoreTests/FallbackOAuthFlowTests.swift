import Foundation
@testable import GmailGatewayCore
import XCTest

final class FallbackOAuthFlowTests: XCTestCase {
    func testEnvironmentPathOverridesExplicitConfigAndExplainsScopeMismatch() async throws {
        let configURL = try makeVaultOnlyConfig(accessMode: .read)
        let root = configURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try String(contentsOf: configURL, encoding: .utf8)
        try source.replacingOccurrences(
            of: "[[accounts]]", with: "token_store_path = \"configured.json\"\n\n[[accounts]]"
        ).write(to: configURL, atomically: true, encoding: .utf8)
        let client = testClient()
        let token = GmailOAuthTokenStore(
            accessMode: .readSend, accessToken: "scope-secret", refreshToken: "scope-refresh",
            tokenType: "Bearer", scope: gmailScopes(accessMode: .readSend).joined(separator: " "),
            expiresAt: nil, emailAddress: "person@example.com", clientFingerprint: try gmailOAuthClientFingerprint(client),
            schemaVersion: 1, provider: .gmail, credentialId: "gmail-personal"
        )
        let selectedPath = root.appendingPathComponent("override.json").path
        try writeGmailOAuthTokenStore(token, to: selectedPath, errorMessage: "fixture", exitCode: .authenticationBootstrapError)
        let variable = GmailGatewayConfigLoader.getCredentialPathEnvVarName(credentialId: "gmail-personal", pathKey: "token_store_path")
        let environment = [
            variable: selectedPath,
            GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
                credentialId: "gmail-personal", valueKey: "oauth_client_secret_json"
            ): try client.legacyJSON()
        ]
        let cli = GmailGatewayCLI(mode: .reader, authPolicy: .persistent(requiredAccessMode: .read), secureCredentialStore: TestSecureCredentialStore())
        let result = await cli.runPersistent(
            arguments: ["--config", configURL.path, "auth", "login", "--credential", "gmail-personal"], environment: environment
        )
        XCTAssertTrue(result.stderr.contains("SCOPE_MISMATCH"), result.stderr)
        XCTAssertTrue(result.stderr.contains(variable), result.stderr)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: Any])
        let error = try XCTUnwrap(payload["error"] as? [String: Any])
        let details = try XCTUnwrap(error["details"] as? [String: String])
        XCTAssertEqual(details["tokenStorePath"], selectedPath)
        XCTAssertEqual(details["tokenSource"], GmailCredentialSourceKind.environmentPath.rawValue)
        XCTAssertFalse(result.stderr.contains("scope-secret"))
    }

    func testFallbackLoginThenThreadsWithStaleOverrides() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = testClient()
        let jsonVariable = GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
            credentialId: "gmail-personal", valueKey: "token_store_json"
        )
        let pathVariable = GmailGatewayConfigLoader.getCredentialPathEnvVarName(
            credentialId: "gmail-personal", pathKey: "token_store_path"
        )
        let stale = GmailOAuthTokenStore(
            accessMode: .read, accessToken: "stale-secret", refreshToken: "stale-refresh",
            tokenType: "Bearer", scope: nil, expiresAt: nil, emailAddress: nil, clientFingerprint: nil
        )
        var environment = [
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "XDG_DATA_HOME": root.appendingPathComponent("data").path,
            "XDG_CACHE_HOME": root.appendingPathComponent("cache").path,
            GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
                credentialId: "gmail-personal", valueKey: "oauth_client_secret_json"
            ): try client.legacyJSON(),
            jsonVariable: try XCTUnwrap(String(bytes: JSONEncoder().encode(stale), encoding: .utf8)),
            pathVariable: root.appendingPathComponent("old.json").path
        ]
        let store = TestSecureCredentialStore()
        let cli = GmailGatewayCLI(mode: .reader, authPolicy: .persistent(requiredAccessMode: .read), secureCredentialStore: store)
        let query = ["graphql", "--query", #"{ threads(input: { accountId: "personal" }) { totalCount } }"#]
        let validation = await cli.runPersistent(arguments: ["config", "validate"], environment: environment)
        XCTAssertEqual(validation.exitCode, 0, validation.stderr)
        let rejected = await cli.runPersistent(arguments: query, environment: environment)
        XCTAssertTrue(rejected.stdout.contains("AUTH_REQUIRED"), rejected.stdout)
        XCTAssertTrue(rejected.stdout.contains(jsonVariable), rejected.stdout)
        XCTAssertFalse(rejected.stdout.contains("stale-secret"))
        let immutable = await cli.runPersistent(arguments: ["auth", "login", "--credential", "gmail-personal"], environment: environment)
        XCTAssertTrue(immutable.stderr.contains(jsonVariable), immutable.stderr)
        XCTAssertTrue(immutable.stderr.contains(pathVariable), immutable.stderr)

        environment.removeValue(forKey: jsonVariable)
        let selectedPath = root.appendingPathComponent("new.json").path
        environment[pathVariable] = selectedPath
        let config = try GmailGatewayConfigLoader.loadConfig(environment: environment)
        let token = try coherentToken(client: client)
        let coordinator = GmailAuthCoordinator(
            config: config, environment: environment, policy: .persistent(requiredAccessMode: .read), store: store,
            loginResult: { _, _ in GmailOAuthLoginResult(tokenStore: token, redirectURI: "http://127.0.0.1:1/oauth2callback") }
        )
        let login = try await coordinator.login(credentialId: "gmail-personal", options: GmailOAuthLoginOptions(openBrowser: false))
        XCTAssertEqual(login["tokenStorePath"] as? String, selectedPath)
        XCTAssertEqual(login["tokenSource"] as? String, GmailCredentialSourceKind.environmentPath.rawValue)
        XCTAssertTrue((login["tokenSourceHint"] as? String)?.contains(pathVariable) == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.configPath))

        TestGmailRequestCaptureProtocol.reset()
        TestGmailRequestCaptureProtocol.responseData = Data(#"{"threads":[],"resultSizeEstimate":0}"#.utf8)
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }
        let result = await cli.runPersistent(arguments: query, environment: environment)
        XCTAssertEqual(result.exitCode, 0, result.stdout + result.stderr)
        XCTAssertTrue(result.stdout.contains("totalCount"), result.stdout)
        XCTAssertFalse(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty)

        let explicitMissing = await cli.runPersistent(arguments: ["--config", config.configPath] + query, environment: environment)
        XCTAssertTrue(explicitMissing.stderr.contains("CONFIG_INVALID"), explicitMissing.stderr)
    }
}
