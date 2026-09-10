import Foundation

/// Only the historical synthesized fallback used config-dir/tokens/gmail-personal.json.
/// Explicit profile paths and directory overrides are never migration candidates.
func migrateGmailDefaultTokenStore(_ credential: CredentialConfig, beforeMarker: (() throws -> Void)? = nil) throws {
    guard credential.tokenStoreSource == .synthesizedDefault,
          credential.tokenStoreJSON == nil,
          let legacy = credential.legacyDefaultTokenStorePath,
          legacy != credential.tokenStorePath else { return }
    let markerPath = credential.tokenStorePath + ".migration-complete"
    let completed = Data("gmail-token-state-migration-v1\n".utf8)
    do {
        // Avoid creating state directories for an unauthenticated invocation.
        let state = try migrationRead(credential.tokenStorePath, credential: credential, makePrivate: true)
        let marker = try migrationRead(markerPath, credential: credential, makePrivate: true)
        if let marker {
            guard marker.data == completed else { throw POSIXError(.EINVAL) }
            return
        }
        guard try state != nil || migrationRead(legacy, credential: credential) != nil else { return }
        try withGmailTokenMigrationLock(credential: credential) {
            if let marker = try migrationRead(markerPath, credential: credential) {
                guard marker.data == completed else { throw POSIXError(.EINVAL) }
                return
            }
            if try migrationRead(credential.tokenStorePath, credential: credential) == nil {
                guard let source = try migrationRead(legacy, credential: credential) else { return }
                let token = try JSONDecoder().decode(GmailOAuthTokenStore.self, from: source.data)
                guard token.accessMode == credential.accessMode else { throw POSIXError(.EINVAL) }
                try writeSecureGmailOAuthTokenData(
                    source.data, to: credential.tokenStorePath, credential: credential,
                    errorMessage: "Failed to migrate legacy OAuth token", exitCode: .authenticationBootstrapError,
                    replacing: .absent
                )
            }
            // A crash after token publication is recovered here on the next invocation.
            // Revoke resolves migration before deleting the token, so this durable marker
            // prevents the retained legacy recovery copy from ever becoming active again.
            try beforeMarker?()
            try writeSecureGmailOAuthTokenData(
                completed, to: markerPath, credential: credential,
                errorMessage: "Failed to record OAuth token migration", exitCode: .authenticationBootstrapError,
                replacing: .absent
            )
        }
    } catch {
        throw GmailGatewayError(
            "Default OAuth token migration failed; inspect the legacy and state paths before retrying. No legacy token was deleted.",
            code: .authRequired, exitCode: .authenticationBootstrapError,
            details: ["credentialId": credential.id, "legacyTokenStorePath": legacy, "tokenStorePath": credential.tokenStorePath]
        )
    }
}

private func migrationRead(_ path: String, credential: CredentialConfig, makePrivate: Bool = false) throws -> PersistentTokenFileRead? {
    try readPersistentTokenFileData(
        path, credential: credential, exitCode: .authenticationBootstrapError,
        requireOwnedSingleLink: true, makePrivate: makePrivate
    )
}
