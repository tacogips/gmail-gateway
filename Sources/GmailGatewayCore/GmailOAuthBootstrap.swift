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

struct GmailOAuthLoginResult: Sendable {
    let tokenStore: GmailOAuthTokenStore
    let redirectURI: String
}

private func loadGmailOAuthClientRecord(for credential: CredentialConfig) throws -> GmailOAuthClientRecord {
    do {
        if let clientJSON = credential.oauthClientSecretJSON {
            return try loadGmailOAuthClientRecord(from: Data(clientJSON.utf8))
        }
        return try loadGmailOAuthClientRecord(from: credential.oauthClientSecretPath)
    } catch let error as GmailGatewayError {
        throw GmailGatewayError(
            "Failed to read Gmail OAuth client JSON",
            code: error.code,
            exitCode: .authenticationBootstrapError,
            details: ["credentialId": credential.id, "path": credential.oauthClientSecretPath]
        )
    }
}

struct GmailOAuthBootstrapper {
    private let receiverFactory: @Sendable (GmailLoopbackRedirectURI) throws -> LoopbackOAuthReceiver
    private let browserOpener: @Sendable (URL) throws -> Void
    private let beforeTokenExchange: @Sendable () -> Void

    init(
        receiverFactory: @escaping @Sendable (GmailLoopbackRedirectURI) throws -> LoopbackOAuthReceiver = { redirect in
            try LoopbackOAuthReceiver(redirect: redirect)
        },
        browserOpener: @escaping @Sendable (URL) throws -> Void = openBrowser,
        beforeTokenExchange: @escaping @Sendable () -> Void = {}
    ) {
        self.receiverFactory = receiverFactory
        self.browserOpener = browserOpener
        self.beforeTokenExchange = beforeTokenExchange
    }

    func login(credential: CredentialConfig, options: GmailOAuthLoginOptions = GmailOAuthLoginOptions()) throws -> [String: Any] {
        let result = try loginResult(credential: credential, options: options)
        try writeGmailOAuthTokenStore(
            result.tokenStore,
            to: credential.tokenStorePath,
            errorMessage: "Failed to write Gmail OAuth token store",
            exitCode: .authenticationBootstrapError
        )
        return [
            "credentialId": credential.id,
            "provider": credential.provider.rawValue,
            "state": AuthState.ready.rawValue,
            "tokenStorePath": credential.tokenStorePath,
            "redirectUri": result.redirectURI,
            "emailAddress": result.tokenStore.emailAddress as Any? ?? NSNull(),
            "expiresAt": result.tokenStore.expiresAt as Any? ?? NSNull(),
            "hasRefreshToken": result.tokenStore.refreshToken?.isEmpty == false
        ]
    }

    func loginResult(
        credential: CredentialConfig,
        options: GmailOAuthLoginOptions = GmailOAuthLoginOptions()
    ) throws -> GmailOAuthLoginResult {
        let profile = try loadGmailOAuthClientRecord(for: credential)
        let client = GoogleOAuthClient(
            clientId: profile.clientId,
            clientSecret: profile.clientSecret,
            authURI: profile.authorizationEndpoint,
            tokenURI: profile.tokenEndpoint
        )
        let redirect: GmailLoopbackRedirectURI
        do {
            redirect = try selectedGmailOAuthLoopbackRedirect(client: profile, requestedURI: options.redirectURI)
        } catch where options.redirectURI != nil {
            throw authError("OAuth redirect URI must be a registered http:// loopback URL")
        }
        let receiver = try receiverFactory(redirect)
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
            try browserOpener(authorizationURL)
        } else {
            guard isInteractiveTerminal() else {
                throw authError("Manual OAuth authorization requires an interactive terminal")
            }
            writeManualAuthorizationMessage(authorizationURL)
        }
        let code = try receiver.waitForCode(expectedState: state, timeoutSeconds: options.timeoutSeconds)
        beforeTokenExchange()
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
        return GmailOAuthLoginResult(tokenStore: tokenStore, redirectURI: receiver.redirectURI)
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

struct GmailOAuthTokenStore: Codable, Sendable {
    let accessMode: AccessMode
    let accessToken: String
    let refreshToken: String?
    let tokenType: String?
    let scope: String?
    let expiresAt: String?
    let emailAddress: String?
    let clientFingerprint: String?
    /// Current persistent-token records are bound to a credential so a valid
    /// token cannot be copied between same-scope credentials. All three fields
    /// being absent denotes a legacy record that must be re-authorized before
    /// persistent provider use.
    let schemaVersion: Int?
    let provider: MailProvider?
    let credentialId: String?

