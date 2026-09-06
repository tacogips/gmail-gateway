import Foundation
@testable import GmailGatewayCore
import XCTest

final class PersistentAuthCredentialBindingTests: XCTestCase {
    func testCurrentSchemaTokensCannotMoveBetweenSameScopeCredentials() async throws {
        let client = testClient()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let token = try credentialBoundToken(client: client, credentialId: "credential-a")

        for source in [TokenSource.file, .environment] {
            let credential = CredentialConfig(
                id: "credential-b",
                provider: .gmail,
                accessMode: .read,
                oauthClientSecretPath: "/unused-client",
                oauthClientSecretJSON: try client.legacyJSON(),
                tokenStorePath: root.appendingPathComponent("\(source.rawValue).json").path,
                tokenStoreJSON: source == .environment ? try tokenJSON(token) : nil,
                oauthClientSecretSource: .environmentJSON,
                tokenStoreSource: source == .environment ? .environmentJSON : .configuredPath
            )
            if source == .file {
                try JSONEncoder().encode(token).write(to: URL(fileURLWithPath: credential.tokenStorePath))
            }
            let config = bindingConfig(credential: credential)
            let loginSpy = CredentialBindingLoginSpy()
            let coordinator = GmailAuthCoordinator(
                config: config,
                environment: [:],
                policy: .persistent(requiredAccessMode: .read),
                store: TestSecureCredentialStore(),
                loginResult: { _, _ in
                    loginSpy.recordCall()
                    return GmailOAuthLoginResult(tokenStore: token, redirectURI: "http://127.0.0.1:1/oauth2callback")
                }
            )

            let status = try await coordinator.status(credentialId: credential.id)
            XCTAssertEqual(status["tokenState"] as? String, AuthState.invalid.rawValue, source.rawValue)
            await XCTAssertThrowsErrorAsync {
                _ = try await coordinator.hydratedConfig()
            }
            if source == .file {
                let before = try Data(contentsOf: URL(fileURLWithPath: credential.tokenStorePath))
                await XCTAssertThrowsErrorAsync {
                    _ = try await coordinator.login(
                        credentialId: credential.id,
                        options: GmailOAuthLoginOptions(openBrowser: false)
                    )
                }
                await XCTAssertThrowsErrorAsync {
                    _ = try await coordinator.revoke(
                        credentialId: credential.id,
                        confirmedCredentialId: credential.id
                    )
                }
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: credential.tokenStorePath)), before)
                XCTAssertEqual(loginSpy.callCount(), 0)
            }
        }
    }
}

private enum TokenSource: String {
    case file
    case environment
}

private func credentialBoundToken(
    client: GmailOAuthClientRecord,
    credentialId: String
) throws -> GmailOAuthTokenStore {
    GmailOAuthTokenStore(
        accessMode: .read,
        accessToken: "credential-a-access-token",
        refreshToken: "credential-a-refresh-token",
        tokenType: "Bearer",
        scope: gmailScopes(accessMode: .read).joined(separator: " "),
        expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60)),
        emailAddress: nil,
        clientFingerprint: try gmailOAuthClientFingerprint(client),
        schemaVersion: 1,
        provider: .gmail,
        credentialId: credentialId
    )
}

private func tokenJSON(_ token: GmailOAuthTokenStore) throws -> String {
    try XCTUnwrap(String(data: JSONEncoder().encode(token), encoding: .utf8))
}

private func bindingConfig(credential: CredentialConfig) -> GmailGatewayConfig {
    GmailGatewayConfig(
        configPath: "/unused-config",
        storage: StorageConfig(cacheDir: "/tmp", attachmentDir: "/tmp", allowedSendAttachmentRoots: []),
        credentials: [credential],
        accounts: [AccountConfig(
            id: "fallback",
            provider: .gmail,
            emailAddress: "fallback@example.invalid",
            credentialId: credential.id,
            defaultLabelIds: [],
            isFallback: true
        )]
    )
}

private final class CredentialBindingLoginSpy: @unchecked Sendable {
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
