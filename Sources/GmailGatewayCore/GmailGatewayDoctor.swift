import Foundation

private struct PersistentDoctorCredentialInspection {
    let credential: [String: Any]
    let status: [String: Any]
    let issues: [[String: Any]]
}

struct GmailGatewayDoctor {
    let mode: GmailGatewayCLIMode
    let configPath: String?
    let configPathFromFlag: Bool
    let environment: [String: String]
    let preloadedConfig: GmailGatewayConfig?

    init(
        mode: GmailGatewayCLIMode,
        configPath: String?,
        configPathFromFlag: Bool,
        environment: [String: String],
        preloadedConfig: GmailGatewayConfig? = nil
    ) {
        self.mode = mode
        self.configPath = configPath
        self.configPathFromFlag = configPathFromFlag
        self.environment = environment
        self.preloadedConfig = preloadedConfig
    }

    func run(pretty: Bool) throws -> GmailGatewayCommandResult {
        let config = try preloadedConfig ?? GmailGatewayConfigLoader.loadConfig(configPath: configPath, environment: environment)
        var issues: [[String: Any]] = []
        let credentials = config.credentials
            .sorted { $0.id < $1.id }
            .map { credential in
                inspectCredential(credential, issues: &issues)
            }
        let accounts = config.accounts
            .sorted { $0.id < $1.id }
            .map { account in
                inspectAccount(account, config: config, issues: &issues)
            }
        let environmentStatus = inspectEnvironment(config: config)
        let hasConfigurationIssue = issues.contains { $0["category"] as? String == "CONFIGURATION" }
        let hasAuthenticationIssue = issues.contains { $0["category"] as? String == "AUTHENTICATION" }
        let exitCode: GmailGatewayExitCode
        if hasConfigurationIssue {
            exitCode = .configurationError
        } else if hasAuthenticationIssue {
            exitCode = .authenticationBootstrapError
        } else {
            exitCode = .success
        }
        let payload: [String: Any] = [
            "ok": issues.isEmpty,
            "executable": mode.executableName,
            "config": inspectConfig(config),
            "environment": environmentStatus,
            "credentials": credentials,
            "accounts": accounts,
            "issues": issues
        ]
        return GmailGatewayCommandResult(
            exitCode: exitCode.rawValue,
            stdout: jsonString(payload, pretty: pretty) + "\n",
            stderr: ""
        )
    }

    func runPersistent(
        coordinator: GmailAuthCoordinator,
        pretty: Bool
    ) async throws -> GmailGatewayCommandResult {
        let config = try preloadedConfig ?? GmailGatewayConfigLoader.loadConfig(configPath: configPath, environment: environment)
        var issues: [[String: Any]] = []
        var statusByCredentialID: [String: [String: Any]] = [:]
        var credentials: [[String: Any]] = []

        for credential in config.credentials.sorted(by: { $0.id < $1.id }) {
            let inspection = await inspectPersistentCredential(credential, coordinator: coordinator)
            credentials.append(inspection.credential)
            statusByCredentialID[credential.id] = inspection.status
            issues.append(contentsOf: inspection.issues)
        }
        let accounts = config.accounts
            .sorted { $0.id < $1.id }
            .map { account in
                inspectPersistentAccount(account, statusByCredentialID: statusByCredentialID, issues: &issues)
            }
        return doctorResult(
            config: config,
            credentials: credentials,
            accounts: accounts,
            issues: issues,
            pretty: pretty
        )
    }

    private func doctorResult(
        config: GmailGatewayConfig,
        credentials: [[String: Any]],
        accounts: [[String: Any]],
        issues: [[String: Any]],
        pretty: Bool
    ) -> GmailGatewayCommandResult {
        let hasConfigurationIssue = issues.contains { $0["category"] as? String == "CONFIGURATION" }
        let hasAuthenticationIssue = issues.contains { $0["category"] as? String == "AUTHENTICATION" }
        let exitCode: GmailGatewayExitCode
        if hasConfigurationIssue {
            exitCode = .configurationError
        } else if hasAuthenticationIssue {
            exitCode = .authenticationBootstrapError
        } else {
            exitCode = .success
        }
        let payload: [String: Any] = [
            "ok": issues.isEmpty,
            "executable": mode.executableName,
            "config": inspectConfig(config),
            "environment": inspectEnvironment(config: config),
            "credentials": credentials,
            "accounts": accounts,
            "issues": issues
        ]
        return GmailGatewayCommandResult(
            exitCode: exitCode.rawValue,
            stdout: jsonString(payload, pretty: pretty) + "\n",
            stderr: ""
        )
    }

