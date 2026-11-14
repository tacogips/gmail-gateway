import Foundation
@testable import GmailGatewayCore
import XCTest

final class PersistentAuthLifecycleCoherenceTests: XCTestCase {
    func testMismatchedFileFingerprintBlocksLoginAndRevokeBeforeMutation() async throws {
        let sources: [GmailCredentialSourceKind] = [
            .environmentPath, .configuredPath, .relocatedPath, .synthesizedDefault
        ]
        TestGmailRequestCaptureProtocol.reset()
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }

        for source in sources {
            let fixture = try await LifecycleCoherenceFixture(source: source)
            defer { fixture.remove() }
            let before = try Data(contentsOf: fixture.tokenURL)
            let writesBefore = await fixture.store.dataWriteCount()

            do {
                _ = try await fixture.coordinator.login(
                    credentialId: fixture.credential.id,
                    options: GmailOAuthLoginOptions(openBrowser: false)
                )
                XCTFail("Expected \(source.rawValue) login to reject a mismatched token")
            } catch let error as GmailGatewayError {
                XCTAssertEqual(error.code, .authRequired, source.rawValue)
                XCTAssertEqual(error.exitCode, .authenticationBootstrapError, source.rawValue)
            }
            XCTAssertEqual(try Data(contentsOf: fixture.tokenURL), before, source.rawValue)
            XCTAssertEqual(fixture.loginSpy.callCount(), 0, source.rawValue)
            let writesAfterLogin = await fixture.store.dataWriteCount()
            XCTAssertEqual(writesAfterLogin, writesBefore, source.rawValue)

            do {
                _ = try await fixture.coordinator.revoke(
                    credentialId: fixture.credential.id,
                    confirmedCredentialId: fixture.credential.id
                )
                XCTFail("Expected \(source.rawValue) revoke to reject a mismatched token")
            } catch let error as GmailGatewayError {
                XCTAssertEqual(error.code, .authRequired, source.rawValue)
                XCTAssertEqual(error.exitCode, .authenticationBootstrapError, source.rawValue)
            }
            XCTAssertEqual(try Data(contentsOf: fixture.tokenURL), before, source.rawValue)
            XCTAssertEqual(fixture.loginSpy.callCount(), 0, source.rawValue)
            let writesAfterRevoke = await fixture.store.dataWriteCount()
            XCTAssertEqual(writesAfterRevoke, writesBefore, source.rawValue)
            XCTAssertTrue(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty, source.rawValue)
        }
    }

    func testMismatchedHigherPriorityClientBlocksVaultRevokeBeforeMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vaultClient = testClient()
        let selectedClient = GmailOAuthClientRecord(
            kind: "installed",
            clientId: "different-client-id.apps.googleusercontent.com",
            clientSecret: "different-client-secret",
            projectId: "different-project",
            authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenEndpoint: "https://oauth2.googleapis.com/token",
            redirectURIs: ["http://127.0.0.1:8080/oauth2callback"]
        )
        let vaultToken = try coherentToken(client: vaultClient)
        let credential = CredentialConfig(
            id: "gmail-personal",
            provider: .gmail,
            accessMode: .read,
            oauthClientSecretPath: root.appendingPathComponent("client.json").path,
            oauthClientSecretJSON: try selectedClient.legacyJSON(),
            tokenStorePath: root.appendingPathComponent("token.json").path,
            tokenStoreJSON: nil,
            oauthClientSecretSource: .environmentJSON,
            tokenStoreSource: .synthesizedDefault
        )
        let config = GmailGatewayConfig(
            configPath: root.appendingPathComponent("config.toml").path,
            storage: StorageConfig(cacheDir: root.path, attachmentDir: root.path, allowedSendAttachmentRoots: []),
            credentials: [credential],
            accounts: [AccountConfig(
                id: "personal", provider: .gmail, emailAddress: "person@example.invalid",
                credentialId: credential.id, defaultLabelIds: [], isFallback: true
            )]
        )
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: vaultClient, token: vaultToken))
        let writesBefore = await store.dataWriteCount()
        let coordinator = GmailAuthCoordinator(
            config: config,
            environment: [:],
            policy: .persistent(requiredAccessMode: .read),
            store: store
        )

        do {
            _ = try await coordinator.revoke(
                credentialId: credential.id,
                confirmedCredentialId: credential.id
            )
            XCTFail("Expected revoke to reject the mismatched selected OAuth client")
        } catch let error as GmailGatewayError {
            XCTAssertEqual(error.code, .authRequired)
            XCTAssertEqual(error.exitCode, .authenticationBootstrapError)
        }

        let retainedProfile = try await vault.profile(credentialId: credential.id, accessMode: credential.accessMode)
        XCTAssertEqual(retainedProfile?.token?.accessToken, vaultToken.accessToken)
        let writesAfter = await store.dataWriteCount()
        XCTAssertEqual(writesAfter, writesBefore)
    }
}

private struct LifecycleCoherenceFixture {
    let root: URL
    let credential: CredentialConfig
    let tokenURL: URL
    let coordinator: GmailAuthCoordinator
    let loginSpy: LifecycleLoginSpy
    let store: TestSecureCredentialStore

    init(source: GmailCredentialSourceKind) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tokenURL = root.appendingPathComponent("token.json")
        let client = testClient()
        let mismatchedToken = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "other-client-access-token",
            refreshToken: "other-client-refresh-token",
            tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "),
            expiresAt: nil,
            emailAddress: nil,
            clientFingerprint: "other-client-fingerprint"
        )
        try JSONEncoder().encode(mismatchedToken).write(to: tokenURL)
        credential = CredentialConfig(
            id: "gmail-personal",
            provider: .gmail,
            accessMode: .read,
            oauthClientSecretPath: root.appendingPathComponent("client.json").path,
            oauthClientSecretJSON: try client.legacyJSON(),
            tokenStorePath: tokenURL.path,
            tokenStoreJSON: nil,
            oauthClientSecretSource: .environmentJSON,
            tokenStoreSource: source
        )
        let config = GmailGatewayConfig(
            configPath: root.appendingPathComponent("config.toml").path,
            storage: StorageConfig(cacheDir: root.path, attachmentDir: root.path, allowedSendAttachmentRoots: []),
            credentials: [credential],
            accounts: [AccountConfig(
                id: "personal", provider: .gmail, emailAddress: "person@example.invalid",
                credentialId: credential.id, defaultLabelIds: [], isFallback: true
            )]
        )
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        let lowerPriorityToken = source == .synthesizedDefault ? nil : try coherentToken(client: client)
        try await vault.replaceProfile(testProfile(client: client, token: lowerPriorityToken))
        self.store = store
        let spy = LifecycleLoginSpy()
        loginSpy = spy
        coordinator = GmailAuthCoordinator(
            config: config,
            environment: [:],
            policy: .persistent(requiredAccessMode: .read),
            store: store,
            loginResult: { _, _ in
                spy.recordCall()
                throw LifecycleLoginSpy.UnexpectedCall.error
            }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class LifecycleLoginSpy: @unchecked Sendable {
    enum UnexpectedCall: Error {
        case error
    }

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
