import Foundation

struct GmailOAuthClientRecord: Codable, Sendable, Equatable {
    let kind: String
    let clientId: String
    let clientSecret: String?
    let projectId: String?
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let redirectURIs: [String]

    func legacyJSON() throws -> String {
        var installed: [String: Any] = [
            "client_id": clientId,
            "auth_uri": authorizationEndpoint,
            "token_uri": tokenEndpoint,
            "redirect_uris": redirectURIs
        ]
        if let clientSecret { installed["client_secret"] = clientSecret }
        if let projectId { installed["project_id"] = projectId }
        let data = try JSONSerialization.data(withJSONObject: ["installed": installed], options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw profileError("OAuth client could not be encoded")
        }
        return json
    }
}

struct GmailOAuthSetupOptions: Sendable {
    let clientSecretPath: String
    let replace: Bool
    let confirmedCredentialId: String?
}

func loadGmailOAuthClientRecord(from path: String) throws -> GmailOAuthClientRecord {
    guard let data = FileManager.default.contents(atPath: path) else {
        throw GmailGatewayError("OAuth client file could not be read", code: .configInvalid, exitCode: .configurationError)
    }
    return try loadGmailOAuthClientRecord(from: data)
}

func loadGmailOAuthClientRecord(from data: Data) throws -> GmailOAuthClientRecord {
    do {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let installed = root?["installed"] as? [String: Any], root?["web"] == nil else {
            throw profileError("OAuth client JSON must contain only an installed desktop client")
        }
        guard let clientID = nonBlank(installed["client_id"] as? String),
              let authorizationEndpoint = nonBlank(installed["auth_uri"] as? String),
              let tokenEndpoint = nonBlank(installed["token_uri"] as? String),
              let redirects = installed["redirect_uris"] as? [String], !redirects.isEmpty else {
            throw profileError("OAuth client JSON is missing required desktop client fields")
        }
        let normalizedAuthorization = try normalizedAuthorizationEndpoint(authorizationEndpoint)
        try validateEndpoint(tokenEndpoint, expectedPath: "/token")
        // OAuth client registration order is meaningful for the default callback.
        // Validate every value without changing the order supplied by Google.
        let normalizedRedirects = try redirects.map { try GmailLoopbackRedirectURI($0).registeredURI }
        return GmailOAuthClientRecord(
            kind: "installed",
            clientId: clientID,
            clientSecret: nonBlank(installed["client_secret"] as? String),
            projectId: nonBlank(installed["project_id"] as? String),
            authorizationEndpoint: normalizedAuthorization,
            tokenEndpoint: tokenEndpoint,
            redirectURIs: normalizedRedirects
        )
    } catch let error as GmailGatewayError {
        throw error
    } catch {
        throw profileError("OAuth client JSON is invalid")
    }
}

private func normalizedAuthorizationEndpoint(_ value: String) throws -> String {
    try validateEndpoint(value, expectedPath: "/o/oauth2/auth", alternatePath: "/o/oauth2/v2/auth")
    return "https://accounts.google.com/o/oauth2/v2/auth"
}

private func validateEndpoint(_ value: String, expectedPath: String, alternatePath: String? = nil) throws {
    guard let components = URLComponents(string: value),
          components.scheme == "https",
          components.host == (expectedPath == "/token" ? "oauth2.googleapis.com" : "accounts.google.com"),
          components.port == nil,
          components.user == nil,
          components.password == nil,
          components.query == nil,
          components.fragment == nil,
          components.path == expectedPath || components.path == alternatePath else {
        throw profileError("OAuth endpoint is not an approved Google endpoint")
    }
}

struct GmailLoopbackRedirectURI: Sendable, Equatable {
    let registeredURI: String
    let host: String
    let port: UInt16?
    let path: String

    init(_ value: String) throws {
        guard let components = URLComponents(string: value),
              components.scheme == "http",
              let host = components.host,
              ["127.0.0.1", "localhost", "::1"].contains(normalizedLoopbackHost(host)),
              components.port.map({ $0 > 0 && $0 <= 65_535 }) ?? true,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw profileError("OAuth redirect URI must be a loopback URI")
        }
        registeredURI = value
        self.host = normalizedLoopbackHost(host)
        port = components.port.map(UInt16.init)
        path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
    }

    private init(registeredURI: String, host: String, port: UInt16?, path: String) {
        self.registeredURI = registeredURI
        self.host = host
        self.port = port
        self.path = path
    }

    static let defaultCallback = GmailLoopbackRedirectURI(
        registeredURI: "http://127.0.0.1/oauth2callback",
        host: "127.0.0.1",
        port: nil,
        path: "/oauth2callback"
    )

    func absoluteString(port: UInt16) -> String {
        let renderedHost = host == "::1" ? "[::1]" : host
        return "http://\(renderedHost):\(port)\(path)"
    }

    func accepts(_ requested: GmailLoopbackRedirectURI) -> Bool {
        host == requested.host && path == requested.path && (port == nil || port == requested.port)
    }
}

private func normalizedLoopbackHost(_ value: String) -> String {
    value == "[::1]" ? "::1" : value.lowercased()
}

func selectedGmailOAuthLoopbackRedirect(
    client: GmailOAuthClientRecord,
    requestedURI: String?
) throws -> GmailLoopbackRedirectURI {
    let registered = try client.redirectURIs.map(GmailLoopbackRedirectURI.init)
    guard !registered.isEmpty else {
        throw profileError("OAuth client JSON is missing loopback redirect URIs")
    }
    guard let requestedURI else {
        return registered[0]
    }
    let requested = try GmailLoopbackRedirectURI(requestedURI)
    guard registered.contains(where: { $0.accepts(requested) }) else {
        throw profileError("OAuth redirect URI is not registered for the selected client")
    }
    return requested
}

private func profileError(_ message: String) -> GmailGatewayError {
    GmailGatewayError(message, code: .configInvalid, exitCode: .configurationError)
}
