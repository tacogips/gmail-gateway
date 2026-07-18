import Foundation

struct MailGatewayDoctor {
    let mode: MailGatewayCLIMode
    let configPath: String?
    let configPathFromFlag: Bool
    let environment: [String: String]

    func run(pretty: Bool) throws -> MailGatewayCommandResult {
        let config = try MailGatewayConfigLoader.loadConfig(configPath: configPath, environment: environment)
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
        let exitCode: MailGatewayExitCode
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
        return MailGatewayCommandResult(
            exitCode: exitCode.rawValue,
            stdout: jsonString(payload, pretty: pretty) + "\n",
            stderr: ""
        )
    }

    private func inspectConfig(_ config: MailGatewayConfig) -> [String: Any] {
        let exists = FileManager.default.isReadableFile(atPath: config.configPath)
        let source: String
        if configPathFromFlag {
            source = "COMMAND_LINE"
        } else if nonBlank(environment["MAIL_GATEWAY_CONFIG"]) != nil {
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

    private func inspectEnvironment(config: MailGatewayConfig) -> [[String: Any]] {
        var statuses: [[String: Any]] = [
            environmentStatus(
                name: "MAIL_GATEWAY_CONFIG",
                purpose: "config_path",
                selected: !configPathFromFlag && nonBlank(environment["MAIL_GATEWAY_CONFIG"]) != nil,
                containsSecret: false
            )
        ]
        for credential in config.credentials.sorted(by: { $0.id < $1.id }) {
            let oauthJSON = MailGatewayConfigLoader.getCredentialJSONEnvVarName(
                credentialId: credential.id,
                valueKey: "oauth_client_secret_json"
            )
            let oauthPath = MailGatewayConfigLoader.getCredentialPathEnvVarName(
                credentialId: credential.id,
                pathKey: "oauth_client_secret_path"
            )
            let tokenJSON = MailGatewayConfigLoader.getCredentialJSONEnvVarName(
                credentialId: credential.id,
                valueKey: "token_store_json"
            )
            let tokenPath = MailGatewayConfigLoader.getCredentialPathEnvVarName(
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
        let requiredAccessMode: AccessMode
        switch mode {
        case .reader:
            requiredAccessMode = .read
        case .draftGateway, .directSender:
            requiredAccessMode = .readSend
        }
        let accessModeReady = requiredAccessMode == .read || credential.accessMode == .readSend
        if !accessModeReady {
            issues.append(issue(
                category: "CONFIGURATION",
                code: "ACCESS_MODE_INSUFFICIENT",
                message: "Credential \(credential.id) requires read_send access for \(mode.executableName)",
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
        } catch let error as MailGatewayError {
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
            "requiredAccessMode": requiredAccessMode.rawValue,
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
        let jsonName = MailGatewayConfigLoader.getCredentialJSONEnvVarName(
            credentialId: credentialId,
            valueKey: jsonValueKey
        )
        if nonBlank(environment[jsonName]) != nil {
            return "ENVIRONMENT_JSON"
        }
        let pathName = MailGatewayConfigLoader.getCredentialPathEnvVarName(
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
        config: MailGatewayConfig,
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
