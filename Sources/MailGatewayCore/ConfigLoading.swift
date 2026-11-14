import Foundation

private enum TomlSection {
    case none
    case storage
    case credential(Int)
    case account(Int)
}

private struct CredentialPathRequest {
    let configPath: String
    let credentialId: String
    let pathKey: String
    let configValue: String?
    let environment: [String: String]
    let context: String
}

public enum MailGatewayConfigLoader {
    private static let defaultCredentialId = "gmail-personal"
    private static let defaultAccountId = "personal"

    public static func getCredentialPathEnvVarName(credentialId: String, pathKey: String) -> String {
        let safeSuffix = credentialEnvSuffix(credentialId)
        if pathKey == "oauth_client_secret_path" {
            return "MAIL_GATEWAY_CREDENTIAL_\(safeSuffix)_OAUTH_CLIENT_SECRET_PATH"
        }
        return "MAIL_GATEWAY_CREDENTIAL_\(safeSuffix)_TOKEN_STORE_PATH"
    }

    public static func getCredentialJSONEnvVarName(credentialId: String, valueKey: String) -> String {
        let safeSuffix = credentialEnvSuffix(credentialId)
        if valueKey == "oauth_client_secret_json" {
            return "MAIL_GATEWAY_CREDENTIAL_\(safeSuffix)_OAUTH_CLIENT_SECRET_JSON"
        }
        return "MAIL_GATEWAY_CREDENTIAL_\(safeSuffix)_TOKEN_STORE_JSON"
    }

