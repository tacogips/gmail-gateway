import Foundation
import GoogleServiceGatewayCore

enum GmailPersistentAuthLifecyclePhase: Sendable {
    case setupReadyToCommit
    case revokeReadyToCommit
    case loginDestinationResolved
    case refreshResolved
}

struct GmailAuthCoordinator: Sendable {
    private let config: GmailGatewayConfig
    private let environment: [String: String]
    private let policy: GmailAuthPolicy
    private let vault: GmailCredentialVault
    private let loginResult: @Sendable (CredentialConfig, GmailOAuthLoginOptions) throws -> GmailOAuthLoginResult
    private let refreshToken: @Sendable (CredentialConfig, GmailOAuthTokenStore) throws -> GmailOAuthTokenStore
    private let lifecyclePhase: @Sendable (GmailPersistentAuthLifecyclePhase) async -> Void
    private let lifecycleLockAttempt: @Sendable () async -> Void
    private let lifecycleLockEvent: @Sendable (GmailCredentialLifecycleLockEvent) -> Void

    init(
        config: GmailGatewayConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        policy: GmailAuthPolicy,
        store: any SecureCredentialStore = KeychainCredentialStore(service: "com.tacogips.gmail-gateway"),
        loginResult: @escaping @Sendable (CredentialConfig, GmailOAuthLoginOptions) throws -> GmailOAuthLoginResult = { credential, options in
            try GmailOAuthBootstrapper().loginResult(credential: credential, options: options)
        },
        refreshToken: @escaping @Sendable (CredentialConfig, GmailOAuthTokenStore) throws -> GmailOAuthTokenStore = refreshedGmailOAuthTokenStore,
        lifecyclePhase: @escaping @Sendable (GmailPersistentAuthLifecyclePhase) async -> Void = { _ in },
        lifecycleLockAttempt: @escaping @Sendable () async -> Void = {},
        lifecycleLockEvent: @escaping @Sendable (GmailCredentialLifecycleLockEvent) -> Void = { _ in }
    ) {
        self.config = config
        self.environment = environment
        self.policy = policy
        vault = GmailCredentialVault(store: store)
        self.loginResult = loginResult
        self.refreshToken = refreshToken
        self.lifecyclePhase = lifecyclePhase
        self.lifecycleLockAttempt = lifecycleLockAttempt
        self.lifecycleLockEvent = lifecycleLockEvent
    }

    func setup(credentialId: String, options: GmailOAuthSetupOptions) async throws -> [String: Any] {
        let credential = try selectedCredential(credentialId)
        await lifecycleLockAttempt()
        return try await withLifecycleLock(credential) {
            try await setupLocked(credential: credential, options: options)
        }
    }

    private func setupLocked(credential: CredentialConfig, options: GmailOAuthSetupOptions) async throws -> [String: Any] {
        let existing: GmailCredentialProfileEnvelope?
        let invalidRawData: Data?
        do {
            existing = try await vault.profile(credentialId: credential.id, accessMode: credential.accessMode)
            invalidRawData = nil
        } catch {
            guard options.replace, options.confirmedCredentialId == credential.id,
                  let rawData = try await vault.rawProfileData(credentialId: credential.id, accessMode: credential.accessMode) else {
                throw error
            }
            existing = nil
            invalidRawData = rawData
        }
        if existing != nil {
            guard options.replace, options.confirmedCredentialId == credential.id else {
                throw GmailGatewayError(
                    "a persistent OAuth client already exists; pass --replace and --confirm-credential",
                    code: .invalidArgument,
                    exitCode: .invalidCliUsage
                )
            }
        }
        let client = try loadGmailOAuthClientRecord(from: options.clientSecretPath)
        await lifecyclePhase(.setupReadyToCommit)
        let replacement = envelope(credential: credential, client: client, token: nil)
        if let invalidRawData {
            try await vault.replaceInvalidProfile(replacement, replacingRawData: invalidRawData)
        } else {
            try await vault.replaceProfile(replacement, replacing: existing)
        }
        return [
            "credentialId": credential.id,
            "provider": credential.provider.rawValue,
            "accessMode": credential.accessMode.rawValue,
            "clientKind": client.kind,
            "projectId": client.projectId as Any? ?? NSNull(),
            "persistenceBackend": "KEYCHAIN",
            "clientStored": true
        ]
    }

