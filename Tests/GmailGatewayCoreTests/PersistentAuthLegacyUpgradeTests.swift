import Foundation
@testable import GmailGatewayCore
import XCTest

final class PersistentAuthLegacyUpgradeTests: XCTestCase {
    func testLegacyMetadataRequiresReloginAndUpgradesSelectedFileInPlace() async throws {
        let sources: [GmailCredentialSourceKind] = [
            .environmentPath, .configuredPath, .relocatedPath, .synthesizedDefault
        ]
        let omissions: [LegacyMetadataOmission] = [.scope, .fingerprint, .both]
        TestGmailRequestCaptureProtocol.reset()
        TestGmailRequestCaptureProtocol.profileResponseData = Data(#"{"emailAddress":"person@example.invalid"}"#.utf8)
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }

        for source in sources {
            for omission in omissions {
                let fixture = try LegacyUpgradeFixture(source: source, omission: omission)
                defer { fixture.remove() }
                let before = try Data(contentsOf: fixture.tokenURL)

                let initialStatus = try await fixture.coordinator.status(credentialId: fixture.credential.id)
                XCTAssertEqual(initialStatus["tokenState"] as? String, AuthState.unknown.rawValue, fixture.label)
                do {
                    _ = try await fixture.coordinator.hydratedConfig()
                    XCTFail("Expected \(fixture.label) to require re-login")
                } catch let error as GmailGatewayError {
                    XCTAssertEqual(error.code, .authRequired, fixture.label)
                    XCTAssertEqual(error.exitCode, .graphqlExecutionError, fixture.label)
                }
                XCTAssertEqual(try Data(contentsOf: fixture.tokenURL), before, fixture.label)
                XCTAssertEqual(fixture.loginSpy.callCount(), 0, fixture.label)
                XCTAssertTrue(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty, fixture.label)

                let login = try await fixture.coordinator.login(
                    credentialId: fixture.credential.id,
                    options: GmailOAuthLoginOptions(openBrowser: false)
                )
                let upgraded = try JSONDecoder().decode(
                    GmailOAuthTokenStore.self,
                    from: Data(contentsOf: fixture.tokenURL)
                )
                XCTAssertEqual(login["persistenceBackend"] as? String, "FILE", fixture.label)
                XCTAssertEqual(fixture.loginSpy.callCount(), 1, fixture.label)
                XCTAssertEqual(upgraded.scope, gmailScopes(accessMode: .read).joined(separator: " "), fixture.label)
                XCTAssertEqual(upgraded.clientFingerprint, try gmailOAuthClientFingerprint(fixture.client), fixture.label)

                let upgradedStatus = try await fixture.coordinator.status(credentialId: fixture.credential.id)
                XCTAssertEqual(upgradedStatus["tokenState"] as? String, AuthState.ready.rawValue, fixture.label)
                let hydrated = try await fixture.coordinator.hydratedConfig()
                _ = try GmailGatewayService(config: hydrated).getProfile(accountId: "personal")
                XCTAssertEqual(TestGmailRequestCaptureProtocol.capturedURLs.last?.host, "gmail.googleapis.com", fixture.label)
                TestGmailRequestCaptureProtocol.reset()
            }
        }
    }

    func testInlineLegacyTokenRemainsImmutableWithRemovalGuidance() async throws {
        let client = testClient()
        let token = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "legacy-access-token",
            refreshToken: "legacy-refresh-token",
            tokenType: "Bearer",
            scope: nil,
            expiresAt: nil,
            emailAddress: nil,
            clientFingerprint: nil
        )
        let credential = CredentialConfig(
            id: "gmail-personal", provider: .gmail, accessMode: .read,
            oauthClientSecretPath: "/unused-client", oauthClientSecretJSON: try client.legacyJSON(),
            tokenStorePath: "/unused-token", tokenStoreJSON: try legacyTokenJSON(token),
            oauthClientSecretSource: .environmentJSON, tokenStoreSource: .environmentJSON
        )
        let config = legacyUpgradeConfig(credential: credential, root: "/tmp")
        let coordinator = GmailAuthCoordinator(
            config: config,
            environment: [:],
            policy: .persistent(requiredAccessMode: .read),
            store: TestSecureCredentialStore()
        )