    private static func credentialEnvSuffix(_ credentialId: String) -> String {
        let suffix = credentialId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "_"
            }
        let normalized = String(suffix)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            .uppercased()
        return normalized.isEmpty ? "CREDENTIAL" : normalized
    }

    public static func resolveDefaultConfigPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let xdgConfigHome = nonBlank(environment["XDG_CONFIG_HOME"]) {
            return normalizedPath(URL(fileURLWithPath: xdgConfigHome)
                .appendingPathComponent("mail-gateway")
                .appendingPathComponent("config.toml")
                .path)
        }
        return normalizedPath(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("mail-gateway")
            .appendingPathComponent("config.toml")
            .path)
    }

    public static func loadConfig(
        configPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        validateOAuthClientSecrets: Bool = false
    ) throws -> MailGatewayConfig {
        let explicitConfigPath = nonBlank(configPath) ?? nonBlank(environment["MAIL_GATEWAY_CONFIG"])
        let usesImplicitDefaultConfig = explicitConfigPath == nil
        let selectedConfigPath = normalizedPath(
            explicitConfigPath ?? resolveDefaultConfigPath(environment: environment)
        )
        let source: String
        do {
            source = try String(contentsOfFile: selectedConfigPath, encoding: .utf8)
        } catch {
            if usesImplicitDefaultConfig,
               !FileManager.default.fileExists(atPath: selectedConfigPath) {
                return try defaultConfig(configPath: selectedConfigPath, environment: environment)
            }
            throw MailGatewayError(
                "Failed to read config: \(selectedConfigPath)",
                code: .configInvalid,
                exitCode: .configurationError,
                details: ["cause": error.localizedDescription]
            )
        }

        let parsed = try parseTomlSubset(source)
        guard let storageRecord = parsed.storage else {
            throw configError("storage must be a table/object")
        }
        if parsed.credentials.isEmpty {
            throw configError("credentials must be a non-empty array")
        }
        if parsed.accounts.isEmpty {
            throw configError("accounts must be a non-empty array")
        }

        let storage = try parseStorageConfig(storageRecord, configPath: selectedConfigPath)
        let credentials = try parsed.credentials.enumerated().map { index, record in
            try parseCredentialConfig(record, index: index, configPath: selectedConfigPath, environment: environment)
        }
        let accounts = try parsed.accounts.enumerated().map { index, record in
            try parseAccountConfig(record, index: index)
        }

        try ensureUnique(credentials.map(\.id), context: "credentials.id")
        try ensureUniqueCredentialEnvSuffixes(credentials)
        try ensureUnique(accounts.map(\.id), context: "accounts.id")
        try ensureUnique(credentials.map(\.tokenStorePath), context: "credentials.token_store_path")
        try validateAccountCredentialLinks(credentials: credentials, accounts: accounts)

        if validateOAuthClientSecrets {
            try validateOAuthClientSecretPaths(credentials)
        }

        return MailGatewayConfig(
            configPath: selectedConfigPath,
            storage: storage,
            credentials: credentials,
            accounts: accounts
        )
    }

    public static func validateConfig(
        configPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [String: Any] {
        let config = try loadConfig(
            configPath: configPath,
            environment: environment,
            validateOAuthClientSecrets: true
        )
        return [
            "ok": true,
            "configPath": config.configPath,
            "fallbackConfig": config.accounts.contains { $0.isFallback },
            "accountIds": config.accounts.map(\.id),
            "credentialIds": config.credentials.map(\.id)
        ]
    }

    private static func defaultConfig(
        configPath: String,
        environment: [String: String]
    ) throws -> MailGatewayConfig {
        let storage = StorageConfig(
            cacheDir: defaultDataDirectory(environment: environment),
            attachmentDir: normalizedPath(URL(fileURLWithPath: defaultCacheDirectory(environment: environment))
                .appendingPathComponent("attachments", isDirectory: true)
                .path),
            allowedSendAttachmentRoots: [
                normalizedPath(URL(fileURLWithPath: defaultDataDirectory(environment: environment))
                    .appendingPathComponent("send-attachments", isDirectory: true)
                    .path)
            ]
        )
        let credential = CredentialConfig(
            id: defaultCredentialId,
            provider: .gmail,
            accessMode: .read,
            oauthClientSecretPath: try resolveCredentialPath(CredentialPathRequest(
                configPath: configPath,
                credentialId: defaultCredentialId,
                pathKey: "oauth_client_secret_path",
                configValue: "google-client.json",
                environment: environment,
                context: "credentials.\(defaultCredentialId).oauth_client_secret_path"
            )),
            oauthClientSecretJSON: credentialJSONEnvValue(
                credentialId: defaultCredentialId,
                valueKey: "oauth_client_secret_json",
                environment: environment
            ),
            tokenStorePath: try resolveCredentialPath(CredentialPathRequest(
                configPath: configPath,
                credentialId: defaultCredentialId,
                pathKey: "token_store_path",
                configValue: "tokens/\(defaultCredentialId).json",
                environment: environment,
                context: "credentials.\(defaultCredentialId).token_store_path"
            )),
            tokenStoreJSON: credentialJSONEnvValue(
                credentialId: defaultCredentialId,
                valueKey: "token_store_json",
                environment: environment
            )
        )
        return MailGatewayConfig(
            configPath: configPath,
            storage: storage,
            credentials: [credential],
            accounts: [
                AccountConfig(
                    id: defaultAccountId,
                    provider: .gmail,
                    emailAddress: "\(defaultAccountId)@example.invalid",
                    credentialId: credential.id,
                    defaultLabelIds: ["INBOX"],
                    isFallback: true
                )
            ]
        )
    }

    private static func defaultDataDirectory(environment: [String: String]) -> String {
        if let xdgDataHome = nonBlank(environment["XDG_DATA_HOME"]) {
            return normalizedPath(URL(fileURLWithPath: xdgDataHome)
                .appendingPathComponent("mail-gateway", isDirectory: true)
                .path)
        }
        return normalizedPath(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("mail-gateway", isDirectory: true)
            .path)
    }

    private static func defaultCacheDirectory(environment: [String: String]) -> String {
        if let xdgCacheHome = nonBlank(environment["XDG_CACHE_HOME"]) {
            return normalizedPath(URL(fileURLWithPath: xdgCacheHome)
                .appendingPathComponent("mail-gateway", isDirectory: true)
                .path)
        }
        return normalizedPath(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("mail-gateway", isDirectory: true)
            .path)
    }

    private static func credentialJSONEnvValue(
        credentialId: String,
        valueKey: String,
        environment: [String: String]
    ) -> String? {
        nonBlank(environment[getCredentialJSONEnvVarName(credentialId: credentialId, valueKey: valueKey)])
    }
}