    init(
        accessMode: AccessMode,
        accessToken: String,
        refreshToken: String?,
        tokenType: String?,
        scope: String?,
        expiresAt: String?,
        emailAddress: String?,
        clientFingerprint: String?,
        schemaVersion: Int? = nil,
        provider: MailProvider? = nil,
        credentialId: String? = nil
    ) {
        self.accessMode = accessMode
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.scope = scope
        self.expiresAt = expiresAt
        self.emailAddress = emailAddress
        self.clientFingerprint = clientFingerprint
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.credentialId = credentialId
    }
}

private struct LoopbackOAuthListener {
    let descriptor: Int32
    let addressFamily: Int32
}

final class LoopbackOAuthReceiver: @unchecked Sendable {
    let redirectURI: String
    private let listeners: [LoopbackOAuthListener]
    private let redirect: GmailLoopbackRedirectURI

    convenience init(
        redirectURI: String? = nil,
        localhostAddressResolver: @escaping @Sendable () throws -> [String] = resolvedLocalhostLoopbackAddresses
    ) throws {
        let redirect = try redirectURI.map(GmailLoopbackRedirectURI.init) ?? .defaultCallback
        try self.init(redirect: redirect, localhostAddressResolver: localhostAddressResolver)
    }

    init(
        redirect: GmailLoopbackRedirectURI,
        localhostAddressResolver: @escaping @Sendable () throws -> [String] = resolvedLocalhostLoopbackAddresses
    ) throws {
        let hosts = try loopbackListenerHosts(for: redirect, localhostAddressResolver: localhostAddressResolver)
        var opened: [LoopbackOAuthListener] = []
        do {
            var boundPort = redirect.port ?? 0
            for host in hosts {
                let listener = try openLoopbackOAuthListener(host: host, port: boundPort)
                opened.append(listener)
                if boundPort == 0 {
                    boundPort = try loopbackBoundPort(listener.descriptor, addressFamily: listener.addressFamily)
                    guard boundPort != 0 else { throw authError("Failed to resolve OAuth callback port") }
                }
            }
            listeners = opened
            self.redirect = redirect
            redirectURI = redirect.absoluteString(port: boundPort)
        } catch {
            opened.forEach { close($0.descriptor) }
            throw error
        }
    }

    deinit {
        listeners.forEach { close($0.descriptor) }
    }

    func waitForCode(expectedState: String, timeoutSeconds: Int32) throws -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            let remainingMilliseconds = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
            var pollSet = listeners.map { pollfd(fd: $0.descriptor, events: Int16(POLLIN), revents: 0) }
            let pollResult = Darwin.poll(&pollSet, nfds_t(pollSet.count), remainingMilliseconds)
            guard pollResult > 0 else {
                break
            }
            guard let listenerIndex = pollSet.firstIndex(where: { $0.revents & Int16(POLLIN) != 0 }) else {
                continue
            }
            let connection = accept(listeners[listenerIndex].descriptor, nil, nil)
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

private func loopbackListenerHosts(
    for redirect: GmailLoopbackRedirectURI,
    localhostAddressResolver: @Sendable () throws -> [String]
) throws -> [String] {
    guard redirect.host == "localhost" else { return [redirect.host] }
    let hosts = try localhostAddressResolver()
    let normalized = Array(Set(hosts.map { $0 == "[::1]" ? "::1" : $0.lowercased() })).sorted()
    guard !normalized.isEmpty, normalized.allSatisfy({ $0 == "127.0.0.1" || $0 == "::1" }) else {
        throw authError("localhost must resolve only to loopback addresses")
    }
    return normalized
}

private func resolvedLocalhostLoopbackAddresses() throws -> [String] {
    // `localhost` is not assumed to be safe: deployments can override it.
    // Resolving before binding also makes the set of listeners test-injectable.
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = IPPROTO_TCP
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo("localhost", nil, &hints, &result) == 0, let result else {
        throw authError("Failed to resolve OAuth callback host")
    }
    defer { freeaddrinfo(result) }
    var addresses: [String] = []
    var cursor: UnsafeMutablePointer<addrinfo>? = result
    while let entry = cursor {
        switch entry.pointee.ai_family {
        case AF_INET:
            var address = entry.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil {
                addresses.append(loopbackAddressString(buffer))
            }
        case AF_INET6:
            var address = entry.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil {
                addresses.append(loopbackAddressString(buffer))
            }
        default:
            break
        }
        cursor = entry.pointee.ai_next
    }
    return addresses
}

private func loopbackAddressString(_ bytes: [CChar]) -> String {
    String(bytes: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
}

private func openLoopbackOAuthListener(host: String, port: UInt16) throws -> LoopbackOAuthListener {
    let addressFamily: Int32 = host == "::1" ? AF_INET6 : AF_INET
    let descriptor = socket(addressFamily, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw authError("Failed to create OAuth callback socket") }
    do {
        var reuse: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw authError("Failed to configure OAuth callback socket")
        }
        guard try bindLoopbackSocket(descriptor, host: host, port: port) == 0 else {
            throw authError("Failed to bind OAuth callback socket to \(host):\(port)")
        }
        guard listen(descriptor, 1) == 0 else { throw authError("Failed to listen for OAuth callback") }
        return LoopbackOAuthListener(descriptor: descriptor, addressFamily: addressFamily)
    } catch {
        close(descriptor)
        throw error
    }
}

private func bindLoopbackSocket(_ fd: Int32, host: String, port: UInt16) throws -> Int32 {
    switch host == "::1" ? AF_INET6 : AF_INET {
    case AF_INET:
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            throw authError("Failed to resolve OAuth callback host")
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    case AF_INET6:
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET6, host, &address.sin6_addr) == 1 else {
            throw authError("Failed to resolve OAuth callback host")
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
    default:
        throw authError("OAuth callback uses an unsupported address family")
    }
}

private func loopbackBoundPort(_ fd: Int32, addressFamily: Int32) throws -> UInt16 {
    switch addressFamily {
    case AF_INET:
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(fd, socketAddress, &length)
            }
        }
        guard result == 0 else {
            throw authError("Failed to resolve OAuth callback port")
        }
        return UInt16(bigEndian: address.sin_port)
    case AF_INET6:
        var address = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(fd, socketAddress, &length)
            }
        }
        guard result == 0 else {
            throw authError("Failed to resolve OAuth callback port")
        }
        return UInt16(bigEndian: address.sin6_port)
    default:
        throw authError("OAuth callback uses an unsupported address family")
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

