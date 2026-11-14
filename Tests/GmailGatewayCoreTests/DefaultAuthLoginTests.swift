import Foundation
@testable import GmailGatewayCore
import XCTest

final class DefaultAuthLoginTests: XCTestCase {
    func testPersistentLoginDefaultsCredentialWithoutOpeningBrowserWhenClientMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = GmailGatewayCLI(
            mode: .reader,
            authPolicy: .persistent(requiredAccessMode: .read),
            secureCredentialStore: TestSecureCredentialStore()
        )
        let result = await cli.runPersistent(
            arguments: ["auth", "login"],
            environment: ["HOME": root.path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
                          "XDG_STATE_HOME": root.appendingPathComponent("state").path]
        )
        XCTAssertEqual(result.exitCode, 4, result.stderr)
        XCTAssertTrue(result.stderr.contains("AUTH_REQUIRED"), result.stderr)
        XCTAssertTrue(result.stderr.contains("gmail-personal"), result.stderr)
        XCTAssertFalse(result.stderr.contains("auth commands require --credential"), result.stderr)
    }

    func testStatusDefaultsCredentialAndRevokeRequiresExplicitCredential() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = GmailGatewayCLI(
            mode: .reader,
            authPolicy: .persistent(requiredAccessMode: .read),
            secureCredentialStore: TestSecureCredentialStore()
        )
        for command in ["status", "revoke"] {
            let result = await cli.runPersistent(
                arguments: ["auth", command],
                environment: ["HOME": root.path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
                              "XDG_STATE_HOME": root.appendingPathComponent("state").path]
            )
            if command == "status" {
                XCTAssertEqual(result.exitCode, 0, result.stderr)
                XCTAssertTrue(result.stdout.contains("gmail-personal"), result.stdout)
            } else {
                XCTAssertEqual(result.exitCode, 2, result.stderr)
                XCTAssertTrue(result.stderr.contains("auth commands require --credential"), result.stderr)
            }
        }
    }
    func testPersistentCatalogCommandsDoNotRequireCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = GmailGatewayCLI(mode: .draftGateway, authPolicy: .persistent(requiredAccessMode: .readSend),
            secureCredentialStore: TestSecureCredentialStore())
        let environment = ["HOME": root.path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "XDG_STATE_HOME": root.appendingPathComponent("state").path]
        let schema = await cli.runPersistent(arguments: ["graphql", "schema"], environment: environment)
        XCTAssertEqual(schema.exitCode, 0, schema.stderr)
        XCTAssertTrue(schema.stdout.contains("drafts"), schema.stdout)
        let search = await cli.runPersistent(arguments: ["graphql", "search", "^drafts$", "--kinds", "query"], environment: environment)
        XCTAssertEqual(search.exitCode, 0, search.stderr)
        XCTAssertTrue(search.stdout.contains("drafts"), search.stdout)
        let operation = await cli.runPersistent(arguments: ["graphql", "operation", "unknown-operation"], environment: environment)
        XCTAssertNotEqual(operation.exitCode, 0)
        XCTAssertFalse(operation.stderr.contains("Exactly one of --query"), operation.stderr)
    }

}
