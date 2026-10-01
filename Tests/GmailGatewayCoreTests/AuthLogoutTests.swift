import Foundation
import GoogleServiceGatewayCore
@testable import GmailGatewayCore
import XCTest

final class AuthLogoutTests: XCTestCase {
    func testPersistentLogoutClearsVaultAndFileAndPreservesClient() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("token.json").path
        let client = testClient()
        let token = try coherentToken(client: client)
        try writeGmailOAuthTokenStore(token, to: path, errorMessage: "fixture failed", exitCode: .authenticationBootstrapError)
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: token))
        let coordinator = GmailAuthCoordinator(config: try persistentConfiguredTokenPathConfig(tokenPath: path),
            environment: [:], policy: .persistent(requiredAccessMode: .read), store: store)
        let first = try await coordinator.logout(credentialId: "gmail-personal")
        XCTAssertEqual(first["state"] as? String, "LOGGED_OUT")
        XCTAssertEqual(first["localTokenDeleted"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let saved = try await vault.profile(credentialId: "gmail-personal", accessMode: .read)
        XCTAssertEqual(saved?.client, client)
        XCTAssertNil(saved?.token)
        let second = try await coordinator.logout(credentialId: "gmail-personal")
        XCTAssertEqual(second["localTokenDeleted"] as? Bool, false)
    }

    func testEveryModeAcceptsDefaultLogoutAndPreservesExternalInputs() async throws {
        let roles: [(GmailGatewayCLIMode, AccessMode)] = [(.reader, .read), (.draftGateway, .readSend),
            (.directSender, .readSend), (.mailboxThreads, .readModify), (.messageBox, .full)]
        for (mode, access) in roles {
            let config = try makeVaultOnlyConfig(accessMode: access)
            defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
            let path = config.deletingLastPathComponent().appendingPathComponent("external.json")
            let original = Data("external-fixture".utf8)
            try original.write(to: path)
            for environment in [
                ["GMAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_TOKEN_STORE_PATH": path.path],
                ["GMAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_TOKEN_STORE_JSON": "external-inline-fixture"],
                ["GMAIL_GATEWAY_ACCESS_TOKEN": "external-direct-fixture"]
            ] {
                let cli = GmailGatewayCLI(mode: mode, secureCredentialStore: TestSecureCredentialStore())
                let result: GmailGatewayCommandResult
                switch mode {
                case .reader, .draftGateway, .directSender:
                    result = await cli.runPersistent(arguments: ["auth", "logout", "--config", config.path], environment: environment)
                case .mailboxThreads, .messageBox:
                    result = cli.run(arguments: ["auth", "logout", "--config", config.path], environment: environment)
                }
                XCTAssertEqual(result.exitCode, 0, result.stdout + result.stderr)
                XCTAssertTrue(result.stdout.contains("EXTERNAL_CREDENTIAL_PRESERVED"), result.stdout)
                XCTAssertEqual(try Data(contentsOf: path), original)
                XCTAssertFalse(result.stdout.contains("external-inline-fixture"))
                XCTAssertFalse(result.stdout.contains("external-direct-fixture"))
            }
        }
    }
}
