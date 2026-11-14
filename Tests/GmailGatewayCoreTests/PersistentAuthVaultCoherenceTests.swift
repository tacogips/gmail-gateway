@testable import GmailGatewayCore
import XCTest

final class PersistentAuthVaultCoherenceTests: XCTestCase {
    func testReplaceProfileRejectsModeScopeAndFingerprintMismatchesBeforeStoreWrite() async throws {
        let client = testClient()
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        let incoherent = GmailOAuthTokenStore(
            accessMode: .readSend,
            accessToken: "access-token",
            refreshToken: "refresh-token",
            tokenType: "Bearer",
            scope: "unexpected-scope",
            expiresAt: nil,
            emailAddress: nil,
            clientFingerprint: "unexpected-fingerprint"
        )
        let writesBefore = await store.dataWriteCount()

        await XCTAssertThrowsErrorAsync {
            try await vault.replaceProfile(testProfile(client: client, token: incoherent))
        }

        let writesAfter = await store.dataWriteCount()
        XCTAssertEqual(writesAfter, writesBefore)
    }
}
