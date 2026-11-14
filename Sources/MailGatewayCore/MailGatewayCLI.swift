import Foundation

public enum MailGatewayCLIMode: Sendable {
    case reader
    case draftGateway
    case directSender

    var executableName: String {
        switch self {
        case .reader:
            return "mail-gateway-reader"
        case .draftGateway:
            return "mail-gateway-draft"
        case .directSender:
            return "mail-gateway-sender"
        }
    }
}

public struct MailGatewayCLI {
    private let mode: MailGatewayCLIMode

    public init(mode: MailGatewayCLIMode = .reader) {
        self.mode = mode
    }

    public func run(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MailGatewayCommandResult {
        do {
            let parsed = try parseArguments(arguments)
            if shouldShowHelp(parsed) {
                return helpResult(for: parsed)
            }
            let configPath = try getStringFlag(parsed.flags, "config") ?? environment["MAIL_GATEWAY_CONFIG"]
            let pretty = try getBooleanFlag(parsed.flags, "pretty")
            return try runParsedCommand(
                parsed,
                configPath: configPath,
                environment: environment,
                pretty: pretty
            )
        } catch let error as MailGatewayError {
            return MailGatewayCommandResult(
                exitCode: error.exitCode.rawValue,
                stdout: "",
                stderr: jsonString(errorOutput(error), pretty: true) + "\n"
            )
        } catch {
            let appError = MailGatewayError(
                String(describing: error),
                code: .configInvalid,
                exitCode: .generalError
            )
            return MailGatewayCommandResult(
                exitCode: appError.exitCode.rawValue,
                stdout: "",
                stderr: jsonString(errorOutput(appError), pretty: true) + "\n"
            )
        }
    }

    private func shouldShowHelp(_ parsed: ParsedArgs) -> Bool {
        parsed.flags["help"] != nil || parsed.positionals.first == "help"
    }

    private func helpResult(for parsed: ParsedArgs) -> MailGatewayCommandResult {
        let topic = parsed.positionals.first == "help"
            ? parsed.positionals.dropFirst().first
            : parsed.positionals.first
        let text = topic == "file" ? fileHelpText(executableName: mode.executableName) : rootHelpText(mode: mode)
        return MailGatewayCommandResult(
            exitCode: MailGatewayExitCode.success.rawValue,
            stdout: text,
            stderr: ""
        )
    }

    private func runParsedCommand(
        _ parsed: ParsedArgs,
        configPath: String?,
        environment: [String: String],
        pretty: Bool
    ) throws -> MailGatewayCommandResult {
        let command = parsed.positionals.first
        let subcommand = parsed.positionals.dropFirst().first
        switch command {
        case "graphql":
            return try runGraphQL(
                flags: parsed.flags,
                configPath: configPath,
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
            throw MailGatewayError(
                "Supported commands: graphql, config validate, auth <login|revoke|status>, cache prune, file download",
                code: .invalidArgument,
                exitCode: .invalidCliUsage
            )
        }
    }

    private func runGraphQL(
        flags: [String: StringOrBool],
        configPath: String?,
        environment: [String: String],
        pretty: Bool
    ) throws -> MailGatewayCommandResult {
        let config = try MailGatewayConfigLoader.loadConfig(configPath: configPath, environment: environment)
        let query = try loadQuery(flags: flags)
        _ = try loadVariables(flags: flags)
        let result: (body: [String: Any], exitCode: MailGatewayExitCode)
        switch mode {
        case .reader:
            result = try executeReaderGraphQL(config: config, query: query)
        case .draftGateway:
            result = try executeWriteGraphQL(config: config, query: query, mode: .draftDefault)
        case .directSender:
            result = try executeWriteGraphQL(config: config, query: query, mode: .directSend)
        }
        return MailGatewayCommandResult(
            exitCode: result.exitCode.rawValue,
            stdout: jsonString(result.body, pretty: pretty) + "\n",
            stderr: ""
        )
    }

    private func runConfig(
        subcommand: String?,
        configPath: String?,
        environment: [String: String],
        pretty: Bool
    ) throws -> MailGatewayCommandResult {
        guard subcommand == "validate" else {
            throw MailGatewayError(
                "config requires the validate subcommand",
                code: .invalidArgument,
                exitCode: .invalidCliUsage
            )
        }
        return success(
            try MailGatewayConfigLoader.validateConfig(configPath: configPath, environment: environment),
            pretty: pretty
        )
    }

    private func runAuth(
        subcommand: String?,
        flags: [String: StringOrBool],
        configPath: String?,
        environment: [String: String],
        pretty: Bool
    ) throws -> MailGatewayCommandResult {
        guard let credentialId = try getStringFlag(flags, "credential") else {
            throw MailGatewayError(
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
            return success(try service.login(credentialId: credentialId), pretty: pretty)
        default:
            throw MailGatewayError(
                "auth requires one of: login, revoke, status",
                code: .invalidArgument,
                exitCode: .invalidCliUsage
            )
        }
    }

    private func runCache(
        subcommand: String?,
        flags: [String: StringOrBool],
        configPath: String?,
        environment: [String: String],
        pretty: Bool
    ) throws -> MailGatewayCommandResult {
        guard subcommand == "prune" else {
            throw MailGatewayError(
                "cache requires the prune subcommand",
                code: .invalidArgument,
                exitCode: .invalidCliUsage
            )
        }
        return success(
            try readerService(configPath: configPath, environment: environment).pruneCache(
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
        pretty: Bool
    ) throws -> MailGatewayCommandResult {
        guard subcommand == "download" else {
            throw MailGatewayError(
                "file requires the download subcommand",
                code: .invalidArgument,
                exitCode: .invalidCliUsage
            )
        }
        let downloadKeys = try getStringFlags(parsed.repeatedFlags, "key")
        guard !downloadKeys.isEmpty else {
            throw MailGatewayError(
                "file download requires --key",
                code: .invalidArgument,
                exitCode: .invalidCliUsage
            )
        }
        let service = try readerService(configPath: configPath, environment: environment)
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
        environment: [String: String]
    ) throws -> MailGatewayReaderService {
        MailGatewayReaderService(
            config: try MailGatewayConfigLoader.loadConfig(configPath: configPath, environment: environment)
        )
    }

    private func success(_ payload: [String: Any], pretty: Bool) -> MailGatewayCommandResult {
        MailGatewayCommandResult(
            exitCode: MailGatewayExitCode.success.rawValue,
            stdout: jsonString(payload, pretty: pretty) + "\n",
            stderr: ""
        )
    }
}

private func rootHelpText(mode: MailGatewayCLIMode) -> String {
    let executableName = mode.executableName
    let writeNote: String
    switch mode {
    case .reader:
        writeNote = """
          This binary is read-only. Write mutations are rejected with SEND_DISABLED_IN_READER.
        """
    case .draftGateway:
        writeNote = """
          This binary is draft-first. sendMessage creates a provider draft and does not directly send mail.
        """
    case .directSender:
        writeNote = """
          This binary is the explicit sender. sendMessage directly sends mail through the provider, and createDraft creates a provider draft.
        """
    }

    return """
\(executableName)

Usage:
  \(executableName) [--config <path>] [--pretty] <command>

Commands:
  graphql --query <query>
  config validate
  auth <login|revoke|status> --credential <id>
  cache prune [--account <id>|--all]
  file download --key <download-key> [--key <download-key> ...] [--output-dir <dir>]

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
