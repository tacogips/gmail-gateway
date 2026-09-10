import Foundation

/// Source metadata only: never include credential JSON or token values.
func tokenSourceDiagnostics(
    _ credential: CredentialConfig,
    source: GmailCredentialSourceKind? = nil
) -> [String: String] {
    let kind = source ?? (credential.tokenStoreJSON == nil ? credential.tokenStoreSource : .environmentJSON)
    let jsonVariable = GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
        credentialId: credential.id, valueKey: "token_store_json"
    )
    let pathVariable = GmailGatewayConfigLoader.getCredentialPathEnvVarName(
        credentialId: credential.id, pathKey: "token_store_path"
    )
    var details = ["credentialId": credential.id, "tokenSource": kind.rawValue]
    switch kind {
    case .environmentJSON:
        details["tokenEnvironmentVariable"] = jsonVariable
        details["tokenSourceHint"] = "Unset \(jsonVariable) before login; inline JSON overrides token paths."
        if credential.tokenStoreSource == .environmentPath {
            details["tokenPathEnvironmentVariable"] = pathVariable
        }
    case .secureVault:
        details["tokenSourceHint"] = "Keep \(jsonVariable) and \(pathVariable) unset to use the vault token."
    case .environmentPath, .configuredPath, .relocatedPath, .synthesizedDefault:
        details["tokenStorePath"] = credential.tokenStorePath
        details["tokenSourceHint"] = "Unset \(jsonVariable) and select this path with \(pathVariable); environment paths override config paths."
        if kind == .environmentPath {
            details["tokenEnvironmentVariable"] = pathVariable
        }
    }
    return details
}

func tokenSourceError(_ error: GmailGatewayError, credential: CredentialConfig) -> GmailGatewayError {
    if error.details["tokenSourceHint"] != nil { return error }
    let source = error.details["tokenSource"].flatMap(GmailCredentialSourceKind.init(rawValue:))
    let details = tokenSourceDiagnostics(credential, source: source).merging(error.details) { _, existing in existing }
    let summary = details.keys.sorted().compactMap { key -> String? in
        guard key.hasPrefix("token"), let value = details[key] else { return nil }
        return "\(key)=\(value)"
    }.joined(separator: "; ")
    return GmailGatewayError(
        "\(error.message) (\(summary))",
        code: error.code,
        exitCode: error.exitCode,
        details: details
    )
}