        let status = try await coordinator.status(credentialId: credential.id)
        XCTAssertEqual(status["tokenState"] as? String, AuthState.unknown.rawValue)
        do {
            _ = try await coordinator.login(credentialId: credential.id, options: GmailOAuthLoginOptions(openBrowser: false))
            XCTFail("Expected inline token login to be rejected")
        } catch let error as GmailGatewayError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertTrue(error.message.contains("remove the environment override"))
        }
    }
}

private enum LegacyMetadataOmission: CaseIterable {
    case scope
    case fingerprint
    case both
}

private struct LegacyUpgradeFixture {
    let root: URL
    let credential: CredentialConfig
    let tokenURL: URL
    let client: GmailOAuthClientRecord
    let coordinator: GmailAuthCoordinator
    let loginSpy: LegacyUpgradeLoginSpy
    let label: String

    init(source: GmailCredentialSourceKind, omission: LegacyMetadataOmission) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tokenURL = root.appendingPathComponent("token.json")
        client = testClient()
        let includeScope = omission != .scope && omission != .both
        let includeFingerprint = omission != .fingerprint && omission != .both
        let token = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "legacy-access-token",
            refreshToken: "legacy-refresh-token",
            tokenType: "Bearer",
            scope: includeScope ? gmailScopes(accessMode: .read).joined(separator: " ") : nil,
            expiresAt: nil,
            emailAddress: nil,
            clientFingerprint: includeFingerprint ? try gmailOAuthClientFingerprint(client) : nil
        )
        try JSONEncoder().encode(token).write(to: tokenURL)
        credential = CredentialConfig(
            id: "gmail-personal", provider: .gmail, accessMode: .read,
            oauthClientSecretPath: root.appendingPathComponent("client.json").path,
            oauthClientSecretJSON: try client.legacyJSON(),
            tokenStorePath: tokenURL.path, tokenStoreJSON: nil,
            oauthClientSecretSource: .environmentJSON, tokenStoreSource: source
        )
        let spy = LegacyUpgradeLoginSpy()
        loginSpy = spy
        let upgradedLoginToken = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "upgraded-access-token",
            refreshToken: "upgraded-refresh-token",
            tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "),
            expiresAt: nil,
            emailAddress: nil,
            clientFingerprint: nil
        )
        coordinator = GmailAuthCoordinator(
            config: legacyUpgradeConfig(credential: credential, root: root.path),
            environment: [:],
            policy: .persistent(requiredAccessMode: .read),
            store: TestSecureCredentialStore(),
            loginResult: { _, _ in
                spy.recordCall()
                return GmailOAuthLoginResult(
                    tokenStore: upgradedLoginToken,
                    redirectURI: "http://127.0.0.1:1/oauth2callback"
                )
            }
        )
        label = "\(source.rawValue)-\(String(describing: omission))"
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func legacyUpgradeConfig(credential: CredentialConfig, root: String) -> GmailGatewayConfig {
    GmailGatewayConfig(
        configPath: "\(root)/config.toml",
        storage: StorageConfig(cacheDir: root, attachmentDir: root, allowedSendAttachmentRoots: []),
        credentials: [credential],
        accounts: [AccountConfig(
            id: "personal", provider: .gmail, emailAddress: "person@example.invalid",
            credentialId: credential.id, defaultLabelIds: [], isFallback: true
        )]
    )
}

private func legacyTokenJSON(_ token: GmailOAuthTokenStore) throws -> String {
    try XCTUnwrap(String(data: JSONEncoder().encode(token), encoding: .utf8))
}

private final class LegacyUpgradeLoginSpy: @unchecked Sendable {
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