private func callbackRequestPathMatches(request: String, redirect: GmailLoopbackRedirectURI) -> Bool {
    guard let firstLine = request.components(separatedBy: "\r\n").first else {
        return false
    }
    let parts = firstLine.split(separator: " ")
    guard parts.count >= 2,
          let components = URLComponents(string: "http://localhost\(parts[1])") else {
        return false
    }
    return components.percentEncodedPath == redirect.path
}

func buildAuthorizationURL(
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
        URLQueryItem(name: "include_granted_scopes", value: "false"),
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
        throw GmailGatewayError(
            "Failed to open browser for Gmail OAuth",
            code: .authRequired,
            exitCode: .authenticationBootstrapError,
            details: ["cause": error.localizedDescription]
        )
    }
    guard process.terminationStatus == 0 else {
        throw GmailGatewayError(
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

private func isInteractiveTerminal() -> Bool {
    isatty(STDERR_FILENO) == 1
}

private func parseCallbackCode(
    request: String,
    redirect: GmailLoopbackRedirectURI,
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
    guard let components = URLComponents(string: "http://localhost\(parts[1])") else {
        throw authError("OAuth callback request was malformed")
    }
    guard components.percentEncodedPath == redirect.path else {
        throw authError("OAuth callback path did not match the configured redirect URI")
    }
    var query: [String: String] = [:]
    for item in components.queryItems ?? [] {
        query[item.name] = item.value ?? ""
    }
    guard query["state"] == expectedState else {
        throw authError("Gmail OAuth callback state did not match")
    }
    if query["error"] != nil {
        throw GmailGatewayError(
            "Gmail OAuth authorization failed",
            code: .authRequired,
            exitCode: .authenticationBootstrapError
        )
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
        throw GmailGatewayError(
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
        emailAddress: profile.emailAddress,
        clientFingerprint: nil
    )
}

func gmailScopes(accessMode: AccessMode) -> [String] {
    switch accessMode {
    case .read:
        return ["https://www.googleapis.com/auth/gmail.readonly"]
    case .readSend:
        return [
            "https://www.googleapis.com/auth/gmail.readonly",
            "https://www.googleapis.com/auth/gmail.compose",
            "https://www.googleapis.com/auth/gmail.send"
        ]
    case .readModify:
        // gmail.modify covers label mutation, trash, and untrash; gmail.insert covers
        // import and insert. Neither covers permanent delete, which needs .full.
        return [
            "https://www.googleapis.com/auth/gmail.readonly",
            "https://www.googleapis.com/auth/gmail.modify",
            "https://www.googleapis.com/auth/gmail.insert"
        ]
    case .full:
        // Permanent delete (messages.delete, threads.delete, messages.batchDelete) accepts
        // only the full-access scope.
        return ["https://mail.google.com/"]
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

private func authError(_ message: String) -> GmailGatewayError {
    GmailGatewayError(
        message,
        code: .authRequired,
        exitCode: .authenticationBootstrapError
    )
}
