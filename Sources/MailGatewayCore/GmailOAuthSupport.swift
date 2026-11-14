import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let gmailTokenRefreshLeeway: TimeInterval = 60

struct GoogleOAuthClient: Decodable {
    let clientId: String
    let clientSecret: String?
    let authURI: String?
    let tokenURI: String?

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case clientSecret = "client_secret"
        case authURI = "auth_uri"
        case tokenURI = "token_uri"
    }
}

enum GoogleOAuthClientUse {
    case desktopLogin
    case tokenRefresh
}

enum GmailAccessTokenUse {
    case read
    case draftCreation
    case directSend

    var missingAuthMessage: String {
        switch self {
        case .read:
            return "Authentication is required before reading Gmail"
        case .draftCreation:
            return "Authentication is required before creating Gmail drafts"
        case .directSend:
            return "Authentication is required before sending Gmail messages"
        }
    }

    fileprivate var refreshPersistencePolicy: GmailRefreshPersistencePolicy {
        switch self {
        case .read:
            return .bestEffort
        case .draftCreation, .directSend:
            return .required
        }
    }
}

private enum GmailRefreshPersistencePolicy {
    case bestEffort
    case required
}

private enum GoogleOAuthClientSource {
    case installed
    case web
}

private struct GoogleOAuthClientFile: Decodable {
    let installed: GoogleOAuthClient?
    let web: GoogleOAuthClient?
}

func loadGoogleOAuthClient(credential: CredentialConfig, use: GoogleOAuthClientUse) throws -> GoogleOAuthClient {
    do {
        let data: Data
        if let oauthClientSecretJSON = credential.oauthClientSecretJSON {
            data = Data(oauthClientSecretJSON.utf8)
        } else {
            data = try Data(contentsOf: URL(fileURLWithPath: credential.oauthClientSecretPath))
        }
        let decoded = try JSONDecoder().decode(GoogleOAuthClientFile.self, from: data)
        let selected = try selectGoogleOAuthClient(decoded, credential: credential, use: use)
        let client = normalizedGoogleOAuthClient(selected.client)
        try validateGoogleOAuthClient(
            client,
            source: selected.source,
            credential: credential,
            use: use
        )
        return client
    } catch let error as MailGatewayError {
        throw error
    } catch {
        throw MailGatewayError(
            "Failed to read Gmail OAuth client JSON",
            code: .configInvalid,
            exitCode: oauthClientLoadExitCode(use),
            details: ["credentialId": credential.id, "path": credential.oauthClientSecretPath, "cause": error.localizedDescription]
        )
    }
}

func validGmailAccessToken(
    credential: CredentialConfig,
    use: GmailAccessTokenUse
) throws -> String {
    let tokenStore = try loadGmailOAuthTokenStore(credential: credential, missingAuthMessage: use.missingAuthMessage)
    let accessToken = nonBlank(tokenStore.accessToken)
    if let accessToken,
       gmailAccessTokenIsFresh(expiresAt: tokenStore.expiresAt) {
        return accessToken
    }
    return try refreshGmailAccessToken(
        credential: credential,
        tokenStore: tokenStore,
        persistencePolicy: use.refreshPersistencePolicy
    )
}

func performGmailHTTPRequest(_ request: URLRequest, context: String) throws -> (data: Data, response: HTTPURLResponse) {
    let semaphore = DispatchSemaphore(value: 0)
    let box = HTTPResultBox()
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer {
            semaphore.signal()
        }
        if let error {
            box.store(.failure(error))
            return
        }
        guard let data,
              let httpResponse = response as? HTTPURLResponse else {
            box.store(.failure(MailGatewayError(
                "Gmail API response was empty",
                code: .providerApiError,
                exitCode: .providerApiError
            )))
            return
        }
        box.store(.success((data, httpResponse)))
    }.resume()
    semaphore.wait()

    let resolved: (data: Data, response: HTTPURLResponse)
    do {
        resolved = try box.load()?.get() ?? {
            throw MailGatewayError(
                "Gmail API request did not complete",
                code: .providerApiError,
                exitCode: .providerApiError
            )
        }()
    } catch let error as MailGatewayError {
        throw error
    } catch {
        throw MailGatewayError(
            context,
            code: .providerApiError,
            exitCode: .providerApiError,
            details: ["cause": error.localizedDescription]
        )
    }

    guard (200..<300).contains(resolved.response.statusCode) else {
        let body = String(data: resolved.data, encoding: .utf8) ?? ""
        let code: MailGatewayErrorCode = resolved.response.statusCode == 429 ? .providerRateLimited : .providerApiError
        throw MailGatewayError(
            context,
            code: code,
            exitCode: .providerApiError,
            details: ["httpStatus": String(resolved.response.statusCode), "body": String(body.prefix(1_000))]
        )
    }
    return resolved
}