private struct ParsedToml {
    var storage: [String: Any]?
    var credentials: [[String: Any]]
    var accounts: [[String: Any]]
}

private func parseTomlSubset(_ source: String) throws -> ParsedToml {
    var parsed = ParsedToml(storage: nil, credentials: [], accounts: [])
    var section = TomlSection.none

    for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = try stripTomlComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") {
            continue
        }
        if line == "[storage]" {
            parsed.storage = parsed.storage ?? [:]
            section = .storage
            continue
        }
        if line == "[[credentials]]" {
            parsed.credentials.append([:])
            section = .credential(parsed.credentials.count - 1)
            continue
        }
        if line == "[[accounts]]" {
            parsed.accounts.append([:])
            section = .account(parsed.accounts.count - 1)
            continue
        }
        guard let equals = line.firstIndex(of: "=") else {
            throw configError("config contains an unsupported TOML line: \(line)")
        }
        let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = try parseTomlValue(rawValue)
        switch section {
        case .storage:
            parsed.storage?[key] = value
        case .credential(let index):
            parsed.credentials[index][key] = value
        case .account(let index):
            parsed.accounts[index][key] = value
        case .none:
            throw configError("config key appears outside a supported section: \(key)")
        }
    }

    return parsed
}

private func parseTomlValue(_ rawValue: String) throws -> Any {
    if rawValue.hasPrefix("\""),
       rawValue.hasSuffix("\"") {
        return try parseTomlBasicString(rawValue)
    }
    if rawValue.hasPrefix("["),
       rawValue.hasSuffix("]") {
        let inner = String(rawValue.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        if inner.isEmpty {
            return [String]()
        }
        return try splitTomlArray(inner).map { item in
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("\""),
                  trimmed.hasSuffix("\"") else {
                throw configError("array values must be strings")
            }
            return try parseTomlBasicString(trimmed)
        }
    }
    throw configError("config contains an unsupported TOML value: \(rawValue)")
}

private func stripTomlComment(_ source: String) throws -> String {
    var output = ""
    var inString = false
    var escaping = false
    for character in source {
        if escaping {
            output.append(character)
            escaping = false
            continue
        }
        if character == "\\" && inString {
            output.append(character)
            escaping = true
            continue
        }
        if character == "\"" {
            output.append(character)
            inString.toggle()
            continue
        }
        if character == "#",
           !inString {
            return output
        }
        output.append(character)
    }
    guard !inString else {
        throw configError("config contains an unterminated string")
    }
    return output
}

private func parseTomlBasicString(_ rawValue: String) throws -> String {
    var output = ""
    var escaping = false
    let inner = rawValue.dropFirst().dropLast()
    for character in inner {
        if escaping {
            switch character {
            case "\"":
                output.append("\"")
            case "\\":
                output.append("\\")
            case "n":
                output.append("\n")
            case "r":
                output.append("\r")
            case "t":
                output.append("\t")
            default:
                throw configError("config contains an unsupported string escape: \\\(character)")
            }
            escaping = false
            continue
        }
        if character == "\\" {
            escaping = true
            continue
        }
        output.append(character)
    }
    guard !escaping else {
        throw configError("config contains an unterminated string escape")
    }
    return output
}

private func splitTomlArray(_ source: String) throws -> [String] {
    var values: [String] = []
    var current = ""
    var inString = false
    var escaping = false
    for character in source {
        if escaping {
            current.append(character)
            escaping = false
            continue
        }
        if character == "\\" {
            current.append(character)
            escaping = true
            continue
        }
        if character == "\"" {
            inString.toggle()
            current.append(character)
            continue
        }
        if character == ",",
           !inString {
            values.append(current)
            current = ""
            continue
        }
        current.append(character)
    }
    if !current.isEmpty {
        values.append(current)
    }
    guard !inString else {
        throw configError("array contains an unterminated string")
    }
    return values
}

private func parseStorageConfig(_ record: [String: Any], configPath: String) throws -> StorageConfig {
    StorageConfig(
        cacheDir: try resolveConfigRelativePath(
            configPath: configPath,
            rawPath: readString(record["cache_dir"], "storage.cache_dir")
        ),
        attachmentDir: try resolveConfigRelativePath(
            configPath: configPath,
            rawPath: readString(record["attachment_dir"], "storage.attachment_dir")
        ),
        allowedSendAttachmentRoots: try readOptionalStringArray(
            record["allowed_send_attachment_roots"],
            "storage.allowed_send_attachment_roots"
        )
            .map { try resolveConfigRelativePath(configPath: configPath, rawPath: $0) }
    )
}

private func parseCredentialConfig(
    _ record: [String: Any],
    index: Int,
    configPath: String,
    environment: [String: String]
) throws -> CredentialConfig {
    let contextBase = "credentials[\(index)]"
    let credentialId = try readString(record["id"], "\(contextBase).id")
    let oauthClientSecretJSON = nonBlank(environment[
        MailGatewayConfigLoader.getCredentialJSONEnvVarName(
            credentialId: credentialId,
            valueKey: "oauth_client_secret_json"
        )
    ])
    let tokenStoreJSON = nonBlank(environment[
        MailGatewayConfigLoader.getCredentialJSONEnvVarName(
            credentialId: credentialId,
            valueKey: "token_store_json"
        )
    ])
    return CredentialConfig(
        id: credentialId,
        provider: try readProvider(record["provider"], "\(contextBase).provider"),
        accessMode: try readAccessMode(record["access_mode"], "\(contextBase).access_mode"),
        oauthClientSecretPath: try resolveCredentialPath(CredentialPathRequest(
            configPath: configPath,
            credentialId: credentialId,
            pathKey: "oauth_client_secret_path",
            configValue: readOptionalString(
                record["oauth_client_secret_path"],
                "\(contextBase).oauth_client_secret_path"
            ),
            environment: environment,
            context: "\(contextBase).oauth_client_secret_path"
        )),
        oauthClientSecretJSON: oauthClientSecretJSON,
        tokenStorePath: try resolveCredentialPath(CredentialPathRequest(
            configPath: configPath,
            credentialId: credentialId,
            pathKey: "token_store_path",
            configValue: readOptionalString(record["token_store_path"], "\(contextBase).token_store_path"),
            environment: environment,
            context: "\(contextBase).token_store_path"
        )),
        tokenStoreJSON: tokenStoreJSON
    )
}

private func parseAccountConfig(_ record: [String: Any], index: Int) throws -> AccountConfig {
    let contextBase = "accounts[\(index)]"
    let emailAddress = try readString(record["email_address"], "\(contextBase).email_address")
    if !isValidConfiguredMailboxAddress(emailAddress) {
        throw configError("\(contextBase).email_address must be a valid mailbox address")
    }
    return AccountConfig(
        id: try readString(record["id"], "\(contextBase).id"),
        provider: try readProvider(record["provider"], "\(contextBase).provider"),
        emailAddress: emailAddress,
        credentialId: try readString(record["credential_id"], "\(contextBase).credential_id"),
        defaultLabelIds: try readOptionalStringArray(record["default_label_ids"], "\(contextBase).default_label_ids")
    )
}

private func isValidConfiguredMailboxAddress(_ emailAddress: String) -> Bool {
    if emailAddress.unicodeScalars.contains(where: isWhitespaceOrControlCharacter) {
        return false
    }

    let parts = emailAddress.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2 else {
        return false
    }

    let localPart = String(parts[0])
    let domainPart = String(parts[1])
    guard !localPart.isEmpty,
          !domainPart.isEmpty,
          !localPart.hasPrefix("."),
          !localPart.hasSuffix("."),
          domainPart.contains("."),
          !domainPart.hasPrefix("."),
          !domainPart.hasSuffix("."),
          !domainPart.contains("..") else {
        return false
    }

    return true
}

private func isWhitespaceOrControlCharacter(_ scalar: Unicode.Scalar) -> Bool {
    CharacterSet.whitespacesAndNewlines.contains(scalar) ||
        CharacterSet.controlCharacters.contains(scalar)
}

private func resolveCredentialPath(_ request: CredentialPathRequest) throws -> String {
    let envName = MailGatewayConfigLoader.getCredentialPathEnvVarName(
        credentialId: request.credentialId,
        pathKey: request.pathKey
    )
    let selected = nonBlank(request.environment[envName]) ?? request.configValue
    guard let selected else {
        throw configError("\(request.context) must be set in config or \(envName)")
    }
    return try resolveConfigRelativePath(configPath: request.configPath, rawPath: selected)
}

private func resolveConfigRelativePath(configPath: String, rawPath: String) throws -> String {
    if rawPath.hasPrefix("/") {
        return normalizedPath(rawPath)
    }
    let configDirectory = URL(fileURLWithPath: configPath).deletingLastPathComponent()
    return normalizedPath(configDirectory.appendingPathComponent(rawPath).path)
}

private func validateOAuthClientSecretPaths(_ credentials: [CredentialConfig]) throws {
    for credential in credentials
        where credential.oauthClientSecretJSON == nil &&
        !FileManager.default.isReadableFile(atPath: credential.oauthClientSecretPath) {
        throw configError(
            "credentials.\(credential.id).oauth_client_secret_path is not readable: " +
                credential.oauthClientSecretPath
        )
    }
}

private func readProvider(_ value: Any?, _ context: String) throws -> MailProvider {
    let provider = try readString(value, context)
    guard let parsed = MailProvider(rawValue: provider) else {
        throw configError("\(context) must currently be \"gmail\"")
    }
    return parsed
}

private func readAccessMode(_ value: Any?, _ context: String) throws -> AccessMode {
    let raw = value == nil ? "read" : try readString(value, context)
    guard let parsed = AccessMode(rawValue: raw) else {
        throw configError("\(context) must be \"read\" or \"read_send\"")
    }
    return parsed
}

private func readString(_ value: Any?, _ context: String) throws -> String {
    guard let string = value as? String,
          !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw configError("\(context) must be a non-empty string")
    }
    return string
}