    func status(credentialId: String) async throws -> [String: Any] {
        let credential = try selectedCredential(credentialId)
        let resolver = resolver()
        let profile = try? await vault.profile(credentialId: credential.id, accessMode: credential.accessMode)
        let clientSource = resolver.clientSourceKind(for: credential)
        let tokenSource = resolver.tokenSourceKind(for: credential)
        let client: ResolvedCredentialSource<GmailOAuthClientRecord>?
        let clientState: AuthState
        do {
            client = try await resolver.resolveClient(for: credential)
            clientState = client == nil ? .missing : .ready
        } catch {
            client = nil
            clientState = .invalid
        }
        let resolvedToken: GmailResolvedToken?
        let tokenReadState: AuthState?
        do {
            resolvedToken = try await resolver.resolveToken(for: credential)
            tokenReadState = nil
        } catch {
            resolvedToken = nil
            tokenReadState = .invalid
        }
        let token = resolvedToken?.source.value
        let state: AuthState
        if let tokenReadState {
            state = tokenReadState
        } else if token == nil {
            state = .missing
        } else if let token {
            switch persistentTokenCredentialBinding(token, credential: credential) {
            case .legacy:
                return statusOutput(
                    credential: credential,
                    clientSource: client?.kind ?? clientSource,
                    tokenSource: resolvedToken?.source.kind ?? tokenSource,
                    clientState: clientState,
                    tokenState: .unknown,
                    scopes: [],
                    token: nil,
                    profile: profile
                )
            case .mismatch:
                return statusOutput(
                    credential: credential,
                    clientSource: client?.kind ?? clientSource,
                    tokenSource: resolvedToken?.source.kind ?? tokenSource,
                    clientState: clientState,
                    tokenState: .invalid,
                    scopes: [],
                    token: nil,
                    profile: profile
                )
            case .current:
                break
            }
            do {
                try validatePersistentTokenLifecycleIdentity(
                    token,
                    credential: credential,
                    exitCode: .graphqlExecutionError
                )
            } catch {
                return statusOutput(
                    credential: credential,
                    clientSource: client?.kind ?? clientSource,
                    tokenSource: resolvedToken?.source.kind ?? tokenSource,
                    clientState: clientState,
                    tokenState: .scopeMismatch,
                    scopes: [],
                    token: nil,
                    profile: profile
                )
            }
            guard token.clientFingerprint != nil, token.scope != nil, let client else {
                state = .unknown
                return statusOutput(
                    credential: credential,
                    clientSource: client?.kind ?? clientSource,
                    tokenSource: resolvedToken?.source.kind ?? tokenSource,
                    clientState: clientState,
                    tokenState: state,
                    scopes: [],
                    token: nil,
                    profile: profile
                )
            }
            do {
                try validatePersistentToken(token, client: client.value, credential: credential, accounts: config.accounts)
            } catch {
                return statusOutput(
                    credential: credential,
                    clientSource: client.kind,
                    tokenSource: resolvedToken?.source.kind ?? tokenSource,
                    clientState: clientState,
                    tokenState: .scopeMismatch,
                    scopes: [],
                    token: nil,
                    profile: profile
                )
            }
            if let expiresAt = nonBlank(token.expiresAt), ISO8601DateFormatter().date(from: expiresAt) == nil {
                state = .invalid
            } else if let expiresAt = token.expiresAt,
                      !gmailAccessTokenIsFresh(expiresAt: expiresAt),
                      token.refreshToken == nil {
                state = .expired
            } else {
                state = .ready
            }
        } else {
            state = .unknown
        }
        return statusOutput(
            credential: credential,
            clientSource: client?.kind ?? clientSource,
            tokenSource: resolvedToken?.source.kind ?? tokenSource,
            clientState: clientState,
            tokenState: state,
            scopes: statusMetadataIsSafe(for: state) ? token?.scope.map(normalizedGmailScopes) ?? [] : [],
            token: statusMetadataIsSafe(for: state) ? token : nil,
            profile: profile
        )
    }

