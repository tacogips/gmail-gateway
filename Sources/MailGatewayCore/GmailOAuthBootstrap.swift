import CryptoKit
import Darwin
import Foundation
import Security

struct GmailOAuthLoginOptions: Sendable {
    static let defaultTimeoutSeconds: Int32 = 300

    let redirectURI: String?
    let openBrowser: Bool
    let timeoutSeconds: Int32

    init(
        redirectURI: String? = nil,
        openBrowser: Bool = true,
        timeoutSeconds: Int32 = GmailOAuthLoginOptions.defaultTimeoutSeconds
    ) {
        self.redirectURI = nonBlank(redirectURI)
        self.openBrowser = openBrowser
        self.timeoutSeconds = timeoutSeconds
    }
}

struct GmailOAuthBootstrapper {
    func login(credential: CredentialConfig, options: GmailOAuthLoginOptions = GmailOAuthLoginOptions()) throws -> [String: Any] {
        let client = try loadGoogleOAuthClient(credential: credential, use: .desktopLogin)
        let receiver = try LoopbackOAuthReceiver(redirectURI: options.redirectURI)
        let state = try randomURLSafeString(byteCount: 32)
        let codeVerifier = try randomURLSafeString(byteCount: 32)
        let authorizationURL = try buildAuthorizationURL(
            client: client,
            credential: credential,
            redirectURI: receiver.redirectURI,
            state: state,
            codeVerifier: codeVerifier
        )

        if options.openBrowser {
            try openBrowser(authorizationURL)
        } else {
            writeManualAuthorizationMessage(authorizationURL)
        }
        let code = try receiver.waitForCode(expectedState: state, timeoutSeconds: options.timeoutSeconds)
        let tokenResponse = try exchangeAuthorizationCode(
            client: client,
            code: code,
            codeVerifier: codeVerifier,
            redirectURI: receiver.redirectURI
        )
        let tokenStore = try buildTokenStore(
            credential: credential,
            tokenResponse: tokenResponse,
            profile: validateGmailProfile(accessToken: tokenResponse.accessToken)
        )
        try writeGmailOAuthTokenStore(
            tokenStore,
            to: credential.tokenStorePath,
            errorMessage: "Failed to write Gmail OAuth token store",
            exitCode: .authenticationBootstrapError
        )

        return [
            "credentialId": credential.id,
            "provider": credential.provider.rawValue,
            "state": AuthState.ready.rawValue,
            "tokenStorePath": credential.tokenStorePath,
            "redirectUri": receiver.redirectURI,
            "emailAddress": tokenStore.emailAddress as Any? ?? NSNull(),
            "expiresAt": tokenStore.expiresAt as Any? ?? NSNull(),
            "hasRefreshToken": tokenStore.refreshToken?.isEmpty == false
        ]
    }
}

private struct GmailOAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let tokenType: String?
    let scope: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case scope
        case expiresIn = "expires_in"
    }

    init(
        accessToken: String,
        refreshToken: String?,
        tokenType: String?,
        scope: String?,
        expiresIn: Int?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.scope = scope
        self.expiresIn = expiresIn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn)
    }

    func normalized(accessToken: String) -> GmailOAuthTokenResponse {
        GmailOAuthTokenResponse(
            accessToken: accessToken,
            refreshToken: nonBlank(refreshToken),
            tokenType: nonBlank(tokenType),
            scope: nonBlank(scope),
            expiresIn: expiresIn
        )
    }
}

private struct GmailProfile: Decodable {
    let emailAddress: String?
}

struct GmailOAuthTokenStore: Codable {
    let accessMode: AccessMode
    let accessToken: String
    let refreshToken: String?
    let tokenType: String?
    let scope: String?
    let expiresAt: String?
    let emailAddress: String?
}

private struct LoopbackRedirectURI {
    let authorizationHost: String
    let bindHost: String
    let port: UInt16
    let path: String