private final class HTTPResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<(Data, HTTPURLResponse), Error>?

    func store(_ result: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> Result<(Data, HTTPURLResponse), Error>? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return result
    }
}

func writeGmailOAuthTokenStore(
    _ tokenStore: GmailOAuthTokenStore,
    to path: String,
    errorMessage: String,
    exitCode: MailGatewayExitCode
) throws {
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
            errorMessage,
            code: .authRequired,
            exitCode: exitCode,
            details: ["path": path, "cause": error.localizedDescription]
        )
    }
}

func gmailAccessTokenIsFresh(
    expiresAt: String?,
    now: Date = Date(),
    refreshLeeway: TimeInterval = gmailTokenRefreshLeeway
) -> Bool {
    guard let expiresAt = nonBlank(expiresAt) else {
        return true
    }
    guard let expiresAtDate = ISO8601DateFormatter().date(from: expiresAt) else {
        return false
    }
    return expiresAtDate > now.addingTimeInterval(refreshLeeway)
}

private func selectGoogleOAuthClient(
    _ file: GoogleOAuthClientFile,
    credential: CredentialConfig,
    use: GoogleOAuthClientUse
) throws -> (client: GoogleOAuthClient, source: GoogleOAuthClientSource) {
    switch use {
    case .desktopLogin:
        guard let installed = file.installed else {
            throw MailGatewayError(
                "OAuth client JSON must contain an installed desktop client",
                code: .configInvalid,
                exitCode: .authenticationBootstrapError,
                details: ["credentialId": credential.id, "path": credential.oauthClientSecretPath]
            )
        }
        return (installed, .installed)
    case .tokenRefresh:
        if let installed = file.installed {
            return (installed, .installed)
        }
        guard let web = file.web else {
            throw MailGatewayError(
                "OAuth client JSON must contain installed or web credentials",
                code: .configInvalid,
                exitCode: .configurationError,
                details: ["credentialId": credential.id, "path": credential.oauthClientSecretPath]
            )
        }
        return (web, .web)
    }
}

private func normalizedGoogleOAuthClient(_ client: GoogleOAuthClient) -> GoogleOAuthClient {
    GoogleOAuthClient(
        clientId: nonBlank(client.clientId) ?? "",
        clientSecret: nonBlank(client.clientSecret),
        authURI: nonBlank(client.authURI),
        tokenURI: nonBlank(client.tokenURI)
    )
}

private func validateGoogleOAuthClient(
    _ client: GoogleOAuthClient,
    source: GoogleOAuthClientSource,
    credential: CredentialConfig,
    use: GoogleOAuthClientUse
) throws {
    guard nonBlank(client.clientId) != nil,
          nonBlank(client.tokenURI) != nil else {
        throw invalidOAuthClientError(credential: credential, use: use)
    }
    if use == .desktopLogin,
       nonBlank(client.authURI) == nil {
        throw invalidOAuthClientError(credential: credential, use: use)
    }
    if use == .tokenRefresh,
       source == .web,
       nonBlank(client.clientSecret) == nil {
        throw invalidOAuthClientError(credential: credential, use: use)
    }
}

private func invalidOAuthClientError(credential: CredentialConfig, use: GoogleOAuthClientUse) -> MailGatewayError {
    MailGatewayError(
        oauthClientInvalidMessage(use),
        code: .configInvalid,
        exitCode: oauthClientLoadExitCode(use),
        details: ["credentialId": credential.id, "path": credential.oauthClientSecretPath]
    )
}

private func oauthClientInvalidMessage(_ use: GoogleOAuthClientUse) -> String {
    switch use {
    case .desktopLogin:
        return "OAuth client JSON must contain an installed desktop client"
    case .tokenRefresh:
        return "OAuth client JSON must contain refreshable installed or web credentials"
    }
}