    /// Synthesized OAuth clients follow the production vault-before-file
    /// resolution order. Each configured credential is validated against its
    /// own access mode rather than the executable's selected access mode, so a
    /// shared read/read-send configuration can be validated from either CLI.
    /// Explicit sources are already checked synchronously by configuration
    /// loading and never reach this fallback.
    func validatePersistentConfigSources() async throws {
        for credential in config.credentials
            where credential.oauthClientSecretJSON == nil &&
            credential.oauthClientSecretSource == .synthesizedDefault {
            let validationResolver = GmailAuthResolver(
                config: config,
                environment: environment,
                policy: .persistent(requiredAccessMode: credential.accessMode),
                vault: vault
            )
            do {
                guard try await validationResolver.resolveClient(for: credential) != nil else {
                    throw persistentConfigSourceError(credential)
                }
            } catch let error as GmailGatewayError where error.code == .configInvalid {
                throw error
            } catch {
                throw persistentConfigSourceError(credential)
            }
        }
    }

    private func statusOutput(
        credential: CredentialConfig,
        clientSource: GmailCredentialSourceKind,
        tokenSource: GmailCredentialSourceKind,
        clientState: AuthState,
        tokenState: AuthState,
        scopes: [String],
        token: GmailOAuthTokenStore?,
        profile: GmailCredentialProfileEnvelope?
    ) -> [String: Any] {
        [
            "credentialId": credential.id,
            "provider": credential.provider.rawValue,
            "configuredAccessMode": credential.accessMode.rawValue,
            "requiredAccessMode": policy.requiredAccessMode?.rawValue as Any? ?? NSNull(),
            "clientSource": clientState == .missing ? "MISSING" : clientSource.rawValue,
            "tokenSource": tokenState == .missing ? "MISSING" : tokenSource.rawValue,
            "clientState": clientState.rawValue,
            "tokenState": tokenState.rawValue,
            "grantedScopes": scopes,
            "expiresAt": token?.expiresAt as Any? ?? NSNull(),
            "hasRefreshToken": token?.refreshToken != nil,
            "emailAddress": token?.emailAddress as Any? ?? NSNull(),
            "persistentClientExists": profile != nil,
            "persistentTokenExists": profile?.token != nil
        ].merging(tokenSourceDiagnostics(credential, source: tokenSource)) { current, _ in current }
    }

    func revoke(credentialId: String, confirmedCredentialId: String?) async throws -> [String: Any] {
        let credential = try selectedCredential(credentialId)
        await lifecycleLockAttempt()
        return try await withLifecycleLock(credential) {
            try await revokeLocked(credential: credential, confirmedCredentialId: confirmedCredentialId)
        }
    }

    private func revokeLocked(credential: CredentialConfig, confirmedCredentialId: String?) async throws -> [String: Any] {
        guard confirmedCredentialId == credential.id else {
            throw GmailGatewayError("auth revoke requires an exact --confirm-credential", code: .invalidArgument, exitCode: .invalidCliUsage)
        }
        try await recoverPersistentTokenTransactionIfNeeded(credential)
        let resolved: GmailResolvedToken?
        do {
            resolved = try await resolver().resolveToken(for: credential)
        } catch {
            throw GmailGatewayError(
                "selected token cannot be safely revoked",
                code: .authRequired,
                exitCode: .authenticationBootstrapError,
                details: ["credentialId": credential.id]
            )
        }
        guard let resolved else {
            return ["credentialId": credential.id, "accessMode": credential.accessMode.rawValue, "tokenSource": "MISSING", "revoked": false]
        }
        await lifecyclePhase(.revokeReadyToCommit)
        switch resolved.destination {
        case .immutableEnvironment:
            throw GmailGatewayError("inline token JSON cannot be revoked; remove the environment override", code: .invalidArgument, exitCode: .invalidCliUsage)
        case let .file(path, identity):
            guard let client = try await resolver().resolveClient(for: credential) else {
                throw GmailGatewayError(
                    "run auth setup or configure an OAuth client before auth revoke",
                    code: .authRequired,
                    exitCode: .authenticationBootstrapError
                )
            }
            try validatePersistentTokenLifecycleIdentity(
                resolved.source.value,
                credential: credential,
                exitCode: .authenticationBootstrapError
            )
            try validatePersistentTokenLifecycleFingerprint(
                resolved.source.value,
                client: client.value,
                credential: credential,
                exitCode: .authenticationBootstrapError
            )
            guard case let .identity(fileIdentity) = identity else {
                throw GmailGatewayError(
                    "selected token source changed during lifecycle operation",
                    code: .authRequired,
                    exitCode: .authenticationBootstrapError,
                    details: ["credentialId": credential.id]
                )
            }
            try removePersistentTokenFile(
                at: path,
                expectedState: .identity(fileIdentity),
                credential: credential,
                exitCode: .authenticationBootstrapError
            )
        case let .vault(profile):
            guard let client = try await resolver().resolveClient(for: credential) else {
                throw GmailGatewayError(
                    "run auth setup or configure an OAuth client before auth revoke",
                    code: .authRequired,
                    exitCode: .authenticationBootstrapError
                )
            }
            try validatePersistentTokenLifecycleIdentity(
                resolved.source.value,
                credential: credential,
                exitCode: .authenticationBootstrapError
            )
            guard constantTimeEqual(
                try gmailOAuthClientFingerprint(profile.client),
                try gmailOAuthClientFingerprint(client.value)
            ) else {
                throw GmailGatewayError(
                    "selected OAuth client does not match the vault persistent profile",
                    code: .authRequired,
                    exitCode: .authenticationBootstrapError,
                    details: ["credentialId": credential.id]
                )
            }
            try await vault.replaceToken(nil, in: profile)
        }
        return [
            "credentialId": credential.id,
            "accessMode": credential.accessMode.rawValue,
            "tokenSource": resolved.source.kind.rawValue,
            "revoked": true
        ]
    }