    private func inspectPersistentCredential(
        _ credential: CredentialConfig,
        coordinator: GmailAuthCoordinator
    ) async -> PersistentDoctorCredentialInspection {
        do {
            let status = try await coordinator.status(credentialId: credential.id)
            let clientState = status["clientState"] as? String ?? AuthState.invalid.rawValue
            let tokenState = status["tokenState"] as? String ?? AuthState.invalid.rawValue
            var issues: [[String: Any]] = []
            if clientState != AuthState.ready.rawValue {
                issues.append(issue(
                    category: "CONFIGURATION",
                    code: "OAUTH_CLIENT_\(clientState)",
                    message: "Credential \(credential.id) OAuth client state is \(clientState)",
                    credentialId: credential.id
                ))
            }
            if tokenState != AuthState.ready.rawValue {
                issues.append(issue(
                    category: "AUTHENTICATION",
                    code: "AUTH_\(tokenState)",
                    message: "Credential \(credential.id) authentication state is \(tokenState)",
                    credentialId: credential.id
                ))
            }
            return PersistentDoctorCredentialInspection(
                credential: persistentCredentialOutput(credential, status: status),
                status: status,
                issues: issues
            )
        } catch let error as GmailGatewayError {
            let status: [String: Any] = [
                "credentialId": credential.id,
                "clientState": AuthState.invalid.rawValue,
                "tokenState": AuthState.missing.rawValue,
                "clientSource": "MISSING",
                "tokenSource": "MISSING"
            ]
            return PersistentDoctorCredentialInspection(
                credential: persistentCredentialOutput(credential, status: status),
                status: status,
                issues: [issue(
                    category: "CONFIGURATION",
                    code: "ACCESS_MODE_MISMATCH",
                    message: error.message,
                    credentialId: credential.id
                )]
            )
        } catch {
            let status: [String: Any] = [
                "credentialId": credential.id,
                "clientState": AuthState.invalid.rawValue,
                "tokenState": AuthState.invalid.rawValue,
                "clientSource": "MISSING",
                "tokenSource": "MISSING"
            ]
            return PersistentDoctorCredentialInspection(
                credential: persistentCredentialOutput(credential, status: status),
                status: status,
                issues: [issue(
                    category: "CONFIGURATION",
                    code: "PERSISTENT_AUTH_INSPECTION_FAILED",
                    message: "Persistent OAuth state could not be inspected",
                    credentialId: credential.id
                )]
            )
        }
    }

    private func persistentCredentialOutput(
        _ credential: CredentialConfig,
        status: [String: Any]
    ) -> [String: Any] {
        let clientState = status["clientState"] as? String ?? AuthState.invalid.rawValue
        let tokenState = status["tokenState"] as? String ?? AuthState.invalid.rawValue
        let clientSource = (status["clientSource"] as? String) ?? "MISSING"
        let tokenSource = (status["tokenSource"] as? String) ?? "MISSING"
        let clientIssue: Any = clientState == AuthState.ready.rawValue ? NSNull() : clientState
        let requiredAccessMode = persistentPolicy(for: mode).requiredAccessMode
        let accessModeReady = credential.accessMode == requiredAccessMode
        return [
            "id": credential.id,
            "provider": credential.provider.rawValue,
            "configuredAccessMode": credential.accessMode.rawValue,
            "requiredCapability": mode.requiredCapability?.rawValue as Any? ?? NSNull(),
            "acceptedAccessModes": requiredAccessMode.map { [$0.rawValue] } ?? [],
            "accessModeReady": accessModeReady,
            "oauthClient": [
                "ready": clientState == AuthState.ready.rawValue,
                "source": clientSource,
                "path": credential.oauthClientSecretPath,
                "issue": clientIssue
            ],
            "auth": [
                "ready": tokenState == AuthState.ready.rawValue,
                "state": tokenState,
                "source": tokenSource,
                "tokenStorePath": credential.tokenStorePath,
                "tokenStoreExists": tokenState != AuthState.missing.rawValue,
                "grantedAccessMode": credential.accessMode.rawValue,
                "expiresAt": status["expiresAt"] ?? NSNull(),
                "hasRefreshToken": status["hasRefreshToken"] ?? false,
                "emailAddress": status["emailAddress"] ?? NSNull()
            ]
        ]
    }