private func readOptionalString(_ value: Any?, _ context: String) throws -> String? {
    guard value != nil else {
        return nil
    }
    return try readString(value, context)
}

private func readOptionalStringArray(_ value: Any?, _ context: String) throws -> [String] {
    guard value != nil else {
        return []
    }
    guard let values = value as? [String] else {
        throw configError("\(context) must be an array of strings")
    }
    for (index, item) in values.enumerated() where item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw configError("\(context)[\(index)] must be a non-empty string")
    }
    return values
}

private func ensureUnique(_ values: [String], context: String) throws {
    var seen: Set<String> = []
    for value in values {
        if seen.contains(value) {
            throw configError("\(context) contains a duplicate value: \(value)")
        }
        seen.insert(value)
    }
}

private func ensureUniqueCredentialEnvSuffixes(_ credentials: [CredentialConfig]) throws {
    var seen: [String: String] = [:]
    for credential in credentials {
        let suffix = MailGatewayConfigLoader.getCredentialPathEnvVarName(
            credentialId: credential.id,
            pathKey: "token_store_path"
        )
        if let existing = seen[suffix] {
            throw configError(
                "credentials.id values \(existing) and \(credential.id) resolve to the same environment variable suffix"
            )
        }
        seen[suffix] = credential.id
    }
}

private func validateAccountCredentialLinks(credentials: [CredentialConfig], accounts: [AccountConfig]) throws {
    let credentialsById = Dictionary(uniqueKeysWithValues: credentials.map { ($0.id, $0) })
    for account in accounts {
        guard let credential = credentialsById[account.credentialId] else {
            throw configError("accounts.\(account.id) references unknown credential: \(account.credentialId)")
        }
        if credential.provider != account.provider {
            throw configError("accounts.\(account.id) provider does not match credential provider")
        }
    }
}

private func configError(_ message: String) -> MailGatewayError {
    MailGatewayError(message, code: .configInvalid, exitCode: .configurationError)
}
