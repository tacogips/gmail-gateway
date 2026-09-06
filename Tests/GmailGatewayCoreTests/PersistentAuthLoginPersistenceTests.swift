import Foundation
@testable import GmailGatewayCore
import XCTest

final class PersistentAuthLoginPersistenceTests: XCTestCase {
    func testCoordinatorLoginValidatesBeforeWritingSelectedVaultDestination() async throws {
        let client = testClient()
        let config = persistentConfig(tokenPath: "/unused", fallback: true)
        let existing = try coherentToken(client: client)
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: existing))
        let invalidToken = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "replacement-access-token",
            refreshToken: "replacement-refresh-token",
            tokenType: "Bearer",
            scope: "https://www.googleapis.com/auth/gmail.send",
            expiresAt: nil,
            emailAddress: nil,
            clientFingerprint: nil
        )
        let coordinator = GmailAuthCoordinator(
            config: config,
            environment: [:],
            policy: .persistent(requiredAccessMode: .read),
            store: store,
            loginResult: { _, _ in GmailOAuthLoginResult(tokenStore: invalidToken, redirectURI: "http://127.0.0.1:1/oauth2callback") }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.login(credentialId: "gmail-personal", options: GmailOAuthLoginOptions(openBrowser: false))
        }
        let retained = try await vault.profile(credentialId: "gmail-personal", accessMode: .read)

        XCTAssertEqual(retained?.token?.accessToken, existing.accessToken)
    }

    func testCoordinatorLoginWritesSelectedFileDestination() async throws {
        let client = testClient()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let path = directory.appendingPathComponent("token.json").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try persistentConfiguredTokenPathConfig(tokenPath: path)
        let token = try coherentToken(client: client)
        let coordinator = GmailAuthCoordinator(
            config: config,
            environment: [:],
            policy: .persistent(requiredAccessMode: .read),
            store: TestSecureCredentialStore(),
            loginResult: { _, _ in GmailOAuthLoginResult(tokenStore: token, redirectURI: "http://127.0.0.1:1/oauth2callback") }
        )

        let output = try await coordinator.login(credentialId: "gmail-personal", options: GmailOAuthLoginOptions(openBrowser: false))
        let persisted = try JSONDecoder().decode(GmailOAuthTokenStore.self, from: Data(contentsOf: URL(fileURLWithPath: path)))

        XCTAssertEqual(output["persistenceBackend"] as? String, "FILE")
        XCTAssertEqual(persisted.accessToken, token.accessToken)
        XCTAssertEqual(persisted.clientFingerprint, try gmailOAuthClientFingerprint(client))
    }
    func testSelectedVaultAndFileDestinationsPersistValidatedLoginTokens() async throws {
        let client = testClient()
        let config = persistentConfig(tokenPath: "/unused", fallback: true)
        let loginToken = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "access-token",
            refreshToken: "refresh-token",
            tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "),
            expiresAt: nil,
            emailAddress: nil,
            clientFingerprint: nil
        )
        let token = try validatedPersistentLoginToken(
            loginToken,
            credential: config.credentials[0],
            client: client,
            accounts: config.accounts
        )
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        let coordinator = GmailAuthCoordinator(
            config: config,
            environment: [:],
            policy: .persistent(requiredAccessMode: .read),
            store: store
        )
        let envelope = testProfile(client: client, token: nil)
        try await coordinator.persistPersistentToken(token, destination: .vault(envelope))
        let storedToken = try await vault.profile(credentialId: "gmail-personal", accessMode: .read)?.token
        XCTAssertEqual(storedToken?.accessToken, "access-token")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let path = directory.appendingPathComponent("token.json").path
        defer { try? FileManager.default.removeItem(at: directory) }
        try await coordinator.persistPersistentToken(token, destination: .file(path, .absent))
        let fileToken = try JSONDecoder().decode(GmailOAuthTokenStore.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(fileToken.clientFingerprint, try gmailOAuthClientFingerprint(client))
    }

    func testRejectedVaultLoginPersistencePreservesExistingToken() async throws {
        let client = testClient()
        let config = persistentConfig(tokenPath: "/unused", fallback: true)
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        let existing = try coherentToken(client: client)
        let envelope = testProfile(client: client, token: existing)
        try await vault.replaceProfile(envelope)
        let coordinator = GmailAuthCoordinator(
            config: config,
            environment: [:],
            policy: .persistent(requiredAccessMode: .read),
            store: store
        )
        let incoherent = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "replacement-access-token",
            refreshToken: "replacement-refresh-token",
            tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "),
            expiresAt: nil,
            emailAddress: nil,
            clientFingerprint: "wrong-client"
        )

        await XCTAssertThrowsErrorAsync {
            try await coordinator.persistPersistentToken(incoherent, destination: .vault(envelope))
        }

        let retained = try await vault.profile(credentialId: "gmail-personal", accessMode: .read)
        XCTAssertEqual(retained?.token?.accessToken, existing.accessToken)
    }
}

func persistentConfiguredTokenPathConfig(tokenPath: String) throws -> GmailGatewayConfig {
    let credential = CredentialConfig(
        id: "gmail-personal",
        provider: .gmail,
        accessMode: .read,
        oauthClientSecretPath: "/not-used-client",
        oauthClientSecretJSON: try testClient().legacyJSON(),
        tokenStorePath: tokenPath,
        tokenStoreJSON: nil,
        oauthClientSecretSource: .environmentJSON,
        tokenStoreSource: .configuredPath
    )
    return GmailGatewayConfig(
        configPath: "/not-used-config",
        storage: StorageConfig(cacheDir: "/tmp", attachmentDir: "/tmp", allowedSendAttachmentRoots: []),
        credentials: [credential],
        accounts: [AccountConfig(id: "personal", provider: .gmail, emailAddress: "personal@example.invalid", credentialId: credential.id, defaultLabelIds: [], isFallback: true)]
    )
}