    func login(credentialId: String, options: GmailOAuthLoginOptions) async throws -> [String: Any] {
        let credential = try selectedCredential(credentialId)
        await lifecycleLockAttempt()
        return try await withLifecycleLock(credential) {
            try await loginLocked(credential: credential, options: options)
        }
    }

    private func loginLocked(credential: CredentialConfig, options: GmailOAuthLoginOptions) async throws -> [String: Any] {
        try await recoverPersistentTokenTransactionIfNeeded(credential)
        let resolver = resolver()
        guard let client = try await resolver.resolveClient(for: credential) else {
            throw GmailGatewayError("run auth setup or configure an OAuth client before auth login", code: .authRequired, exitCode: .authenticationBootstrapError)
        }
        let destination = try await resolver.loginDestination(for: credential, client: client.value)
        await lifecyclePhase(.loginDestinationResolved)
        guard case .immutableEnvironment = destination else {
            return try await performLogin(credential: credential, client: client.value, destination: destination, options: options)
        }
        throw GmailGatewayError("inline token JSON is immutable; remove the environment override before login", code: .invalidArgument, exitCode: .invalidCliUsage)
    }

    private func performLogin(
        credential: CredentialConfig,
        client: GmailOAuthClientRecord,
        destination: GmailTokenDestination,
        options: GmailOAuthLoginOptions
    ) async throws -> [String: Any] {
        let clientJSON = try client.legacyJSON()
        let loginCredential = credential.replacingOAuthClientJSON(clientJSON)
        let login = try loginResult(loginCredential, options)
        let token = try validatedPersistentLoginToken(
            login.tokenStore,
            credential: credential,
            client: client,
            accounts: config.accounts
        )
        switch destination {
        case let .vault(profile):
            try await vault.replaceToken(token, in: profile)
        case let .file(path, expectedState):
            try writeGmailOAuthTokenStore(
                token,
                to: path,
                errorMessage: "Failed to write Gmail OAuth token store",
                exitCode: .authenticationBootstrapError,
                replacing: expectedState
            )
        case .immutableEnvironment:
            throw GmailGatewayError("inline token JSON is immutable", code: .invalidArgument, exitCode: .invalidCliUsage)
        }
        return [
            "credentialId": credential.id,
            "provider": credential.provider.rawValue,
            "accessMode": credential.accessMode.rawValue,
            "state": AuthState.ready.rawValue,
            "emailAddress": token.emailAddress as Any? ?? NSNull(),
            "expiresAt": token.expiresAt as Any? ?? NSNull(),
            "hasRefreshToken": true,
            "persistenceBackend": destination.persistenceBackend
        ].merging(tokenSourceDiagnostics(
            credential,
            source: destination.persistenceBackend == "KEYCHAIN" ? .secureVault : resolver().tokenSourceKind(for: credential)
        )) { current, _ in current }
    }