    init(_ redirectURI: String?) throws {
        guard let redirectURI else {
            authorizationHost = "127.0.0.1"
            bindHost = "127.0.0.1"
            port = 0
            path = "/oauth2callback"
            return
        }
        guard let components = URLComponents(string: redirectURI),
              components.scheme == "http",
              let host = components.host,
              let explicitPort = components.port,
              explicitPort > 0,
              explicitPort <= 65_535 else {
            throw authError("OAuth redirect URI must be an http:// loopback URL with an explicit port")
        }
        let normalizedHost = host.lowercased()
        guard normalizedHost == "127.0.0.1" || normalizedHost == "localhost" else {
            throw authError("OAuth redirect URI must use localhost or 127.0.0.1")
        }
        authorizationHost = "127.0.0.1"
        bindHost = "127.0.0.1"
        port = UInt16(explicitPort)
        path = components.path.isEmpty ? "/" : components.path
    }

    func absoluteString(boundPort: UInt16) -> String {
        "http://\(authorizationHost):\(boundPort)\(path)"
    }
}

final class LoopbackOAuthReceiver: @unchecked Sendable {
    let redirectURI: String
    private let socketFD: Int32
    private let redirect: LoopbackRedirectURI

    init(redirectURI: String? = nil) throws {
        let redirect = try LoopbackRedirectURI(redirectURI)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw authError("Failed to create OAuth callback socket")
        }

        var reuse: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(fd)
            throw authError("Failed to configure OAuth callback socket")
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(redirect.port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr(redirect.bindHost))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw authError("Failed to bind OAuth callback socket to \(redirect.bindHost):\(redirect.port)")
        }
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw authError("Failed to listen for OAuth callback")
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(fd, socketAddress, &length)
            }
        }
        guard nameResult == 0 else {
            close(fd)
            throw authError("Failed to resolve OAuth callback port")
        }
        socketFD = fd
        self.redirect = redirect
        self.redirectURI = redirect.absoluteString(boundPort: UInt16(bigEndian: boundAddress.sin_port))
    }

    deinit {
        close(socketFD)
    }

    func waitForCode(expectedState: String, timeoutSeconds: Int32) throws -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            let remainingMilliseconds = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
            var pollSet = [pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)]
            let pollResult = Darwin.poll(&pollSet, 1, remainingMilliseconds)
            guard pollResult > 0 else {
                break
            }

            let connection = accept(socketFD, nil, nil)
            guard connection >= 0 else {
                throw authError("Failed to accept Gmail OAuth callback")
            }
            defer {
                close(connection)
            }

            guard let request = try readHTTPRequest(connection: connection) else {
                try writeHTTPResponse(connection, status: "404 Not Found", body: "Gmail OAuth callback was not found.\n")
                continue
            }
            guard callbackRequestPathMatches(request: request, redirect: redirect) else {
                try writeHTTPResponse(connection, status: "404 Not Found", body: "Gmail OAuth callback was not found.\n")
                continue
            }

            do {
                let code = try parseCallbackCode(request: request, redirect: redirect, expectedState: expectedState)
                try writeHTTPResponse(
                    connection,
                    status: "200 OK",
                    body: "Gmail authentication completed. You can close this window.\n"
                )
                return code
            } catch {
                try writeHTTPResponse(
                    connection,
                    status: "400 Bad Request",
                    body: "Gmail authentication failed. Return to the terminal for details.\n"
                )
                throw error
            }
        }
        throw authError("Timed out waiting for Gmail OAuth callback")
    }
}

private func readHTTPRequest(connection: Int32) throws -> String? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 2_048)
    while data.count < 16_384 {
        var pollSet = [pollfd(fd: connection, events: Int16(POLLIN), revents: 0)]
        let pollResult = Darwin.poll(&pollSet, 1, 1_000)
        guard pollResult > 0 else {
            break
        }
        let count = Darwin.read(connection, &buffer, buffer.count)
        guard count > 0 else {
            break
        }
        data.append(contentsOf: buffer.prefix(Int(count)))
        if data.range(of: Data("\r\n\r\n".utf8)) != nil {
            break
        }
    }
    guard !data.isEmpty,
          let request = String(data: data, encoding: .utf8) else {
        return nil
    }
    return request
}

