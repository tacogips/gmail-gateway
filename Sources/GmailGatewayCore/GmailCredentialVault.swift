import Foundation
import GoogleServiceGatewayCore

struct GmailCredentialProfileEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let provider: MailProvider
    let credentialId: String
    let accessMode: AccessMode
    let expectedScopes: [String]
    let client: GmailOAuthClientRecord
    let token: GmailOAuthTokenStore?
    /// Optional to preserve profiles written before optimistic lifecycle commits.
    let revision: String?

    init(
        schemaVersion: Int,
        provider: MailProvider,
        credentialId: String,
        accessMode: AccessMode,
        expectedScopes: [String],
        client: GmailOAuthClientRecord,
        token: GmailOAuthTokenStore?,
        revision: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.credentialId = credentialId
        self.accessMode = accessMode
        self.expectedScopes = expectedScopes
        self.client = client
        self.token = token
        self.revision = revision
    }
}

struct GmailCredentialVault: Sendable {
    private let store: any SecureCredentialStore

    init(store: any SecureCredentialStore) {
        self.store = store
    }

    func profile(credentialId: String, accessMode: AccessMode) async throws -> GmailCredentialProfileEnvelope? {
        try validateVaultIdentity(credentialId: credentialId)
        guard let data = try await store.data(for: account(credentialId, accessMode)) else { return nil }
        do {
            let profile = try JSONDecoder().decode(GmailCredentialProfileEnvelope.self, from: data)
            guard profile.credentialId == credentialId,
                  profile.accessMode == accessMode else {
                throw vaultError("stored persistent profile does not match the selected credential")
            }
            return try normalizedVaultProfile(profile)
        } catch let error as GmailGatewayError {
            throw error
        } catch {
            throw vaultError("stored persistent profile is invalid")
        }
    }

    func replaceProfile(_ profile: GmailCredentialProfileEnvelope) async throws {
        try await storeProfile(profile.withFreshRevision())
    }

    func replaceProfile(
        _ profile: GmailCredentialProfileEnvelope,
        replacing expected: GmailCredentialProfileEnvelope?
    ) async throws {
        let current = try await self.profile(credentialId: profile.credentialId, accessMode: profile.accessMode)
        guard vaultProfileMatches(current, expected) else {
            throw vaultError("persistent profile changed during lifecycle operation; retry the command")
        }
        try await storeProfile(profile.withFreshRevision())
    }

    /// A confirmed setup replacement may repair an envelope that cannot be
    /// decoded by `profile()`. The raw snapshot prevents that repair from
    /// overwriting data changed after the operator confirmed the replacement.
    func replaceInvalidProfile(
        _ profile: GmailCredentialProfileEnvelope,
        replacingRawData expectedRawData: Data
    ) async throws {
        let currentRawData: Data?
        do {
            currentRawData = try await store.data(for: account(profile.credentialId, profile.accessMode))
        } catch {
            throw vaultError("failed to read persistent Gmail credentials")
        }
        guard currentRawData == expectedRawData else {
            throw vaultError("persistent profile changed during lifecycle operation; retry the command")
        }
        try await storeProfile(profile.withFreshRevision())
    }

    func rawProfileData(credentialId: String, accessMode: AccessMode) async throws -> Data? {
        try validateVaultIdentity(credentialId: credentialId)
        do {
            return try await store.data(for: account(credentialId, accessMode))
        } catch {
            throw vaultError("failed to read persistent Gmail credentials")
        }
    }

    private func storeProfile(_ profile: GmailCredentialProfileEnvelope) async throws {
        let normalizedProfile = try normalizedVaultProfile(profile)
        do {
            try await store.set(try JSONEncoder().encode(normalizedProfile), for: account(normalizedProfile.credentialId, normalizedProfile.accessMode))
        } catch let error as GmailGatewayError {
            throw error
        } catch {
            throw vaultError("failed to store persistent Gmail credentials")
        }
    }

