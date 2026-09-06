import CryptoKit
import Foundation

enum GmailTokenDestination: Sendable {
    case vault(GmailCredentialProfileEnvelope)
    case file(String, PersistentTokenFileExpectedState)
    case immutableEnvironment
}

struct GmailResolvedToken: Sendable {
    let source: ResolvedCredentialSource<GmailOAuthTokenStore>
    let destination: GmailTokenDestination
}

struct GmailAuthResolver: Sendable {
    private let config: GmailGatewayConfig
    private let environment: [String: String]
    private let policy: GmailAuthPolicy
    private let vault: GmailCredentialVault

    init(
        config: GmailGatewayConfig,
        environment: [String: String],
        policy: GmailAuthPolicy,
        vault: GmailCredentialVault
    ) {
        self.config = config
        self.environment = environment
        self.policy = policy
        self.vault = vault
    }

    func resolveClient(for credential: CredentialConfig) async throws -> ResolvedCredentialSource<GmailOAuthClientRecord>? {
        try validatePersistentCredential(credential, policy: policy)
        switch clientSourceKind(for: credential) {
        case .environmentJSON:
            guard let value = credential.oauthClientSecretJSON else { return nil }
            return ResolvedCredentialSource(
                value: try loadGmailOAuthClientRecord(from: Data(value.utf8)),
                kind: .environmentJSON,
                writable: false
            )
        case .environmentPath, .configuredPath:
            return ResolvedCredentialSource(
                value: try loadGmailOAuthClientRecord(from: credential.oauthClientSecretPath),
                kind: clientSourceKind(for: credential),
                writable: true
            )
        case .relocatedPath:
            return nil
        case .secureVault:
            return nil
        case .synthesizedDefault:
            if let profile = try await vault.profile(credentialId: credential.id, accessMode: credential.accessMode) {
                return ResolvedCredentialSource(value: profile.client, kind: .secureVault, writable: true)
            }
            guard FileManager.default.fileExists(atPath: credential.oauthClientSecretPath) else { return nil }
            return ResolvedCredentialSource(
                value: try loadGmailOAuthClientRecord(from: credential.oauthClientSecretPath),
                kind: .synthesizedDefault,
                writable: true
            )
        }
    }

    func resolveToken(for credential: CredentialConfig) async throws -> GmailResolvedToken? {
        try validatePersistentCredential(credential, policy: policy)
        let kind = tokenSourceKind(for: credential)
        switch kind {
        case .environmentJSON:
            guard let value = credential.tokenStoreJSON else { return nil }
            return GmailResolvedToken(
                source: ResolvedCredentialSource(
                    value: try decodeToken(Data(value.utf8), credential: credential),
                    kind: .environmentJSON,
                    writable: false
                ),
                destination: .immutableEnvironment
            )
        case .environmentPath, .configuredPath:
            guard let data = try readPersistentTokenFileData(
                credential.tokenStorePath, credential: credential, exitCode: .graphqlExecutionError
            ) else { return nil }
            return GmailResolvedToken(
                source: ResolvedCredentialSource(
                    value: try decodeToken(data.data, credential: credential),
                    kind: kind,
                    writable: true
                ),
                destination: .file(credential.tokenStorePath, .identity(data.identity))
            )
        case .relocatedPath:
            if let data = try readPersistentTokenFileData(
                credential.tokenStorePath, credential: credential, exitCode: .graphqlExecutionError
            ) {
                return GmailResolvedToken(
                    source: ResolvedCredentialSource(
                        value: try decodeToken(data.data, credential: credential),
                        kind: kind,
                        writable: true
                    ),
                    destination: .file(credential.tokenStorePath, .identity(data.identity))
                )
            }
            if let profile = try await vault.profile(credentialId: credential.id, accessMode: credential.accessMode),
               let token = profile.token {
                return GmailResolvedToken(
                    source: ResolvedCredentialSource(value: token, kind: .secureVault, writable: true),
                    destination: .vault(profile)
                )
            }
            return nil
        case .secureVault:
            return nil
        case .synthesizedDefault:
            if let profile = try await vault.profile(credentialId: credential.id, accessMode: credential.accessMode),
               let token = profile.token {
                return GmailResolvedToken(
                    source: ResolvedCredentialSource(value: token, kind: .secureVault, writable: true),
                    destination: .vault(profile)
                )
            }
            guard let data = try readPersistentTokenFileData(
                credential.tokenStorePath, credential: credential, exitCode: .graphqlExecutionError
            ) else { return nil }
            return GmailResolvedToken(
                source: ResolvedCredentialSource(
                    value: try decodeToken(data.data, credential: credential),
                    kind: .synthesizedDefault,
                    writable: true
                ),
                destination: .file(credential.tokenStorePath, .identity(data.identity))
            )
        }
    }

