import Foundation
import GoogleServiceGatewayCore
@testable import GmailGatewayCore
import XCTest

final class PersistentAuthVaultTests: XCTestCase {
    func testReplaceAndClearTokenPreservesClient() async throws {
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        let client = testClient()
        let profile = GmailCredentialProfileEnvelope(
            schemaVersion: 1,
            provider: .gmail,
            credentialId: "gmail-personal",
            accessMode: .read,
            expectedScopes: gmailScopes(accessMode: .read).sorted(),
            client: client,
            token: try coherentToken(client: client)
        )

        try await vault.replaceProfile(profile)
        let storedProfile = try await vault.profile(credentialId: "gmail-personal", accessMode: .read)
        let stored = try XCTUnwrap(storedProfile)
        XCTAssertEqual(stored.client, client)
        XCTAssertNotNil(stored.token)

        try await vault.replaceToken(nil, in: stored)
        let clearedProfile = try await vault.profile(credentialId: "gmail-personal", accessMode: .read)
        let cleared = try XCTUnwrap(clearedProfile)
        XCTAssertEqual(cleared.client, client)
        XCTAssertNil(cleared.token)
    }

    func testInvalidStoredDataFailsClosed() async throws {
        let store = TestSecureCredentialStore()
        await store.put(Data("not-json".utf8), account: "gmail-profile:gmail-personal:read")
        let vault = GmailCredentialVault(store: store)

        await XCTAssertThrowsErrorAsync {
            _ = try await vault.profile(credentialId: "gmail-personal", accessMode: .read)
        }
    }

    func testVaultNormalizesDesktopClientBeforeStoreAndReturn() async throws {
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        let legacyClient = GmailOAuthClientRecord(
            kind: "installed", clientId: "client-id.apps.googleusercontent.com", clientSecret: "client-secret",
            projectId: "project", authorizationEndpoint: "https://accounts.google.com/o/oauth2/auth",
            tokenEndpoint: "https://oauth2.googleapis.com/token", redirectURIs: ["http://127.0.0.1:8080/oauth2callback"]
        )

        try await vault.replaceProfile(testProfile(client: legacyClient, token: nil))

        let rawData = try await vault.rawProfileData(credentialId: "gmail-personal", accessMode: .read)
        let raw = try XCTUnwrap(rawData)
        let stored = try JSONDecoder().decode(GmailCredentialProfileEnvelope.self, from: raw)
        let returnedProfile = try await vault.profile(credentialId: "gmail-personal", accessMode: .read)
        let returned = try XCTUnwrap(returnedProfile)
        XCTAssertEqual(stored.client.authorizationEndpoint, "https://accounts.google.com/o/oauth2/v2/auth")
        XCTAssertEqual(returned.client.authorizationEndpoint, "https://accounts.google.com/o/oauth2/v2/auth")
    }

    func testRejectsIncoherentTokenEnvelopeBeforeStoreWrite() async throws {
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        let client = testClient()
        try await vault.replaceProfile(testProfile(client: client, token: nil))
        let writesBefore = await store.dataWriteCount()
        let incoherent = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "access-token",
            refreshToken: "refresh-token",
            tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "),
            expiresAt: nil,
            emailAddress: nil,
            clientFingerprint: "different-client"
        )

        await XCTAssertThrowsErrorAsync {
            try await vault.replaceToken(incoherent, in: testProfile(client: client, token: nil))
        }

        let writesAfter = await store.dataWriteCount()
        let retained = try await vault.profile(credentialId: "gmail-personal", accessMode: .read)
        XCTAssertEqual(writesAfter, writesBefore)
        XCTAssertNil(retained?.token)
    }

    func testFailedWholeEnvelopeWritePreservesPreviousProfile() async throws {
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        let client = testClient()
        let original = testProfile(client: client, token: try coherentToken(client: client))
        try await vault.replaceProfile(original)
        await store.failNextSet()

        var replacement = try coherentToken(client: client)
        replacement = GmailOAuthTokenStore(
            accessMode: replacement.accessMode,
            accessToken: "replacement-access-token",
            refreshToken: replacement.refreshToken,
            tokenType: replacement.tokenType,
            scope: replacement.scope,
            expiresAt: replacement.expiresAt,
            emailAddress: replacement.emailAddress,
            clientFingerprint: replacement.clientFingerprint
        )
        await XCTAssertThrowsErrorAsync {
            try await vault.replaceToken(replacement, in: original)
        }

        let retained = try await vault.profile(credentialId: "gmail-personal", accessMode: .read)
        XCTAssertEqual(retained?.token?.accessToken, original.token?.accessToken)
    }

    func testStoreReadAndWriteFailuresFailClosed() async throws {
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        await store.failNextRead()
        await XCTAssertThrowsErrorAsync {
            _ = try await vault.profile(credentialId: "gmail-personal", accessMode: .read)
        }

        await store.failNextSet()
        await XCTAssertThrowsErrorAsync {
            try await vault.replaceProfile(testProfile(client: testClient(), token: nil))
        }
    }
}

actor TestSecureCredentialStore: SecureCredentialStore {
    private var entries: [String: Data] = [:]
    private var reads = 0
    private var writes = 0
    private var shouldFailNextRead = false
    private var shouldFailNextSet = false

    func data(for account: String) async throws -> Data? {
        reads += 1
        if shouldFailNextRead {
            shouldFailNextRead = false
            throw TestStoreError.read
        }
        return entries[account]
    }
    func set(_ data: Data, for account: String) async throws {
        writes += 1
        if shouldFailNextSet {
            shouldFailNextSet = false
            throw TestStoreError.write
        }
        entries[account] = data
    }
    func remove(account: String) async throws {
        writes += 1
        entries.removeValue(forKey: account)
    }
    func accounts(prefix: String) async throws -> [String] { entries.keys.filter { $0.hasPrefix(prefix) }.sorted() }
    func put(_ data: Data, account: String) {
        writes += 1
        entries[account] = data
    }
    func dataReadCount() -> Int { reads }
    func dataWriteCount() -> Int { writes }
    func failNextRead() { shouldFailNextRead = true }
    func failNextSet() { shouldFailNextSet = true }
}

private enum TestStoreError: Error {
    case read
    case write
}

func testClient() -> GmailOAuthClientRecord {
    GmailOAuthClientRecord(
        kind: "installed",
        clientId: "client-id.apps.googleusercontent.com",
        clientSecret: "client-secret",
        projectId: "project",
        authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
        tokenEndpoint: "https://oauth2.googleapis.com/token",
        redirectURIs: ["http://127.0.0.1:8080/oauth2callback"]
    )
}

func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
