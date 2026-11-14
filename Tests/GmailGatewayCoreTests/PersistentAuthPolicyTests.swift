@testable import GmailGatewayCore
import XCTest

final class PersistentAuthPolicyTests: XCTestCase {
    func testReaderRequiresExactlyRead() throws {
        let credential = CredentialConfig(
            id: "gmail-personal",
            provider: .gmail,
            accessMode: .readSend,
            oauthClientSecretPath: "unused",
            oauthClientSecretJSON: nil,
            tokenStorePath: "unused",
            tokenStoreJSON: nil
        )
        XCTAssertThrowsError(try validatePersistentCredential(credential, policy: .persistent(requiredAccessMode: .read)))
    }

    func testTargetAndExcludedPoliciesAreFixed() {
        XCTAssertEqual(persistentPolicy(for: .reader).requiredAccessMode, .read)
        XCTAssertEqual(persistentPolicy(for: .directSender).requiredAccessMode, .readSend)
        XCTAssertNil(persistentPolicy(for: .mailboxThreads).requiredAccessMode)
        XCTAssertNil(persistentPolicy(for: .messageBox).requiredAccessMode)
    }

    func testExcludedModesDoNotAdvertiseSetup() {
        let result = GmailGatewayCLI(mode: .mailboxThreads).run(arguments: ["--help"], environment: [:])
        XCTAssertFalse(result.stdout.contains("auth <setup|"))
        XCTAssertFalse(result.stdout.contains("Persistent auth setup"))
    }
}