    func loginDestination(for credential: CredentialConfig, client: GmailOAuthClientRecord) async throws -> GmailTokenDestination {
        let kind = tokenSourceKind(for: credential)
        switch kind {
        case .environmentJSON:
            return .immutableEnvironment
        case .environmentPath, .configuredPath:
            try validatePersistentTokenFilePath(credential.tokenStorePath, credential: credential, exitCode: .authenticationBootstrapError)
            let identity = try validateExistingFileToken(for: credential, at: credential.tokenStorePath, client: client)
            return .file(credential.tokenStorePath, identity.map(PersistentTokenFileExpectedState.identity) ?? .absent)
        case .relocatedPath:
            if try readPersistentTokenFileData(credential.tokenStorePath, credential: credential, exitCode: .authenticationBootstrapError) != nil {
                let identity = try validateExistingFileToken(for: credential, at: credential.tokenStorePath, client: client)
                return .file(credential.tokenStorePath, identity.map(PersistentTokenFileExpectedState.identity) ?? .absent)
            }
            if let profile = try await vault.profile(credentialId: credential.id, accessMode: credential.accessMode),
               profile.token != nil {
                return try vaultDestination(profile, client: client, credential: credential)
            }
            return .file(credential.tokenStorePath, .absent)
        case .secureVault:
            if let profile = try await vault.profile(credentialId: credential.id, accessMode: credential.accessMode) {
                return try vaultDestination(profile, client: client, credential: credential)
            }
            return .vault(newEnvelope(credential: credential, client: client))
        case .synthesizedDefault:
            let profile = try await vault.profile(credentialId: credential.id, accessMode: credential.accessMode)
            if let profile, profile.token != nil {
                return try vaultDestination(profile, client: client, credential: credential)
            }
            if try readPersistentTokenFileData(credential.tokenStorePath, credential: credential, exitCode: .authenticationBootstrapError) != nil {
                let identity = try validateExistingFileToken(for: credential, at: credential.tokenStorePath, client: client)
                return .file(credential.tokenStorePath, identity.map(PersistentTokenFileExpectedState.identity) ?? .absent)
            }
            if let profile {
                return try vaultDestination(profile, client: client, credential: credential)
            }
            return .vault(newEnvelope(credential: credential, client: client))
        }
    }

    private func vaultDestination(
        _ profile: GmailCredentialProfileEnvelope,
        client: GmailOAuthClientRecord,
        credential: CredentialConfig
    ) throws -> GmailTokenDestination {
        guard constantTimeEqual(
            try gmailOAuthClientFingerprint(profile.client),
            try gmailOAuthClientFingerprint(client)
        ) else {
            throw credentialResolutionError("persistent OAuth client does not match the vault profile", credential: credential)
        }
        return .vault(profile)
    }

    private func newEnvelope(
        credential: CredentialConfig,
        client: GmailOAuthClientRecord
    ) -> GmailCredentialProfileEnvelope {
        GmailCredentialProfileEnvelope(
            schemaVersion: 1,
            provider: .gmail,
            credentialId: credential.id,
            accessMode: credential.accessMode,
            expectedScopes: gmailScopes(accessMode: credential.accessMode).sorted(),
            client: client,
            token: nil,
            revision: "new:\(UUID().uuidString)"
        )
    }

    func clientSourceKind(for credential: CredentialConfig) -> GmailCredentialSourceKind {
        if credential.oauthClientSecretJSON != nil { return .environmentJSON }
        return credential.oauthClientSecretSource
    }

    func tokenSourceKind(for credential: CredentialConfig) -> GmailCredentialSourceKind {
        if credential.tokenStoreJSON != nil { return .environmentJSON }
        return credential.tokenStoreSource
    }

    private func decodeToken(_ data: Data, credential: CredentialConfig) throws -> GmailOAuthTokenStore {
        do {
            // Keep a decodable token available to local status inspection even when its
            // access mode is incompatible. `validatePersistentToken` rejects it before
            // refresh or provider access, while `status` can accurately report
            // SCOPE_MISMATCH instead of the less actionable INVALID state.
            return try JSONDecoder().decode(GmailOAuthTokenStore.self, from: data)
        } catch let error as GmailGatewayError {
            throw error
        } catch {
            throw credentialResolutionError("selected token source is invalid", credential: credential)
        }
    }

    private func validateExistingFileToken(
        for credential: CredentialConfig,
        at path: String,
        client: GmailOAuthClientRecord
    ) throws -> PersistentTokenFileIdentity? {
        guard let read = try readPersistentTokenFileData(path, credential: credential, exitCode: .authenticationBootstrapError) else { return nil }
        let token = try decodeToken(read.data, credential: credential)
        try validatePersistentTokenLifecycleIdentity(
            token,
            credential: credential,
            exitCode: .authenticationBootstrapError,
            allowingLegacyToken: true
        )
        try validatePersistentTokenLifecycleFingerprint(
            token,
            client: client,
            credential: credential,
            exitCode: .authenticationBootstrapError
        )
        return read.identity
    }
}