private func oauthClientLoadExitCode(_ use: GoogleOAuthClientUse) -> MailGatewayExitCode {
    switch use {
    case .desktopLogin:
        return .authenticationBootstrapError
    case .tokenRefresh:
        return .configurationError
    }
}

private func loadGmailOAuthTokenStore(
    credential: CredentialConfig,
    missingAuthMessage: String
) throws -> GmailOAuthTokenStore {
    do {
        let data: Data
        if let tokenStoreJSON = credential.tokenStoreJSON {
            data = Data(tokenStoreJSON.utf8)
        } else {
            guard FileManager.default.isReadableFile(atPath: credential.tokenStorePath) else {
                throw MailGatewayError(
                    missingAuthMessage,
                    code: .authRequired,
                    exitCode: .graphqlExecutionError,
                    details: ["credentialId": credential.id, "tokenStorePath": credential.tokenStorePath]
                )
            }
            data = try Data(contentsOf: URL(fileURLWithPath: credential.tokenStorePath))
        }
        let tokenStore = try JSONDecoder().decode(GmailOAuthTokenStore.self, from: data)
        guard tokenStore.accessMode == credential.accessMode else {
            throw MailGatewayError(
                "Stored Gmail token scope does not match configured access mode",
                code: .authRequired,
                exitCode: .graphqlExecutionError,
                details: ["credentialId": credential.id]
            )
        }
        return tokenStore
    } catch let error as MailGatewayError {
        throw error
    } catch {
        throw MailGatewayError(
            "Failed to read Gmail token store",
            code: .authRequired,
            exitCode: .graphqlExecutionError,
            details: ["credentialId": credential.id, "cause": error.localizedDescription]
        )
    }
}

private func refreshGmailAccessToken(
    credential: CredentialConfig,
    tokenStore: GmailOAuthTokenStore,
    persistencePolicy: GmailRefreshPersistencePolicy
) throws -> String {
    guard let refreshToken = nonBlank(tokenStore.refreshToken) else {
        throw MailGatewayError(
            "Stored Gmail access token is expired and has no refresh token",
            code: .authRequired,
            exitCode: .graphqlExecutionError,
            details: ["credentialId": credential.id]
        )
    }
    let client = try loadGoogleOAuthClient(credential: credential, use: .tokenRefresh)
    guard let tokenURI = nonBlank(client.tokenURI),
          let tokenURL = URL(string: tokenURI) else {
        throw MailGatewayError(
            "OAuth client token_uri is invalid",
            code: .configInvalid,
            exitCode: .configurationError,
            details: ["credentialId": credential.id]
        )
    }

    var fields = [
        ("client_id", client.clientId),
        ("grant_type", "refresh_token"),
        ("refresh_token", refreshToken)
    ]
    if let clientSecret = nonBlank(client.clientSecret) {
        fields.append(("client_secret", clientSecret))
    }

    var request = URLRequest(url: tokenURL)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formURLEncoded(fields).data(using: .utf8)
    let response = try performGmailHTTPRequest(request, context: "Gmail token refresh failed")
    guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
          let accessToken = nonBlank(object["access_token"] as? String) else {
        throw MailGatewayError(
            "Gmail token refresh response did not include an access token",
            code: .authRequired,
            exitCode: .graphqlExecutionError,
            details: ["credentialId": credential.id]
        )
    }

    let refreshed = GmailOAuthTokenStore(
        accessMode: tokenStore.accessMode,
        accessToken: accessToken,
        refreshToken: tokenStore.refreshToken,
        tokenType: nonBlank(object["token_type"] as? String) ?? tokenStore.tokenType,
        scope: nonBlank(object["scope"] as? String) ?? tokenStore.scope,
        expiresAt: intValue(object["expires_in"]).map {
            ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval($0)))
        },
        emailAddress: tokenStore.emailAddress
    )
    guard credential.tokenStoreJSON == nil else {
        return accessToken
    }
    do {
        try writeGmailOAuthTokenStore(
            refreshed,
            to: credential.tokenStorePath,
            errorMessage: "Failed to write refreshed Gmail token store",
            exitCode: .graphqlExecutionError
        )
    } catch {
        if persistencePolicy == .required {
            throw error
        }
    }
    return accessToken
}
