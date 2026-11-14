import Foundation

/// Canonical inputs and historical aliases. Never include credential values in errors.
func gmailCredentialEnvironment(
  _ source: [String: String], credentialIDs: [String] = ["gmail-personal"]
) throws -> [String: String] {
  var result = source
  let prefix = "GMAIL_GATEWAY_"
  let suffixes = [
    ("OAUTH_CLIENT_JSON", "OAUTH_CLIENT_SECRET_JSON"),
    ("OAUTH_CLIENT_PATH", "OAUTH_CLIENT_SECRET_PATH"),
    ("TOKEN_STORE_JSON", "TOKEN_STORE_JSON"),
    ("TOKEN_STORE_PATH", "TOKEN_STORE_PATH"),
    ("ACCESS_TOKEN", "ACCESS_TOKEN")
  ]
  for id in credentialIDs {
    let profile = "CREDENTIAL_\(id.uppercased().replacingOccurrences(of: "-", with: "_"))_"
    let hasSpecific: [Bool: Bool] = Dictionary(uniqueKeysWithValues: [false, true].map { isApplication in
      let present = suffixes.filter { $0.0.hasPrefix("OAUTH_CLIENT_") == isApplication }.contains { canonical, legacy in
        let keys = [prefix + profile + canonical, prefix + profile + legacy]
        return keys.contains { nonBlank(source[$0]) != nil }
      }
      return (isApplication, present)
    })
    for (canonical, legacy) in suffixes {
      let names = [prefix + profile + canonical, prefix + profile + legacy,
                   prefix + profile + legacy]
      let specific = try gmailEnvironmentAlias(source, names: Array(Set(names)).sorted())
      let value = try specific ?? (hasSpecific[canonical.hasPrefix("OAUTH_CLIENT_")] == true
        ? nil : gmailEnvironmentAlias(source, names: [prefix + canonical]))
      if let value { result[prefix + profile + legacy] = value }
    }
    let tokenKey = prefix + profile + "ACCESS_TOKEN"
    if let token = nonBlank(result[tokenKey]) {
      let jsonKey = prefix + profile + "TOKEN_STORE_JSON"
      let pathKey = prefix + profile + "TOKEN_STORE_PATH"
      guard nonBlank(result[jsonKey]) == nil, nonBlank(result[pathKey]) == nil else {
        throw gmailEnvironmentError("ACCESS_TOKEN cannot be combined with TOKEN_STORE_JSON or TOKEN_STORE_PATH for credential \(id)")
      }
      guard token.utf8.count <= 8192, !token.utf8.contains(where: { $0 < 33 || $0 == 127 }) else {
        throw gmailEnvironmentError("ACCESS_TOKEN contains unsupported characters")
      }
    }
  }
  return result
}

private func gmailEnvironmentAlias(_ source: [String: String], names: [String]) throws -> String? {
  let entries = names.compactMap { name in nonBlank(source[name]).map { (name, $0) } }
  guard let first = entries.first else { return nil }
  guard entries.allSatisfy({ $0.1 == first.1 }) else {
    throw gmailEnvironmentError("Conflicting credential environment variables: \(entries.map { $0.0 }.joined(separator: ", "))")
  }
  return first.1
}

private func gmailEnvironmentError(_ message: String) -> GmailGatewayError {
    GmailGatewayError(message, code: .configInvalid, exitCode: .configurationError)
}