    private func inspectPersistentAccount(
        _ account: AccountConfig,
        statusByCredentialID: [String: [String: Any]],
        issues: inout [[String: Any]]
    ) -> [String: Any] {
        let authenticatedEmail = statusByCredentialID[account.credentialId]?["emailAddress"] as? String
        let identityMatches = authenticatedEmail.map {
            $0.caseInsensitiveCompare(account.emailAddress) == .orderedSame
        }
        if identityMatches == false {
            issues.append(issue(
                category: "AUTHENTICATION",
                code: "ACCOUNT_IDENTITY_MISMATCH",
                message: "Account \(account.id) email does not match its authenticated Gmail identity",
                credentialId: account.credentialId,
                accountId: account.id
            ))
        }
        return [
            "id": account.id,
            "credentialId": account.credentialId,
            "configuredEmailAddress": account.emailAddress,
            "authenticatedEmailAddress": authenticatedEmail as Any? ?? NSNull(),
            "identityMatches": identityMatches as Any? ?? NSNull(),
            "fallback": account.isFallback
        ]
    }

    private func inspectConfig(_ config: GmailGatewayConfig) -> [String: Any] {
        let exists = FileManager.default.isReadableFile(atPath: config.configPath)
        let source: String
        if configPathFromFlag {
            source = "COMMAND_LINE"
        } else if nonBlank(environment["GMAIL_GATEWAY_CONFIG"]) != nil {
            source = "ENVIRONMENT"
        } else if exists {
            source = "DEFAULT_FILE"
        } else {
            source = "SYNTHESIZED_DEFAULT"
        }
        return [
            "path": config.configPath,
            "source": source,
            "fileReadable": exists,
            "fallbackConfig": config.accounts.contains { $0.isFallback }
        ]
    }