private func callbackRequestPathMatches(request: String, redirect: LoopbackRedirectURI) -> Bool {
    guard let firstLine = request.components(separatedBy: "\r\n").first else {
        return false
    }
    let parts = firstLine.split(separator: " ")
    guard parts.count >= 2,
          let components = URLComponents(string: "http://\(redirect.bindHost):\(redirect.port)\(parts[1])") else {
        return false
    }
    return components.path == redirect.path
}

private func buildAuthorizationURL(
    client: GoogleOAuthClient,
    credential: CredentialConfig,
    redirectURI: String,
    state: String,
    codeVerifier: String
) throws -> URL {
    guard let authURI = nonBlank(client.authURI),
          var components = URLComponents(string: authURI) else {
        throw authError("OAuth client auth_uri is invalid")
    }
    components.queryItems = [
        URLQueryItem(name: "client_id", value: client.clientId),
        URLQueryItem(name: "redirect_uri", value: redirectURI),
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "scope", value: gmailScopes(accessMode: credential.accessMode).joined(separator: " ")),
        URLQueryItem(name: "access_type", value: "offline"),
        URLQueryItem(name: "prompt", value: "consent"),
        URLQueryItem(name: "state", value: state),
        URLQueryItem(name: "code_challenge", value: codeChallenge(for: codeVerifier)),
        URLQueryItem(name: "code_challenge_method", value: "S256")
    ]
    guard let url = components.url else {
        throw authError("Failed to construct Gmail OAuth authorization URL")
    }
    return url
}

private func openBrowser(_ url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        throw MailGatewayError(
            "Failed to open browser for Gmail OAuth",
            code: .authRequired,
            exitCode: .authenticationBootstrapError,
            details: ["cause": error.localizedDescription]
        )
    }
    guard process.terminationStatus == 0 else {
        throw MailGatewayError(
            "Browser launch for Gmail OAuth failed",
            code: .authRequired,
            exitCode: .authenticationBootstrapError,
            details: ["status": String(process.terminationStatus)]
        )
    }
}

private func writeManualAuthorizationMessage(_ url: URL) {
    let message = "Open this Gmail OAuth authorization URL to continue: \(url.absoluteString)\n"
    FileHandle.standardError.write(Data(message.utf8))
}

private func parseCallbackCode(
    request: String,
    redirect: LoopbackRedirectURI,
    expectedState: String
) throws -> String {
    guard let firstLine = request.components(separatedBy: "\r\n").first else {
        throw authError("OAuth callback request was empty")
    }
    let parts = firstLine.split(separator: " ")
    guard parts.count >= 2,
          parts[0] == "GET" else {
        throw authError("OAuth callback requires GET")
    }
    guard let components = URLComponents(string: "http://\(redirect.bindHost):\(redirect.port)\(parts[1])") else {
        throw authError("OAuth callback request was malformed")
    }
    guard components.path == redirect.path else {
        throw authError("OAuth callback path did not match the configured redirect URI")
    }
    var query: [String: String] = [:]
    for item in components.queryItems ?? [] {
        query[item.name] = item.value ?? ""
    }
    if let error = query["error"] {
        throw MailGatewayError(
            "Gmail OAuth authorization failed",
            code: .authRequired,
            exitCode: .authenticationBootstrapError,
            details: ["oauthError": error]
        )
    }
    guard query["state"] == expectedState else {
        throw authError("Gmail OAuth callback state did not match")
    }
    guard let code = nonBlank(query["code"]) else {
        throw authError("Gmail OAuth callback did not include an authorization code")
    }
    return code
}