    func replaceToken(_ token: GmailOAuthTokenStore?, in profile: GmailCredentialProfileEnvelope) async throws {
        try await replaceProfile(GmailCredentialProfileEnvelope(
            schemaVersion: profile.schemaVersion,
            provider: profile.provider,
            credentialId: profile.credentialId,
            accessMode: profile.accessMode,
            expectedScopes: profile.expectedScopes,
            client: profile.client,
            token: token,
            revision: profile.revision
        ), replacing: profile)
    }

    private func account(_ credentialId: String, _ accessMode: AccessMode) -> String {
        "gmail-profile:\(credentialId):\(accessMode.rawValue)"
    }
}

private extension GmailCredentialProfileEnvelope {
    func withFreshRevision() -> GmailCredentialProfileEnvelope {
        GmailCredentialProfileEnvelope(
            schemaVersion: schemaVersion,
            provider: provider,
            credentialId: credentialId,
            accessMode: accessMode,
            expectedScopes: expectedScopes,
            client: client,
            token: token,
            revision: UUID().uuidString
        )
    }
}

private func vaultProfileMatches(
    _ current: GmailCredentialProfileEnvelope?,
    _ expected: GmailCredentialProfileEnvelope?
) -> Bool {
    guard let current else {
        return expected == nil || expected?.revision?.hasPrefix("new:") == true
    }
    guard let expected else { return false }
    // Legacy profiles have no revision. Comparing their encoded representation
    // still prevents a stale snapshot from overwriting a sequential replacement.
    if let revision = expected.revision { return current.revision == revision }
    return (try? JSONEncoder().encode(current)) == (try? JSONEncoder().encode(expected))
}

private func normalizedVaultProfile(_ profile: GmailCredentialProfileEnvelope) throws -> GmailCredentialProfileEnvelope {
    try validateVaultIdentity(credentialId: profile.credentialId)
    guard profile.schemaVersion == 1,
          profile.provider == .gmail,
          profile.expectedScopes == gmailScopes(accessMode: profile.accessMode).sorted() else {
        throw vaultError("persistent profile identity is invalid")
    }
    guard profile.client.kind == "installed" else {
        throw vaultError("stored OAuth client is not an installed desktop client")
    }
    let normalizedClient: GmailOAuthClientRecord
    do {
        normalizedClient = try loadGmailOAuthClientRecord(from: Data(try profile.client.legacyJSON().utf8))
    } catch {
        throw vaultError("stored OAuth client is invalid")
    }
    let normalizedProfile = GmailCredentialProfileEnvelope(
        schemaVersion: profile.schemaVersion,
        provider: profile.provider,
        credentialId: profile.credentialId,
        accessMode: profile.accessMode,
        expectedScopes: profile.expectedScopes,
        client: normalizedClient,
        token: profile.token,
        revision: profile.revision
    )
    try validateVaultTokenCoherence(normalizedProfile)
    return normalizedProfile
}

private func validateVaultTokenCoherence(_ profile: GmailCredentialProfileEnvelope) throws {
    guard let token = profile.token else {
        return
    }
    let credential = CredentialConfig(
        id: profile.credentialId,
        provider: profile.provider,
        accessMode: profile.accessMode,
        oauthClientSecretPath: "",
        oauthClientSecretJSON: nil,
        tokenStorePath: "",
        tokenStoreJSON: nil
    )

    guard token.accessMode == profile.accessMode,
          persistentTokenCredentialBinding(token, credential: credential) != .mismatch,
          Set(normalizedGmailScopes(token.scope ?? "")) == Set(profile.expectedScopes),
          let fingerprint = token.clientFingerprint,
          constantTimeEqual(fingerprint, try gmailOAuthClientFingerprint(profile.client)) else {
        throw vaultError("persistent token does not match the stored OAuth client")
    }
}

private func validateVaultIdentity(credentialId: String) throws {
    guard credentialId.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
        throw vaultError("credential ID is invalid")
    }
}

private func vaultError(_ message: String) -> GmailGatewayError {
    GmailGatewayError(message, code: .authRequired, exitCode: .authenticationBootstrapError)
}
