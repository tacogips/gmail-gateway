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

    func testStatusAndRevokeStillRequireExplicitCredential() async throws {
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
            XCTAssertEqual(result.exitCode, 2, result.stderr)
            XCTAssertTrue(result.stderr.contains("auth commands require --credential"), result.stderr)
        }
    }
}