    private func inspectEnvironment(config: GmailGatewayConfig) -> [[String: Any]] {
        var statuses: [[String: Any]] = [
            environmentStatus(
                name: "GMAIL_GATEWAY_CONFIG",
                purpose: "config_path",
                selected: !configPathFromFlag && nonBlank(environment["GMAIL_GATEWAY_CONFIG"]) != nil,
                containsSecret: false
            )
        ]
        for credential in config.credentials.sorted(by: { $0.id < $1.id }) {
            let oauthJSON = GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
                credentialId: credential.id,
                valueKey: "oauth_client_secret_json"
            )
            let oauthPath = GmailGatewayConfigLoader.getCredentialPathEnvVarName(
                credentialId: credential.id,
                pathKey: "oauth_client_secret_path"
            )
            let tokenJSON = GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
                credentialId: credential.id,
                valueKey: "token_store_json"
            )
            let tokenPath = GmailGatewayConfigLoader.getCredentialPathEnvVarName(
                credentialId: credential.id,
                pathKey: "token_store_path"
            )
            let oauthJSONSelected = nonBlank(environment[oauthJSON]) != nil
            let tokenJSONSelected = nonBlank(environment[tokenJSON]) != nil
            statuses.append(environmentStatus(
                name: oauthJSON,
                purpose: "oauth_client_json",
                selected: oauthJSONSelected,
                containsSecret: true
            ))
            statuses.append(environmentStatus(
                name: oauthPath,
                purpose: "oauth_client_path",
                selected: !oauthJSONSelected && nonBlank(environment[oauthPath]) != nil,
                containsSecret: false
            ))
            statuses.append(environmentStatus(
                name: tokenJSON,
                purpose: "token_store_json",
                selected: tokenJSONSelected,
                containsSecret: true
            ))
            statuses.append(environmentStatus(
                name: tokenPath,
                purpose: "token_store_path",
                selected: !tokenJSONSelected && nonBlank(environment[tokenPath]) != nil,
                containsSecret: false
            ))
        }
        return statuses
    }

    private func environmentStatus(
        name: String,
        purpose: String,
        selected: Bool,
        containsSecret: Bool
    ) -> [String: Any] {
        [
            "name": name,
            "purpose": purpose,
            "set": nonBlank(environment[name]) != nil,
            "selected": selected,
            "containsSecret": containsSecret
        ]
    }

    private func inspectCredential(
        _ credential: CredentialConfig,
        issues: inout [[String: Any]]
    ) -> [String: Any] {
        let accessModeReady = mode.requiredCapability.map { credential.accessMode.grants($0) } ?? true
        if let capability = mode.requiredCapability,
           !accessModeReady {
            let accepted = AccessMode.modesGranting(capability).map(\.rawValue).joined(separator: " or ")
            issues.append(issue(
                category: "CONFIGURATION",
                code: "ACCESS_MODE_INSUFFICIENT",
                message: "Credential \(credential.id) requires \(accepted) access for \(mode.executableName)",
                credentialId: credential.id
            ))
        }

        let oauthSource = credentialSource(
            credentialId: credential.id,
            jsonValueKey: "oauth_client_secret_json",
            pathKey: "oauth_client_secret_path"
        )
        let oauthReady: Bool
        var oauthIssue: String?
        do {
            _ = try loadGoogleOAuthClient(credential: credential, use: .desktopLogin)
            oauthReady = true
        } catch let error as GmailGatewayError {
            oauthReady = false
            oauthIssue = error.message
            issues.append(issue(
                category: "CONFIGURATION",
                code: "OAUTH_CLIENT_INVALID",
                message: error.message,
                credentialId: credential.id
            ))
        } catch {
            oauthReady = false
            oauthIssue = "Failed to inspect OAuth client configuration"
            issues.append(issue(
                category: "CONFIGURATION",
                code: "OAUTH_CLIENT_INVALID",
                message: "Failed to inspect OAuth client configuration for credential \(credential.id)",
                credentialId: credential.id
            ))
        }

        let token = inspectTokenStore(credential: credential)
        let authReady = token.state == .ready
        if !authReady {
            issues.append(issue(
                category: "AUTHENTICATION",
                code: "AUTH_\(token.state.rawValue)",
                message: "Credential \(credential.id) authentication state is \(token.state.rawValue)",
                credentialId: credential.id
            ))
        }

        return [
            "id": credential.id,
            "provider": credential.provider.rawValue,
            "configuredAccessMode": credential.accessMode.rawValue,
            "requiredCapability": mode.requiredCapability?.rawValue as Any? ?? NSNull(),
            "acceptedAccessModes": mode.requiredCapability
                .map { AccessMode.modesGranting($0).map(\.rawValue) } ?? AccessMode.allRawValues,
            "accessModeReady": accessModeReady,
            "oauthClient": [
                "ready": oauthReady,
                "source": oauthSource,
                "path": credential.oauthClientSecretPath,
                "issue": oauthIssue as Any? ?? NSNull()
            ],
            "auth": [
                "ready": authReady,
                "state": token.state.rawValue,
                "source": credentialSource(
                    credentialId: credential.id,
                    jsonValueKey: "token_store_json",
                    pathKey: "token_store_path"
                ),
                "tokenStorePath": credential.tokenStorePath,
                "tokenStoreExists": token.exists,
                "grantedAccessMode": token.grantedAccessMode?.rawValue as Any? ?? NSNull(),
                "expiresAt": token.expiresAt as Any? ?? NSNull(),
                "hasRefreshToken": token.hasRefreshToken,
                "emailAddress": token.emailAddress as Any? ?? NSNull()
            ]
        ]
    }

    private func credentialSource(
        credentialId: String,
        jsonValueKey: String,
        pathKey: String
    ) -> String {
        let jsonName = GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
            credentialId: credentialId,
            valueKey: jsonValueKey
        )
        if nonBlank(environment[jsonName]) != nil {
            return "ENVIRONMENT_JSON"
        }
        let pathName = GmailGatewayConfigLoader.getCredentialPathEnvVarName(
            credentialId: credentialId,
            pathKey: pathKey
        )
        if nonBlank(environment[pathName]) != nil {
            return "ENVIRONMENT_PATH"
        }
        return "CONFIG_PATH"
    }

    private func inspectAccount(
        _ account: AccountConfig,
        config: GmailGatewayConfig,
        issues: inout [[String: Any]]
    ) -> [String: Any] {
        let credential = config.credentials.first { $0.id == account.credentialId }
        let authenticatedEmail = credential.flatMap { inspectTokenStore(credential: $0).emailAddress }
        let identityMatches = authenticatedEmail.map {
            $0.caseInsensitiveCompare(account.emailAddress) == .orderedSame
        }
        if identityMatches == false {
            issues.append(issue(
                category: "AUTHENTICATION",
                code: "ACCOUNT_IDENTITY_MISMATCH",
                message: "Account \(account.id) email does not match its authenticated Gmail identity",
                credentialId: account.credentialId,
                accountId: account.id
            ))
        }
        return [
            "id": account.id,
            "credentialId": account.credentialId,
            "configuredEmailAddress": account.emailAddress,
            "authenticatedEmailAddress": authenticatedEmail as Any? ?? NSNull(),
            "identityMatches": identityMatches as Any? ?? NSNull(),
            "fallback": account.isFallback
        ]
    }

    private func issue(
        category: String,
        code: String,
        message: String,
        credentialId: String? = nil,
        accountId: String? = nil
    ) -> [String: Any] {
        var value: [String: Any] = [
            "category": category,
            "code": code,
            "message": message
        ]
        if let credentialId {
            value["credentialId"] = credentialId
        }
        if let accountId {
            value["accountId"] = accountId
        }
        return value
    }
}
