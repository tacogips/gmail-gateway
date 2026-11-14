import CryptoKit
import Darwin
import Foundation
import Security

struct GmailOAuthBootstrapper {
    func login(credential: CredentialConfig) throws -> [String: Any] {
        let client = try loadOAuthClient(credential: credential)
        let receiver = try LoopbackOAuthReceiver()
        let state = try randomURLSafeString(byteCount: 32)
        let codeVerifier = try randomURLSafeString(byteCount: 32)
        let authorizationURL = try buildAuthorizationURL(
            client: client,
            credential: credential,
            redirectURI: receiver.redirectURI,
            state: state,
            codeVerifier: codeVerifier
        )

        try openBrowser(authorizationURL)
        let code = try receiver.waitForCode(expectedState: state, timeoutSeconds: 300)
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
        try writeTokenStore(tokenStore, to: credential.tokenStorePath)

        return [
            "credentialId": credential.id,
            "provider": credential.provider.rawValue,
            "state": AuthState.ready.rawValue,
            "tokenStorePath": credential.tokenStorePath,
            "emailAddress": tokenStore.emailAddress as Any? ?? NSNull(),
            "expiresAt": tokenStore.expiresAt as Any? ?? NSNull(),
            "hasRefreshToken": tokenStore.refreshToken?.isEmpty == false
        ]
    }
}

private struct GoogleOAuthClient: Decodable {
    let clientId: String
    let clientSecret: String?
    let authURI: String
    let tokenURI: String

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case clientSecret = "client_secret"
        case authURI = "auth_uri"
        case tokenURI = "token_uri"
    }
}

private struct GoogleOAuthClientFile: Decodable {
    let installed: GoogleOAuthClient?
}

private struct GmailOAuthTokenResponse {
    let accessToken: String
    let refreshToken: String?
    let tokenType: String?
    let scope: String?
    let expiresIn: Int?
}

private struct GmailProfile {
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

private final class LoopbackOAuthReceiver {
    let redirectURI: String
    private let socketFD: Int32

    init() throws {
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
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw authError("Failed to bind OAuth callback socket")
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
        redirectURI = "http://127.0.0.1:\(UInt16(bigEndian: boundAddress.sin_port))/oauth2callback"
    }

    deinit {
        close(socketFD)
    }

    func waitForCode(expectedState: String, timeoutSeconds: Int32) throws -> String {
        var pollSet = [pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)]
        let pollResult = Darwin.poll(&pollSet, 1, timeoutSeconds * 1_000)
        guard pollResult > 0 else {
            throw authError("Timed out waiting for Gmail OAuth callback")
        }

        let connection = accept(socketFD, nil, nil)
        guard connection >= 0 else {
            throw authError("Failed to accept Gmail OAuth callback")
        }
        defer {
            close(connection)
        }

        var buffer = [UInt8](repeating: 0, count: 8_192)
        let count = Darwin.read(connection, &buffer, buffer.count)
        guard count > 0,
              let request = String(bytes: buffer.prefix(Int(count)), encoding: .utf8) else {
            try writeHTTPResponse(connection, success: false)
            throw authError("Failed to read Gmail OAuth callback")
        }

        do {
            let code = try parseCallbackCode(request: request, expectedState: expectedState)
            try writeHTTPResponse(connection, success: true)
            return code
        } catch {
            try writeHTTPResponse(connection, success: false)
            throw error
        }
    }
}

private func loadOAuthClient(credential: CredentialConfig) throws -> GoogleOAuthClient {
    do {
        let data: Data
        if let oauthClientSecretJSON = credential.oauthClientSecretJSON {
            data = Data(oauthClientSecretJSON.utf8)
        } else {
            data = try Data(contentsOf: URL(fileURLWithPath: credential.oauthClientSecretPath))
        }
        let decoded = try JSONDecoder().decode(GoogleOAuthClientFile.self, from: data)
        guard let installed = decoded.installed,
              nonBlank(installed.clientId) != nil,
              nonBlank(installed.authURI) != nil,
              nonBlank(installed.tokenURI) != nil else {
            throw MailGatewayError(
                "OAuth client JSON must contain an installed desktop client",
                code: .configInvalid,
                exitCode: .authenticationBootstrapError,
                details: ["path": credential.oauthClientSecretPath]
            )
        }
        return installed
    } catch let error as MailGatewayError {
        throw error
    } catch {
        throw MailGatewayError(
            "Failed to read Gmail OAuth client JSON",
            code: .configInvalid,
            exitCode: .authenticationBootstrapError,
            details: ["path": credential.oauthClientSecretPath, "cause": error.localizedDescription]
        )
    }
}

