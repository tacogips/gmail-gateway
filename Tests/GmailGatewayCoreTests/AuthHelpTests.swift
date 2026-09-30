import XCTest
@testable import GmailGatewayCore

final class AuthHelpTests: XCTestCase {
    func testBareAuthShowsHelpForEveryRoleWithoutLoadingConfiguration() {
        let modes: [GmailGatewayCLIMode] = [.reader, .draftGateway, .directSender, .mailboxThreads, .messageBox]
        for mode in modes {
            let result = GmailGatewayCLI(mode: mode).run(
                arguments: ["--config", "/missing/gmail-config.json", "auth"], environment: [:]
            )
            XCTAssertEqual(result.exitCode, 0, result.stderr)
            XCTAssertTrue(result.stdout.contains("auth login [--credential <id>]"))
            XCTAssertEqual(result.stderr, "")
        }
    }

    func testPersistentBareAuthShowsHelpBeforeLoadingConfigurationOrCredentials() async {
        for mode in [GmailGatewayCLIMode.reader, .draftGateway, .directSender] {
            let cli = GmailGatewayCLI(
                mode: mode, authPolicy: .persistent(requiredAccessMode: mode.synthesizedAccessMode),
                secureCredentialStore: TestSecureCredentialStore()
            )
            let result = await cli.runPersistent(
                arguments: ["--config", "/missing/gmail-config.json", "auth"], environment: [:]
            )
            XCTAssertEqual(result.exitCode, 0, result.stderr)
            XCTAssertTrue(result.stdout.contains("auth login [--credential <id>]"))
            XCTAssertEqual(result.stderr, "")
        }
    }
}