private func exchangeAuthorizationCode(
    client: GoogleOAuthClient,
    code: String,
    codeVerifier: String,
    redirectURI: String
) throws -> GmailOAuthTokenResponse {
    guard let tokenURI = nonBlank(client.tokenURI),
          let tokenURL = URL(string: tokenURI) else {
        throw authError("OAuth client token_uri is invalid")
    }
    var fields: [(String, String)] = [
        ("client_id", client.clientId),
        ("code", code),
        ("code_verifier", codeVerifier),
        ("grant_type", "authorization_code"),
        ("redirect_uri", redirectURI)
    ]
    if let clientSecret = nonBlank(client.clientSecret) {
        fields.append(("client_secret", clientSecret))
    }

    var request = URLRequest(url: tokenURL)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formURLEncoded(fields).data(using: .utf8)

    let response = try performGmailHTTPRequest(request, context: "Gmail OAuth token exchange failed")
    let tokenResponse: GmailOAuthTokenResponse
    do {
        tokenResponse = try JSONDecoder().decode(GmailOAuthTokenResponse.self, from: response.data)
    } catch {
        throw authError("Gmail OAuth token response was not a JSON object")
    }
    guard let accessToken = nonBlank(tokenResponse.accessToken) else {
        throw MailGatewayError(
            "Gmail OAuth token response did not include an access token",
            code: .authRequired,
            exitCode: .authenticationBootstrapError
        )
    }
    return tokenResponse.normalized(accessToken: accessToken)
}

private func validateGmailProfile(accessToken: String) throws -> GmailProfile {
    guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile") else {
        throw authError("Failed to construct Gmail profile URL")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 30
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    let response = try performGmailHTTPRequest(request, context: "Gmail profile validation failed")
    let profile: GmailProfile
    do {
        profile = try JSONDecoder().decode(GmailProfile.self, from: response.data)
    } catch {
        throw authError("Gmail profile response was not a JSON object")
    }
    return GmailProfile(emailAddress: nonBlank(profile.emailAddress))
}

private func buildTokenStore(
    credential: CredentialConfig,
    tokenResponse: GmailOAuthTokenResponse,
    profile: GmailProfile
) throws -> GmailOAuthTokenStore {
    let expiresAt = tokenResponse.expiresIn.map {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval($0)))
    }
    return GmailOAuthTokenStore(
        accessMode: credential.accessMode,
        accessToken: tokenResponse.accessToken,
        refreshToken: tokenResponse.refreshToken,
        tokenType: tokenResponse.tokenType,
        scope: tokenResponse.scope,
        expiresAt: expiresAt,
        emailAddress: profile.emailAddress
    )
}

private func gmailScopes(accessMode: AccessMode) -> [String] {
    switch accessMode {
    case .read:
        return ["https://www.googleapis.com/auth/gmail.readonly"]
    case .readSend:
        return [
            "https://www.googleapis.com/auth/gmail.readonly",
            "https://www.googleapis.com/auth/gmail.compose",
            "https://www.googleapis.com/auth/gmail.send"
        ]
    }
}

private func randomURLSafeString(byteCount: Int) throws -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
        throw authError("Failed to generate secure OAuth random value")
    }
    return base64URLString(Data(bytes))
}

private func codeChallenge(for verifier: String) -> String {
    base64URLString(Data(SHA256.hash(data: Data(verifier.utf8))))
}

private func writeHTTPResponse(_ connection: Int32, status: String, body: String) throws {
    let response = """
    HTTP/1.1 \(status)\r
    Content-Type: text/plain; charset=utf-8\r
    Connection: close\r
    Content-Length: \(body.utf8.count)\r
    \r
    \(body)
    """
    _ = response.withCString { pointer in
        Darwin.write(connection, pointer, strlen(pointer))
    }
}

private func authError(_ message: String) -> MailGatewayError {
    MailGatewayError(
        message,
        code: .authRequired,
        exitCode: .authenticationBootstrapError
    )
}
