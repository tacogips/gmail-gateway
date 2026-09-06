import Foundation
import GatewaySDKKit
import GoogleServiceGatewayCore

public enum GmailGatewayCLIMode: Sendable {
    case reader
    case draftGateway
    case directSender
    case mailboxThreads
    case messageBox

    var executableName: String {
        switch self {
        case .reader:
            return "gmail-gateway-reader"
        case .draftGateway:
            return "gmail-gateway-draft"
        case .directSender:
            return "gmail-gateway-sender"
        case .mailboxThreads:
            return "gmail-gateway-threads"
        case .messageBox:
            return "gmail-gateway-message-box"
        }
    }

    /// The capability this binary needs beyond reading. Nil for the read-only binary.
    var requiredCapability: MailboxCapability? {
        switch self {
        case .reader:
            return nil
        case .draftGateway, .directSender:
            return .send
        case .mailboxThreads:
            return .modify
        case .messageBox:
            return .insert
        }
    }
}

public struct GmailGatewayCLI {
    private let mode: GmailGatewayCLIMode
    private let authPolicy: GmailAuthPolicy
    private let secureCredentialStore: (any SecureCredentialStore)?
    private let configurationLoaded: @Sendable (GmailGatewayConfig) -> Void

    public init(
        mode: GmailGatewayCLIMode = .reader,
        authPolicy: GmailAuthPolicy = .legacy,
        secureCredentialStore: (any SecureCredentialStore)? = nil
    ) {
        self.init(
            mode: mode,
            authPolicy: authPolicy,
            secureCredentialStore: secureCredentialStore,
            configurationLoaded: { _ in }
        )
    }

    init(
        mode: GmailGatewayCLIMode = .reader,
        authPolicy: GmailAuthPolicy = .legacy,
        secureCredentialStore: (any SecureCredentialStore)? = nil,
        configurationLoaded: @escaping @Sendable (GmailGatewayConfig) -> Void
    ) {
        self.mode = mode
        self.authPolicy = authPolicy
        self.secureCredentialStore = secureCredentialStore
        self.configurationLoaded = configurationLoaded
    }