    func hydratedConfig(credentialIds: Set<String>? = nil) async throws -> GmailGatewayConfig {
        guard policy.requiredAccessMode != nil else { return config }
        let credentials = try await config.credentials.asyncMap { credential in
            guard credentialIds?.contains(credential.id) ?? true else { return credential }
            guard credential.accessMode == policy.requiredAccessMode else {
                throw GmailGatewayError(
                    "selected account does not use this executable's access mode",
                    code: .authRequired,
                    exitCode: .graphqlExecutionError,
                    details: ["credentialId": credential.id]
                )
            }
            try validatePersistentCredential(credential, policy: policy)
            await lifecycleLockAttempt()
            return try await withLifecycleLock(credential) {
                try await recoverPersistentTokenTransactionIfNeeded(credential)
                let resolver = resolver()
                let token = try await resolver.resolveToken(for: credential)
                let client = try await resolver.resolveClient(for: credential)
                guard let token else { return credential }
                guard let client else {
                    throw GmailGatewayError(
                        "persistent token has no matching OAuth client",
                        code: .authRequired,
                        exitCode: .graphqlExecutionError,
                        details: ["credentialId": credential.id]
                    )
                }
                try validateResolvedToken(token.source.value, source: token.source.kind, client: client.value, credential: credential)
                let resolvedToken: GmailOAuthTokenStore
                if gmailAccessTokenIsFresh(expiresAt: token.source.value.expiresAt) {
                    resolvedToken = token.source.value
                } else {
                    await lifecyclePhase(.refreshResolved)
                    resolvedToken = try refreshToken(
                        credential.replacingOAuthClientJSON(try client.value.legacyJSON()),
                        token.source.value
                    )
                    try validateResolvedToken(resolvedToken, source: token.source.kind, client: client.value, credential: credential)
                    try await persistPersistentToken(resolvedToken, destination: token.destination)
                }
                return credential
                    .replacingOAuthClientJSON(try client.value.legacyJSON())
                    .replacingTokenJSON(try JSONEncoder().encode(resolvedToken))
            }
        }
        return GmailGatewayConfig(configPath: config.configPath, storage: config.storage, credentials: credentials, accounts: config.accounts)
    }

    private func selectedCredential(_ credentialId: String) throws -> CredentialConfig {
        guard let credential = config.credentials.first(where: { $0.id == credentialId }) else {
            throw GmailGatewayError("credential was not found", code: .credentialNotFound, exitCode: .configurationError)
        }
        try validatePersistentCredential(credential, policy: policy)
        return credential
    }

    private func validateResolvedToken(
        _ token: GmailOAuthTokenStore,
        source: GmailCredentialSourceKind,
        client: GmailOAuthClientRecord,
        credential: CredentialConfig
    ) throws {
        do {
            try validatePersistentToken(token, client: client, credential: credential, accounts: config.accounts)
        } catch let error as GmailGatewayError {
            throw tokenSourceError(
                GmailGatewayError(
                    error.message, code: error.code, exitCode: error.exitCode,
                    details: ["tokenSource": source.rawValue]
                ),
                credential: credential
            )
        }
    }

    private func resolver() -> GmailAuthResolver {
        GmailAuthResolver(config: config, environment: environment, policy: policy, vault: vault)
    }

    private func withLifecycleLock<T>(
        _ credential: CredentialConfig,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await withPersistentCredentialLifecycleLock(
                credential: credential,
                lifecycleLockEvent: lifecycleLockEvent,
                operation: operation
            )
        } catch let error as GmailGatewayError {
            throw tokenSourceError(error, credential: credential)
        }
    }

    private func recoverPersistentTokenTransactionIfNeeded(_ credential: CredentialConfig) async throws {
        // An inline token is the effective immutable source even when a lower
        // priority configured path still names a token file. Recovery is a
        // mutation, so it must follow the resolved token precedence rather
        // than the underlying configured-path provenance.
        guard resolver().tokenSourceKind(for: credential) != .environmentJSON else {
            return
        }
        switch credential.tokenStoreSource {
        case .environmentJSON, .secureVault:
            return
        case .environmentPath, .configuredPath, .relocatedPath, .synthesizedDefault:
            if credential.tokenStoreSource == .synthesizedDefault,
               (try? await vault.profile(credentialId: credential.id, accessMode: credential.accessMode)) != nil,
               !(try persistentTokenFileHasInterruptedTransaction(
                   at: credential.tokenStorePath,
                   credential: credential,
                   exitCode: .authenticationBootstrapError
               )) {
                return
            }
            try recoverPersistentTokenFileTransaction(
                at: credential.tokenStorePath,
                credential: credential,
                exitCode: .authenticationBootstrapError
            )
        }
    }

    private func envelope(
        credential: CredentialConfig,
        client: GmailOAuthClientRecord,
        token: GmailOAuthTokenStore?
    ) -> GmailCredentialProfileEnvelope {
        GmailCredentialProfileEnvelope(
            schemaVersion: 1,
            provider: .gmail,
            credentialId: credential.id,
            accessMode: credential.accessMode,
            expectedScopes: gmailScopes(accessMode: credential.accessMode).sorted(),
            client: client,
            token: token,
            revision: "new:\(UUID().uuidString)"
        )
    }

    func persistPersistentToken(_ token: GmailOAuthTokenStore, destination: GmailTokenDestination) async throws {
        switch destination {
        case let .vault(profile):
            try await vault.replaceToken(token, in: profile)
        case let .file(path, expectedState):
            try writeGmailOAuthTokenStore(
                token,
                to: path,
                errorMessage: "Failed to write refreshed Gmail token store",
                exitCode: .graphqlExecutionError,
                replacing: expectedState
            )
        case .immutableEnvironment:
            break
        }
    }
}