func validatePersistentTokenLifecycleIdentity(
    _ token: GmailOAuthTokenStore,
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode,
    allowingLegacyToken: Bool = false
) throws {
    switch persistentTokenCredentialBinding(token, credential: credential) {
    case .current:
        break
    case .legacy where allowingLegacyToken:
        break
    case .legacy:
        throw persistentTokenLegacyIdentityError(credential: credential, exitCode: exitCode)
    case .mismatch:
        throw persistentTokenIdentityMismatchError(credential: credential, exitCode: exitCode)
    }
    guard token.accessMode == credential.accessMode else {
        throw persistentTokenScopeMismatchError(credential: credential, exitCode: exitCode)
    }
    guard let scope = token.scope else {
        return
    }
    guard Set(normalizedGmailScopes(scope)) == Set(gmailScopes(accessMode: credential.accessMode)) else {
        throw persistentTokenScopeMismatchError(credential: credential, exitCode: exitCode)
    }
}

func validatePersistentTokenLifecycleFingerprint(
    _ token: GmailOAuthTokenStore,
    client: GmailOAuthClientRecord,
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode
) throws {
    // A missing fingerprint is a legacy token that may be upgraded by a successful
    // re-login. Any present fingerprint must identify the selected OAuth client
    // before a lifecycle operation can replace or delete the file.
    guard let fingerprint = token.clientFingerprint else { return }
    guard constantTimeEqual(fingerprint, try gmailOAuthClientFingerprint(client)) else {
        throw GmailGatewayError(
            "selected token does not match the selected OAuth client",
            code: .authRequired,
            exitCode: exitCode,
            details: ["credentialId": credential.id]
        )
    }
}

func validatePersistentToken(
    _ token: GmailOAuthTokenStore,
    client: GmailOAuthClientRecord,
    credential: CredentialConfig,
    accounts: [AccountConfig]
) throws {
    guard persistentTokenCredentialBinding(token, credential: credential) == .current,
          token.accessMode == credential.accessMode,
          Set(normalizedGmailScopes(token.scope ?? "")) == Set(gmailScopes(accessMode: credential.accessMode)),
          let fingerprint = token.clientFingerprint,
          constantTimeEqual(fingerprint, try gmailOAuthClientFingerprint(client)) else {
        throw GmailGatewayError("persistent credentials require re-login", code: .authRequired, exitCode: .graphqlExecutionError)
    }
    let boundAccounts = accounts.filter { $0.credentialId == credential.id && !$0.isFallback }
    if !boundAccounts.isEmpty {
        guard let principal = nonBlank(token.emailAddress),
              boundAccounts.allSatisfy({ $0.emailAddress.caseInsensitiveCompare(principal) == .orderedSame }) else {
            throw GmailGatewayError("stored token principal does not match the configured account", code: .authRequired, exitCode: .graphqlExecutionError)
        }
    }
}

enum PersistentTokenCredentialBinding: Equatable {
    case current
    case legacy
    case mismatch
}

func persistentTokenCredentialBinding(
    _ token: GmailOAuthTokenStore,
    credential: CredentialConfig
) -> PersistentTokenCredentialBinding {
    if token.schemaVersion == nil, token.provider == nil, token.credentialId == nil {
        return .legacy
    }
    guard token.schemaVersion == 1,
          token.provider == credential.provider,
          token.credentialId == credential.id else {
        return .mismatch
    }
    return .current
}

func normalizedGmailScopes(_ value: String) -> [String] {
    value.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init).sorted()
}

func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    var difference = left.count ^ right.count
    for index in 0..<max(left.count, right.count) {
        let leftByte = index < left.count ? left[index] : 0
        let rightByte = index < right.count ? right[index] : 0
        difference |= Int(leftByte ^ rightByte)
    }
    return difference == 0
}

private func credentialResolutionError(_ message: String, credential: CredentialConfig) -> GmailGatewayError {
    GmailGatewayError(
        message,
        code: .authRequired,
        exitCode: .graphqlExecutionError,
        details: ["credentialId": credential.id]
    )
}

private func persistentTokenScopeMismatchError(
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode
) -> GmailGatewayError {
    GmailGatewayError(
        "selected token has SCOPE_MISMATCH identity; use the matching executable or update the credential path",
        code: .authRequired,
        exitCode: exitCode,
        details: [
            "credentialId": credential.id,
            "state": AuthState.scopeMismatch.rawValue
        ]
    )
}

private func persistentTokenLegacyIdentityError(
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode
) -> GmailGatewayError {
    GmailGatewayError(
        "stored token is legacy and requires re-login",
        code: .authRequired,
        exitCode: exitCode,
        details: ["credentialId": credential.id, "state": AuthState.unknown.rawValue]
    )
}

private func persistentTokenIdentityMismatchError(
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode
) -> GmailGatewayError {
    GmailGatewayError(
        "stored token does not match the selected credential",
        code: .authRequired,
        exitCode: exitCode,
        details: ["credentialId": credential.id]
    )
}