    public func runPersistent(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> GmailGatewayCommandResult {
        do {
            let parsed = try parseArguments(arguments)
            if shouldShowHelp(parsed) { return helpResult(for: parsed) }
            if shouldShowVersion(parsed) { return versionResult() }
            let configPathFlag = try getStringFlag(parsed.flags, "config")
            let configPath = configPathFlag ?? environment["GMAIL_GATEWAY_CONFIG"]
            let pretty = try getBooleanFlag(parsed.flags, "pretty")
            guard authPolicy.requiredAccessMode != nil else {
                return run(arguments: arguments, environment: environment)
            }
            let isConfigValidation = parsed.positionals.first == "config" && parsed.positionals.dropFirst().first == "validate"
            let config = try GmailGatewayConfigLoader.loadConfig(
                configPath: configPath,
                environment: environment,
                validateOAuthClientSecrets: isConfigValidation,
                allowMissingSynthesizedOAuthClient: isConfigValidation,
                deferSynthesizedOAuthClientValidation: isConfigValidation
            )
            configurationLoaded(config)
            let coordinator = GmailAuthCoordinator(
                config: config,
                environment: environment,
                policy: authPolicy,
                store: secureCredentialStore ?? KeychainCredentialStore(service: "com.tacogips.gmail-gateway")
            )
            if parsed.positionals.first == "auth" {
                return try await runPersistentAuth(
                    subcommand: parsed.positionals.dropFirst().first,
                    flags: parsed.flags,
                    coordinator: coordinator,
                    pretty: pretty
                )
            }
            if parsed.positionals.first == "config" {
                return try await runPersistentConfig(
                    subcommand: parsed.positionals.dropFirst().first,
                    config: config,
                    coordinator: coordinator,
                    pretty: pretty
                )
            }
            if parsed.positionals.first == "doctor" {
                return try await GmailGatewayDoctor(
                    mode: mode,
                    configPath: configPath,
                    configPathFromFlag: configPathFlag != nil,
                    environment: environment,
                    preloadedConfig: config
                ).runPersistent(coordinator: coordinator, pretty: pretty)
            }
            if parsed.positionals.first == "cache" {
                return try runCache(
                    subcommand: parsed.positionals.dropFirst().first,
                    flags: parsed.flags,
                    configPath: configPath,
                    environment: environment,
                    pretty: pretty
                )
            }
            if parsed.positionals.first == "file" {
                return try runFile(
                    subcommand: parsed.positionals.dropFirst().first,
                    parsed: parsed,
                    configPath: configPath,
                    environment: environment,
                    pretty: pretty
                )
            }
            if parsed.positionals.first == "graphql" {
                let preflight: PersistentGraphQLPreflight
                do {
                    preflight = try persistentGraphQLPreflight(
                        flags: parsed.flags,
                        config: config,
                        mode: mode
                    )
                } catch let error as GmailGatewayError {
                    return persistentGraphQLErrorResult(error, pretty: pretty)
                }
                let hydratedConfig: GmailGatewayConfig
                do {
                    hydratedConfig = preflight.credentialIds.isEmpty
                        ? config
                        : try await coordinator.hydratedConfig(credentialIds: preflight.credentialIds)
                } catch let error as GmailGatewayError {
                    return persistentGraphQLErrorResult(error, pretty: pretty)
                }
                let persistentEnvironment = persistentGraphQLEnvironment(
                    environment,
                    config: hydratedConfig
                )
                return try runGraphQL(
                    positionals: Array(parsed.positionals.dropFirst()),
                    flags: parsed.flags,
                    repeatedFlags: parsed.repeatedFlags,
                    environment: persistentEnvironment,
                    pretty: pretty,
                    config: hydratedConfig
                )
            }
            return run(arguments: arguments, environment: environment)
        } catch let error as GmailGatewayError {
            return GmailGatewayCommandResult(exitCode: error.exitCode.rawValue, stdout: "", stderr: jsonString(errorOutput(error), pretty: true) + "\n")
        } catch {
            let appError = GmailGatewayError(String(describing: error), code: .unexpectedError, exitCode: .generalError)
            return GmailGatewayCommandResult(exitCode: appError.exitCode.rawValue, stdout: "", stderr: jsonString(errorOutput(appError), pretty: true) + "\n")
        }
    }

    public func run(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GmailGatewayCommandResult {
        do {
            let parsed = try parseArguments(arguments)
            if shouldShowHelp(parsed) {
                return helpResult(for: parsed)
            }
            if shouldShowVersion(parsed) {
                return versionResult()
            }
            let configPathFlag = try getStringFlag(parsed.flags, "config")
            let configPath = configPathFlag ?? environment["GMAIL_GATEWAY_CONFIG"]
            let pretty = try getBooleanFlag(parsed.flags, "pretty")
            return try runParsedCommand(
                parsed,
                configPath: configPath,
                configPathFromFlag: configPathFlag != nil,
                environment: environment,
                pretty: pretty
            )
        } catch let error as GmailGatewayError {
            return GmailGatewayCommandResult(
                exitCode: error.exitCode.rawValue,
                stdout: "",
                stderr: jsonString(errorOutput(error), pretty: true) + "\n"
            )
        } catch {
            let appError = GmailGatewayError(
                String(describing: error),
                code: .unexpectedError,
                exitCode: .generalError
            )
            return GmailGatewayCommandResult(
                exitCode: appError.exitCode.rawValue,
                stdout: "",
                stderr: jsonString(errorOutput(appError), pretty: true) + "\n"
            )
        }
    }

    private func shouldShowHelp(_ parsed: ParsedArgs) -> Bool {
        parsed.flags["help"] != nil || parsed.positionals.first == "help"
    }

    private func shouldShowVersion(_ parsed: ParsedArgs) -> Bool {
        parsed.flags["version"] != nil || parsed.positionals.first == "version"
    }

    private func versionResult() -> GmailGatewayCommandResult {
        GmailGatewayCommandResult(
            exitCode: GmailGatewayExitCode.success.rawValue,
            stdout: "\(gmailGatewayVersion())\n",
            stderr: ""
        )
    }

    private func helpResult(for parsed: ParsedArgs) -> GmailGatewayCommandResult {
        let topic = parsed.positionals.first == "help"
            ? parsed.positionals.dropFirst().first
            : parsed.positionals.first
        let text = topic == "file" ? fileHelpText(executableName: mode.executableName) : rootHelpText(mode: mode)
        return GmailGatewayCommandResult(
            exitCode: GmailGatewayExitCode.success.rawValue,
            stdout: text,
            stderr: ""
        )
    }

    private func runParsedCommand(
        _ parsed: ParsedArgs,
        configPath: String?,
        configPathFromFlag: Bool,
        environment: [String: String],
        pretty: Bool
    ) throws -> GmailGatewayCommandResult {
        let command = parsed.positionals.first
        let subcommand = parsed.positionals.dropFirst().first
        switch command {
        case "doctor":
            return try GmailGatewayDoctor(
                mode: mode,
                configPath: configPath,
                configPathFromFlag: configPathFromFlag,
                environment: environment
            ).run(pretty: pretty)
        case "graphql":
            return try runGraphQL(
                positionals: Array(parsed.positionals.dropFirst()),
                flags: parsed.flags,
                repeatedFlags: parsed.repeatedFlags,
                environment: environment,
                pretty: pretty
            )
        case "config":
            return try runConfig(
                subcommand: subcommand,
                configPath: configPath,
                environment: environment,
                pretty: pretty
            )
        case "auth":
            return try runAuth(
                subcommand: subcommand,
                flags: parsed.flags,
                configPath: configPath,
                environment: environment,
                pretty: pretty
            )
        case "cache":
            return try runCache(
                subcommand: subcommand,
                flags: parsed.flags,
                configPath: configPath,
                environment: environment,
                pretty: pretty
            )
        case "file":
            return try runFile(
                subcommand: subcommand,
                parsed: parsed,
                configPath: configPath,
                environment: environment,
                pretty: pretty
            )
        default:
            throw GmailGatewayError(
                "Supported commands: doctor, graphql, config validate, auth <login|revoke|status>, cache prune, file download",
                code: .invalidArgument,
                exitCode: .invalidCliUsage
            )
        }
    }

    private func runGraphQL(
        positionals: [String],
        flags: [String: StringOrBool],
        repeatedFlags: [String: [StringOrBool]],
        environment: [String: String],
        pretty: Bool,
        config preloadedConfig: GmailGatewayConfig? = nil
    ) throws -> GmailGatewayCommandResult {
        let subcommand = positionals.first
        try validateGraphQLInvocation(positionals: positionals, repeatedFlags: repeatedFlags)
        let catalog = GatewaySchemaCatalog.gmail(mode: mode)
        if subcommand == "schema" {
            return GmailGatewayCommandResult(exitCode: 0, stdout: catalog.sdl(), stderr: "")
        }
        if subcommand == "search" {
            guard let pattern = positionals.dropFirst().first else {
                throw GmailGatewayError("graphql search requires a regex", code: .invalidArgument, exitCode: .invalidCliUsage)
            }
            let matches: [GatewaySchemaSearch.Match]
            do {
                let kinds = try graphQLSearchKinds(flags)
                let options = GatewaySchemaSearch.Options(
                    kinds: kinds,
                    includeReferencedTypes: try getBooleanFlag(flags, "include-referenced-types"),
                    limit: try optionalLimit(flags)
                )
                matches = try GatewaySchemaSearch(catalog: catalog).search(pattern, options: options)
            } catch let error as GatewaySDKError {
                return try graphQLCatalogErrorResult(error, pretty: pretty)
            }
            let encoded = try JSONEncoder().encode(matches)
            let json = String(bytes: encoded, encoding: .utf8) ?? ""
            let payload = try GatewayJSONValue.parse(json)
            return GmailGatewayCommandResult(exitCode: 0, stdout: try payload.jsonString(pretty: pretty) + "\n", stderr: "")
        }
        let variables = try loadGatewayVariables(flags: flags)
        let document: String
        if subcommand == "operation" {
            guard let operation = positionals.dropFirst().first else {
                throw GmailGatewayError("graphql operation requires an operation name", code: .invalidArgument, exitCode: .invalidCliUsage)
            }
            let selection = try getStringFlag(flags, "select").map { GatewaySelection.fields($0.split(separator: ",").map(String.init)) } ?? .default
            do {
                // Build from the full catalog so a known operation outside this binary's
                // authorized catalog reaches the shared runtime authorization boundary.
                // The executor then reports CAPABILITY_DENIED with the mode tier rather
                // than treating the operation as unknown.
                document = try GmailGatewayOperationBoundary
                    .build(.init(operation: operation, variables: variables, selection: selection)).document
            } catch let error as GatewaySDKError {
                return try graphQLCatalogErrorResult(error, pretty: pretty)
            }
        } else {
            guard subcommand == nil || subcommand == "query" else {
                throw GmailGatewayError("graphql requires query, schema, search, or operation", code: .invalidArgument, exitCode: .invalidCliUsage)
            }
            document = try loadQuery(flags: flags)
        }
        var effectiveEnvironment = persistentGraphQLEnvironment(environment, config: preloadedConfig)
        if let configPath = try getStringFlag(flags, "config") { effectiveEnvironment["GMAIL_GATEWAY_CONFIG"] = configPath }
        let envelope = awaitEnvelope(query: document, variables: variables, environment: effectiveEnvironment)
        return try graphQLEnvelopeResult(envelope, pretty: pretty)
    }

    private func validateGraphQLInvocation(
        positionals: [String],
        repeatedFlags: [String: [StringOrBool]]
    ) throws {
        let subcommand = positionals.first
        let allowedFlags: Set<String>
        switch subcommand {
        case nil, "query":
            guard positionals.count <= 1 else {
                throw invalidGraphQLInvocation("graphql query does not accept extra positional arguments")
            }
            allowedFlags = ["config", "pretty", "query", "query-file", "variables", "variables-file"]
        case "schema":
            guard positionals.count == 1 else {
                throw invalidGraphQLInvocation("graphql schema does not accept positional arguments")
            }
            allowedFlags = []
        case "search":
            guard positionals.count == 2 else {
                throw invalidGraphQLInvocation("graphql search requires exactly one regex")
            }
            allowedFlags = ["pretty", "kinds", "include-referenced-types", "limit"]
        case "operation":
            guard positionals.count == 2 else {
                throw invalidGraphQLInvocation("graphql operation requires exactly one operation name")
            }
            allowedFlags = ["config", "pretty", "variables", "variables-file", "select"]
        default:
            throw invalidGraphQLInvocation("graphql requires query, schema, search, or operation")
        }

        let unsupported = Set(repeatedFlags.keys).subtracting(allowedFlags)
        guard unsupported.isEmpty else {
            let names = unsupported.sorted().map { "--\($0)" }.joined(separator: ", ")
            throw invalidGraphQLInvocation("Unsupported GraphQL flag: \(names)")
        }
        let duplicates = repeatedFlags.filter { $0.value.count > 1 }.keys.sorted()
        guard duplicates.isEmpty else {
            let names = duplicates.map { "--\($0)" }.joined(separator: ", ")
            throw invalidGraphQLInvocation("Duplicate GraphQL flag: \(names)")
        }
    }

    private func invalidGraphQLInvocation(_ message: String) -> GmailGatewayError {
        GmailGatewayError(message, code: .invalidArgument, exitCode: .invalidCliUsage)
    }

    private func graphQLCatalogErrorResult(
        _ error: GatewaySDKError,
        pretty: Bool
    ) throws -> GmailGatewayCommandResult {
        let envelope = GmailGatewayOperationBoundary.errorEnvelope(error)
        return try graphQLEnvelopeResult(envelope, pretty: pretty)
    }

    private func graphQLEnvelopeResult(
        _ envelope: GatewayEnvelope,
        pretty: Bool
    ) throws -> GmailGatewayCommandResult {
        return GmailGatewayCommandResult(
            exitCode: envelope.exitCode,
            stdout: try GmailGatewayGraphQLEnvelopeSerializer.output(envelope, pretty: pretty),
            stderr: ""
        )
    }

    private func awaitEnvelope(query: String, variables: [String: GatewayJSONValue], environment: [String: String]) -> GatewayEnvelope {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedEnvelope()
        let selectedMode = mode
        Self.executorBridgeQueue.async {
            Task.detached {
                result.value = await GmailGatewayGraphQLExecutor().run(
                    query: query,
                    variables: variables,
                    mode: selectedMode,
                    environment: environment,
                    configurationPolicy: .cliDefaults
                )
                semaphore.signal()
            }
        }
        semaphore.wait()
        return result.value
    }

    private static let executorBridgeQueue = DispatchQueue(
        label: "gmail-gateway.cli.executor-bridge",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private func runConfig(
        subcommand: String?,
        configPath: String?,
        environment: [String: String],
        pretty: Bool
    ) throws -> GmailGatewayCommandResult {
        guard subcommand == "validate" else {
            throw GmailGatewayError(
                "config requires the validate subcommand",
                code: .invalidArgument,
                exitCode: .invalidCliUsage
            )
        }
        return success(
            try GmailGatewayConfigLoader.validateConfig(configPath: configPath, environment: environment),
            pretty: pretty
        )
    }

    private func runPersistentConfig(
        subcommand: String?,
        config: GmailGatewayConfig,
        coordinator: GmailAuthCoordinator,
        pretty: Bool
    ) async throws -> GmailGatewayCommandResult {
        guard subcommand == "validate" else {
            throw GmailGatewayError(
                "config requires the validate subcommand",
                code: .invalidArgument,
                exitCode: .invalidCliUsage
            )
        }
        try await coordinator.validatePersistentConfigSources()
        return success(GmailGatewayConfigLoader.validationOutput(config), pretty: pretty)
    }

    private func runAuth(
        subcommand: String?,
        flags: [String: StringOrBool],
        configPath: String?,
        environment: [String: String],
        pretty: Bool
    ) throws -> GmailGatewayCommandResult {
        guard let credentialId = try getStringFlag(flags, "credential") else {
            throw GmailGatewayError(
                "auth commands require --credential",
                code: .invalidArgument,
                exitCode: .invalidCliUsage
            )
        }
        let service = try readerService(configPath: configPath, environment: environment)
        switch subcommand {
        case "status":
            return success(try service.getAuthStatus(credentialId: credentialId), pretty: pretty)
        case "revoke":
            return success(try service.revokeAuth(credentialId: credentialId), pretty: pretty)
        case "login":
            return success(
                try service.login(
                    credentialId: credentialId,
                    options: GmailOAuthLoginOptions(
                        redirectURI: try getStringFlag(flags, "redirect-uri"),
                        openBrowser: try getBooleanFlag(flags, "open-browser", defaultValue: true),
                        timeoutSeconds: Int32(try getIntFlag(
                            flags,
                            "timeout-seconds",
                            defaultValue: Int(GmailOAuthLoginOptions.defaultTimeoutSeconds),
                            minimum: 1,
                            maximum: 3_600
                        ))
                    )
                ),
                pretty: pretty
            )
        default:
            throw GmailGatewayError(
                "auth requires one of: login, revoke, status",
                code: .invalidArgument,
                exitCode: .invalidCliUsage
            )
        }
    }

    private func runPersistentAuth(
        subcommand: String?,
        flags: [String: StringOrBool],
        coordinator: GmailAuthCoordinator,
        pretty: Bool
    ) async throws -> GmailGatewayCommandResult {
        guard let credentialId = try getStringFlag(flags, "credential") else {
            throw GmailGatewayError("auth commands require --credential", code: .invalidArgument, exitCode: .invalidCliUsage)
        }
        switch subcommand {
        case "setup":
            guard let clientSecretPath = try getStringFlag(flags, "client-secret-path") else {
                throw GmailGatewayError("auth setup requires --client-secret-path", code: .invalidArgument, exitCode: .invalidCliUsage)
            }
            let replace = try getBooleanFlag(flags, "replace")
            let confirmedCredentialId = try getStringFlag(flags, "confirm-credential")
            if replace, confirmedCredentialId != credentialId {
                throw GmailGatewayError("auth setup replacement requires an exact --confirm-credential", code: .invalidArgument, exitCode: .invalidCliUsage)
            }
            return success(try await coordinator.setup(
                credentialId: credentialId,
                options: GmailOAuthSetupOptions(
                    clientSecretPath: clientSecretPath,
                    replace: replace,
                    confirmedCredentialId: confirmedCredentialId
                )
            ), pretty: pretty)
        case "status":
            return success(try await coordinator.status(credentialId: credentialId), pretty: pretty)
        case "revoke":
            return success(try await coordinator.revoke(
                credentialId: credentialId,
                confirmedCredentialId: try getStringFlag(flags, "confirm-credential")
            ), pretty: pretty)
        case "login":
            return success(try await coordinator.login(
                credentialId: credentialId,
                options: GmailOAuthLoginOptions(
                    redirectURI: try getStringFlag(flags, "redirect-uri"),
                    openBrowser: try getBooleanFlag(flags, "open-browser", defaultValue: true),
                    timeoutSeconds: Int32(try getIntFlag(flags, "timeout-seconds", defaultValue: Int(GmailOAuthLoginOptions.defaultTimeoutSeconds), minimum: 1, maximum: 3_600))
                )
            ), pretty: pretty)
        default:
            throw GmailGatewayError("auth requires one of: setup, login, revoke, status", code: .invalidArgument, exitCode: .invalidCliUsage)
        }
    }

    private func runCache(
        subcommand: String?,
        flags: [String: StringOrBool],
        configPath: String?,
        environment: [String: String],
        pretty: Bool,
        config preloadedConfig: GmailGatewayConfig? = nil
    ) throws -> GmailGatewayCommandResult {
        guard subcommand == "prune" else {
            throw GmailGatewayError(
                "cache requires the prune subcommand",
                code: .invalidArgument,
                exitCode: .invalidCliUsage
            )
        }
        return success(
            try readerService(configPath: configPath, environment: environment, config: preloadedConfig).pruneCache(
                accountId: try getStringFlag(flags, "account"),
                all: try getBooleanFlag(flags, "all")
            ),
            pretty: pretty
        )
    }

    private func runFile(
        subcommand: String?,
        parsed: ParsedArgs,
        configPath: String?,
        environment: [String: String],
        pretty: Bool,
        config preloadedConfig: GmailGatewayConfig? = nil
    ) throws -> GmailGatewayCommandResult {
        guard subcommand == "download" else {
            throw GmailGatewayError(
                "file requires the download subcommand",
                code: .invalidArgument,
                exitCode: .invalidCliUsage
            )
        }
        let downloadKeys = try getStringFlags(parsed.repeatedFlags, "key")
        guard !downloadKeys.isEmpty else {
            throw GmailGatewayError(
                "file download requires --key",
                code: .invalidArgument,
                exitCode: .invalidCliUsage
            )
        }
        let service = try readerService(configPath: configPath, environment: environment, config: preloadedConfig)
        let outputDirectory = try getStringFlag(parsed.flags, "output-dir")
        if downloadKeys.count == 1 {
            return success(
                try service.downloadFile(downloadKey: downloadKeys[0], outputDirectory: outputDirectory),
                pretty: pretty
            )
        }
        return success(
            try service.downloadFiles(downloadKeys: downloadKeys, outputDirectory: outputDirectory),
            pretty: pretty
        )
    }

    private func readerService(
        configPath: String?,
        environment: [String: String],
        config preloadedConfig: GmailGatewayConfig? = nil
    ) throws -> GmailGatewayService {
        GmailGatewayService(
            config: try preloadedConfig ?? GmailGatewayConfigLoader.loadConfig(configPath: configPath, environment: environment)
        )
    }

    private func success(_ payload: [String: Any], pretty: Bool) -> GmailGatewayCommandResult {
        GmailGatewayCommandResult(
            exitCode: GmailGatewayExitCode.success.rawValue,
            stdout: jsonString(payload, pretty: pretty) + "\n",
            stderr: ""
        )
    }
}

private func persistentGraphQLErrorResult(
    _ error: GmailGatewayError,
    pretty: Bool
) -> GmailGatewayCommandResult {
    let envelope = GatewayEnvelope(
        errors: [GatewayEnvelopeError(message: error.message, code: error.code.rawValue)],
        exitCode: GmailGatewayExitCode.graphqlExecutionError.rawValue
    )
    let stdout = (try? GmailGatewayGraphQLEnvelopeSerializer.output(envelope, pretty: pretty)) ?? ""
    return GmailGatewayCommandResult(
        exitCode: GmailGatewayExitCode.graphqlExecutionError.rawValue,
        stdout: stdout,
        stderr: ""
    )
}

private struct PersistentGraphQLPreflight {
    let query: String
    let credentialIds: Set<String>
}

private func persistentGraphQLPreflight(
    flags: [String: StringOrBool],
    config: GmailGatewayConfig,
    mode: GmailGatewayCLIMode
) throws -> PersistentGraphQLPreflight {
    let query = try loadQuery(flags: flags)
    // GraphQL execution owns the public error body. Preflight only determines
    // which credentials may be hydrated after parsing, validation, and mode
    // authorization have all succeeded without provider or vault access.
    guard let document = try? GatewayGraphQLParser.parse(query),
          let operation = try? GatewayGraphQLValidator(catalog: .gmail(mode: mode)).validate(document) else {
        return PersistentGraphQLPreflight(query: query, credentialIds: [])
    }
    try validatePersistentGraphQLInputs(operation)
    let accountIDs = Set(operation.rootFields.compactMap(persistentGraphQLAccountID))
    let credentialIDs = Set(config.accounts.filter { accountIDs.contains($0.id) }.map(\.credentialId))
    return PersistentGraphQLPreflight(query: query, credentialIds: credentialIDs)
}

private func validatePersistentGraphQLInputs(_ operation: ValidatedOperation) throws {
    for field in operation.rootFields {
        guard case .object(let input) = field.arguments["input"] else {
            continue
        }
        if field.name == "threads",
           case .int(let first) = input["first"],
           !(1...500).contains(first) {
            throw persistentGraphQLInvalidArgument("ThreadSearchInput.first must be an integer from 1 through 500")
        }
        if field.name == "replyMessage" || field.name == "createReplyDraft" {
            let textBody = persistentGraphQLNonBlankString(input["textBody"])
            let htmlBody = persistentGraphQLNonBlankString(input["htmlBody"])
            if textBody == nil, htmlBody == nil {
                throw persistentGraphQLInvalidArgument("Reply input requires textBody or htmlBody")
            }
        }
    }
}

private func persistentGraphQLInvalidArgument(_ message: String) -> GmailGatewayError {
    GmailGatewayError(
        message,
        code: .invalidArgument,
        exitCode: .graphqlExecutionError
    )
}

private func persistentGraphQLNonBlankString(_ value: GatewayJSONValue?) -> String? {
    guard case .string(let text) = value,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    return text
}

private func persistentGraphQLAccountID(_ field: ValidatedOperation.RootField) -> String? {
    if case .string(let accountID) = field.arguments["accountId"] {
        return accountID
    }
    guard case .object(let input) = field.arguments["input"],
          case .string(let accountID) = input["accountId"] else {
        return nil
    }
    return accountID
}

private func persistentGraphQLEnvironment(
    _ environment: [String: String],
    config: GmailGatewayConfig?
) -> [String: String] {
    guard let config else {
        return environment
    }
    var effectiveEnvironment = environment
    effectiveEnvironment["GMAIL_GATEWAY_CONFIG"] = config.configPath
    for credential in config.credentials {
        if let clientJSON = credential.oauthClientSecretJSON {
            effectiveEnvironment[GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
                credentialId: credential.id,
                valueKey: "oauth_client_secret_json"
            )] = clientJSON
        }
        if let tokenJSON = credential.tokenStoreJSON {
            effectiveEnvironment[GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
                credentialId: credential.id,
                valueKey: "token_store_json"
            )] = tokenJSON
        }
    }
    return effectiveEnvironment
}

private func rootHelpText(mode: GmailGatewayCLIMode) -> String {
    let executableName = mode.executableName
    let authCommand = switch mode {
    case .reader, .draftGateway, .directSender:
        "auth <setup|login|revoke|status> --credential <id>"
    case .mailboxThreads, .messageBox:
        "auth <login|revoke|status> --credential <id>"
    }
    let persistentAuthText = switch mode {
    case .reader, .draftGateway, .directSender:
        """
        Persistent auth setup/revoke:
          auth setup --credential <id> --client-secret-path <path>
                     [--replace --confirm-credential <id>]
          auth revoke --credential <id> --confirm-credential <id>

        """
    case .mailboxThreads, .messageBox:
        ""
    }
    let writeNote: String
    switch mode {
    case .reader:
        writeNote = """
          This binary is read-only. Mutations outside its authorized GraphQL catalog are
          rejected with CAPABILITY_DENIED before resolver or provider dispatch.
          Read surface: accounts, account, threads, thread, message, messageFileSet,
          attachment, labels, and profile.
        """
    case .draftGateway:
        writeNote = """
          This binary is draft-only. It supports createDraft, createReplyDraft,
          createForwardDraft, updateDraft, and deleteDraft, plus the drafts and draft
          queries, and it can never send mail. createReplyDraft and createForwardDraft
          prepare threaded reply and forward drafts without sending them.
          sendMessage, replyMessage, forwardMessage, and sendDraft are rejected with
          CAPABILITY_DENIED before resolver or provider dispatch; use
          gmail-gateway-sender for those.

          updateDraft retains any header or body field it is not given. Supplying textBody
          and/or htmlBody replaces the whole body with exactly what was supplied. Attachments
          already on the draft are all retained unless keepAttachmentIds is given, in which case
          only the listed provider attachment ids survive; attachmentPaths adds local files on
          top, so keepAttachmentIds: [] with attachmentPaths replaces every attachment.
        """
    case .directSender:
        writeNote = """
          This binary is the explicit sender. sendMessage directly sends mail through the provider,
          replyMessage and forwardMessage directly send threaded replies and forwards, and
          sendDraft sends a draft that gmail-gateway-draft already prepared.
          It also supports the full draft surface: createDraft, createReplyDraft,
          createForwardDraft, updateDraft, deleteDraft, and the drafts and draft queries.
        """
    case .mailboxThreads:
        writeNote = """
          This binary mutates stored mail and never composes, sends, or ingests it.
          Label changes:  modifyThreadLabels, modifyMessageLabels, batchModifyMessageLabels
          Trash:          trashThread, untrashThread, trashMessage, untrashMessage
          Label managing: createLabel, updateLabel, deleteLabel
          Permanent:      deleteThread, deleteMessage, batchDeleteMessages

          Trash and label mutations need the read_modify access mode. The three permanent
          delete mutations are irreversible, bypass Trash, and need the full access mode,
          because the provider accepts only its full-access scope for them. Prefer
          trashThread and trashMessage unless a caller truly means to destroy mail.

          Draft, send, and ingest mutations are rejected here; use gmail-gateway-draft,
          gmail-gateway-sender, or gmail-gateway-message-box.
        """
    case .messageBox:
        writeNote = """
          This binary ingests existing RFC 822 mail into the mailbox and never composes,
          sends, or mutates stored mail. It supports importMessage and insertMessage, and
          needs the read_modify access mode.

          importMessage runs the normal delivery pipeline (spam classification, Calendar
          processing) and accepts neverMarkSpam and processForCalendar. insertMessage is a
          direct IMAP-APPEND-style add that bypasses most scanning. Neither sends mail.

          rfc822Path must resolve under a configured storage.allowed_send_attachment_roots
          entry, the same rule outbound attachments follow.

          Draft, send, and mailbox mutations are rejected here; use gmail-gateway-draft,
          gmail-gateway-sender, or gmail-gateway-threads.
        """
    }

    return """
\(executableName)

Usage:
  \(executableName) [--config <path>] [--pretty] <command>

Commands:
  doctor
  graphql [query] --query <query>|--query-file <path> [--variables <json>|--variables-file <path>] [--pretty]
  graphql schema
  graphql search <regex> [--kinds query,mutation,object,inputObject,enumeration] [--include-referenced-types] [--limit <n>]
  graphql operation <name> [--variables <json>|--variables-file <path>] [--select a.b,c]
  config validate
  \(authCommand)
  cache prune [--account <id>|--all]
  file download --key <download-key> [--key <download-key> ...] [--output-dir <dir>]
  --version

Auth login options:
  --redirect-uri <uri>       Optional registered loopback callback URI
                             (127.0.0.1, ::1, or localhost). Defaults to the
                             first stored redirect; a portless URI gets a
                             local ephemeral port while preserving its path.
  --open-browser <true|false>
                             Open the authorization URL automatically. Defaults to true.
  --timeout-seconds <n>      Seconds to wait for the OAuth2 callback. Defaults to 300.

\(persistentAuthText)

Write behavior:
\(writeNote)

File downloads:
  GraphQL returns attachment, body, and temporary-file metadata with
  vendor-neutral downloadKey values, not file payloads. Use file download when
  a caller explicitly needs selected file bytes. Repeat --key to download
  multiple selected files in one command.

  Single-key downloads return a single file JSON object with localPath.
  Multi-key downloads return {"fileCount": n, "files": [...]} and copy files
  under <output-dir>/<accountId>/<messageId>/<filename> to avoid collisions.

Examples:
  \(executableName) file download --config ./config.toml --key <key> --output-dir ./downloads
  \(executableName) file download --config ./config.toml --key <key-1> --key <key-2> --output-dir ./downloads

"""
}

private func fileHelpText(executableName: String) -> String {
    """
\(executableName) file download

Usage:
  \(executableName) file download --key <download-key> [--key <download-key> ...] [--output-dir <dir>]

Options:
  --key <download-key>    Vendor-neutral key returned by GraphQL file metadata.
                          Repeat this option to download multiple files.
  --output-dir <dir>      Optional destination under storage.attachment_dir,
                          storage.cache_dir, or the system temporary directory.

Output:
  With one --key, returns the existing single-file JSON object:
    {"kind":"BODY_TEXT","filename":"body.txt","localPath":"..."}

  With multiple --key values, returns:
    {"fileCount":2,"files":[...]}

  Batch downloads copy files under <output-dir>/<accountId>/<messageId>/<filename>
  so files from different messages cannot overwrite each other.

"""
}

private final class LockedEnvelope: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = GatewayEnvelope.failure(GmailGatewayError("executor did not return", code: .unexpectedError, exitCode: .generalError), exitCode: 1)

    var value: GatewayEnvelope {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private func graphQLSearchKinds(_ flags: [String: StringOrBool]) throws -> Set<GatewayDefinitionKind> {
    guard let value = try getStringFlag(flags, "kinds") else { return [.query, .mutation, .object, .inputObject, .enumeration] }
    let kinds = value.split(separator: ",").compactMap { GatewayDefinitionKind(rawValue: String($0)) }
    guard !kinds.isEmpty, kinds.count == value.split(separator: ",").count else {
        throw GmailGatewayError("--kinds must contain schema definition kinds", code: .invalidArgument, exitCode: .invalidCliUsage)
    }
    return Set(kinds)
}

private func optionalLimit(_ flags: [String: StringOrBool]) throws -> Int? {
    guard let raw = try getStringFlag(flags, "limit") else {
        return nil
    }
    guard let value = Int(raw), value > 0 else {
        throw GmailGatewayError(
            "--limit must be a positive integer",
            code: .invalidArgument,
            exitCode: .invalidCliUsage
        )
    }
    return value
}