private func buildAuthorizationURL(
    client: GoogleOAuthClient,
    credential: CredentialConfig,
    redirectURI: String,
    state: String,
    codeVerifier: String
) throws -> URL {
    guard var components = URLComponents(string: client.authURI) else {
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

private func parseCallbackCode(request: String, expectedState: String) throws -> String {
    guard let firstLine = request.components(separatedBy: "\r\n").first else {
        throw authError("OAuth callback request was empty")
    }
    let parts = firstLine.split(separator: " ")
    guard parts.count >= 2,
          let components = URLComponents(string: "http://127.0.0.1\(parts[1])") else {
        throw authError("OAuth callback request was malformed")
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
    guard let tokenURL = URL(string: client.tokenURI) else {
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

    let response = try performHTTPRequest(request, errorContext: "Gmail OAuth token exchange failed")
    guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
        throw authError("Gmail OAuth token response was not a JSON object")
    }
    guard let accessToken = nonBlank(object["access_token"] as? String) else {
        throw MailGatewayError(
            "Gmail OAuth token response did not include an access token",
            code: .authRequired,
            exitCode: .authenticationBootstrapError
        )
    }
    return GmailOAuthTokenResponse(
        accessToken: accessToken,
        refreshToken: nonBlank(object["refresh_token"] as? String),
        tokenType: nonBlank(object["token_type"] as? String),
        scope: nonBlank(object["scope"] as? String),
        expiresIn: object["expires_in"] as? Int
    )
}

private func validateGmailProfile(accessToken: String) throws -> GmailProfile {
    var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
    request.httpMethod = "GET"
    request.timeoutInterval = 30
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    let response = try performHTTPRequest(request, errorContext: "Gmail profile validation failed")
    guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
        throw authError("Gmail profile response was not a JSON object")
    }
    return GmailProfile(emailAddress: nonBlank(object["emailAddress"] as? String))
}

private func performHTTPRequest(_ request: URLRequest, errorContext: String) throws -> (data: Data, response: HTTPURLResponse) {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<(Data, HTTPURLResponse), Error>?
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer {
            semaphore.signal()
        }
        if let error {
            result = .failure(error)
            return
        }
        guard let data,
              let httpResponse = response as? HTTPURLResponse else {
            result = .failure(authError("HTTP response was empty"))
            return
        }
        result = .success((data, httpResponse))
    }.resume()
    semaphore.wait()

    let resolved: (Data, HTTPURLResponse)
    do {
        resolved = try result?.get() ?? {
            throw authError("HTTP request did not complete")
        }()
    } catch let error as MailGatewayError {
        throw error
    } catch {
        throw MailGatewayError(
            errorContext,
            code: .providerApiError,
            exitCode: .providerApiError,
            details: ["cause": error.localizedDescription]
        )
    }
    guard (200..<300).contains(resolved.1.statusCode) else {
        let body = String(data: resolved.0, encoding: .utf8) ?? ""
        throw MailGatewayError(
            errorContext,
            code: .providerApiError,
            exitCode: .providerApiError,
            details: ["httpStatus": String(resolved.1.statusCode), "body": String(body.prefix(1_000))]
        )
    }
    return resolved
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

private func writeTokenStore(_ tokenStore: GmailOAuthTokenStore, to path: String) throws {
    do {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(tokenStore)
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    } catch {
        throw MailGatewayError(
            "Failed to write Gmail OAuth token store",
            code: .authRequired,
            exitCode: .authenticationBootstrapError,
            details: ["path": path, "cause": error.localizedDescription]
        )
    }
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
    return base64URLEncoded(Data(bytes))
}

private func codeChallenge(for verifier: String) -> String {
    base64URLEncoded(Data(SHA256.hash(data: Data(verifier.utf8))))
}

private func base64URLEncoded(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func formURLEncoded(_ fields: [(String, String)]) -> String {
    fields
        .map { key, value in
            "\(urlFormEncode(key))=\(urlFormEncode(value))"
        }
        .joined(separator: "&")
}

private func urlFormEncode(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private func writeHTTPResponse(_ connection: Int32, success: Bool) throws {
    let body = success
        ? "<html><body>Gmail authentication completed. You can close this window.</body></html>"
        : "<html><body>Gmail authentication failed. Return to the terminal for details.</body></html>"
    let response = """
    HTTP/1.1 200 OK\r
    Content-Type: text/html; charset=utf-8\r
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