private func statusMetadataIsSafe(for state: AuthState) -> Bool {
    state == .ready || state == .expired
}

private func persistentConfigSourceError(_ credential: CredentialConfig) -> GmailGatewayError {
    GmailGatewayError(
        "credentials.\(credential.id).oauth_client_secret_path is not readable and no persistent Keychain client is available",
        code: .configInvalid,
        exitCode: .configurationError
    )
}

func validatedPersistentLoginToken(
    _ loginToken: GmailOAuthTokenStore,
    credential: CredentialConfig,
    client: GmailOAuthClientRecord,
    accounts: [AccountConfig]
) throws -> GmailOAuthTokenStore {
    guard nonBlank(loginToken.refreshToken) != nil else {
        throw GmailGatewayError("OAuth login did not return a refresh token", code: .authRequired, exitCode: .authenticationBootstrapError)
    }
    let grantedScopes = loginToken.scope.map(normalizedGmailScopes) ?? gmailScopes(accessMode: credential.accessMode)
    guard Set(grantedScopes) == Set(gmailScopes(accessMode: credential.accessMode)) else {
        throw GmailGatewayError("OAuth login scopes do not match this executable", code: .authRequired, exitCode: .authenticationBootstrapError)
    }
    let token = GmailOAuthTokenStore(
        accessMode: credential.accessMode,
        accessToken: loginToken.accessToken,
        refreshToken: loginToken.refreshToken,
        tokenType: loginToken.tokenType,
        scope: grantedScopes.sorted().joined(separator: " "),
        expiresAt: loginToken.expiresAt,
        emailAddress: loginToken.emailAddress,
        clientFingerprint: try gmailOAuthClientFingerprint(client),
        schemaVersion: 1,
        provider: credential.provider,
        credentialId: credential.id
    )
    try validatePersistentToken(token, client: client, credential: credential, accounts: accounts)
    return token
}

private extension GmailTokenDestination {
    var persistenceBackend: String {
        switch self {
        case .vault: "KEYCHAIN"
        case .file: "FILE"
        case .immutableEnvironment: "ENVIRONMENT"
        }
    }
}

private extension CredentialConfig {
    func replacingOAuthClientJSON(_ json: String) -> CredentialConfig {
        CredentialConfig(
            id: id,
            provider: provider,
            accessMode: accessMode,
            oauthClientSecretPath: oauthClientSecretPath,
            oauthClientSecretJSON: json,
            tokenStorePath: tokenStorePath,
            tokenStoreJSON: tokenStoreJSON,
            oauthClientSecretSource: oauthClientSecretSource,
            tokenStoreSource: tokenStoreSource
        )
    }

    func replacingTokenJSON(_ data: Data) -> CredentialConfig {
        let json = String(data: data, encoding: .utf8) ?? ""
        return CredentialConfig(
            id: id,
            provider: provider,
            accessMode: accessMode,
            oauthClientSecretPath: oauthClientSecretPath,
            oauthClientSecretJSON: oauthClientSecretJSON,
            tokenStorePath: tokenStorePath,
            tokenStoreJSON: json,
            oauthClientSecretSource: oauthClientSecretSource,
            tokenStoreSource: tokenStoreSource
        )
    }
}

private extension Array {
    func asyncMap<T: Sendable>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for value in self { result.append(try await transform(value)) }
        return result
    }
}
