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
    case draftRead
    case draftCreation
    case draftUpdate
    case draftDelete
    case draftSend
    case directSend
    case mailboxModify
    case mailboxDelete
    case mailIngest

    var missingAuthMessage: String {
        switch self {
        case .read:
            return "Authentication is required before reading Gmail"
        case .draftRead:
            return "Authentication is required before reading Gmail drafts"
        case .draftCreation:
            return "Authentication is required before creating Gmail drafts"
        case .draftUpdate:
            return "Authentication is required before updating Gmail drafts"
        case .draftDelete:
            return "Authentication is required before deleting Gmail drafts"
        case .draftSend:
            return "Authentication is required before sending Gmail drafts"
        case .directSend:
            return "Authentication is required before sending Gmail messages"
        case .mailboxModify:
            return "Authentication is required before modifying stored Gmail mail"
        case .mailboxDelete:
            return "Authentication is required before permanently deleting Gmail mail"
        case .mailIngest:
            return "Authentication is required before importing Gmail messages"
        }
    }

    fileprivate var refreshPersistencePolicy: GmailRefreshPersistencePolicy {
        switch self {
        case .read:
            return .bestEffort
        case .draftRead, .draftCreation, .draftUpdate, .draftDelete, .draftSend, .directSend,
             .mailboxModify, .mailboxDelete, .mailIngest:
            return .required
        }
    }
}

private enum GmailRefreshPersistencePolicy {
    case bestEffort
    case required
}

private struct GmailTokenRefreshResponse: Decodable {
    let accessToken: String?
    let tokenType: String?
    let scope: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
        case expiresIn = "expires_in"
    }

    func normalized() -> GmailTokenRefreshResponse {
        GmailTokenRefreshResponse(
            accessToken: nonBlank(accessToken),
            tokenType: nonBlank(tokenType),
            scope: nonBlank(scope),
            expiresIn: expiresIn
        )
    }
}

private struct GoogleProviderErrorResponse: Decodable {
    let error: GoogleProviderError?
}

private struct GoogleProviderError: Decodable {
    let code: Int?
    let status: String?
    let message: String?
    let errors: [GoogleProviderErrorReason]?
}

private struct GoogleProviderErrorReason: Decodable {
    let reason: String?
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
    } catch let error as GmailGatewayError {
        throw error
    } catch {
        throw GmailGatewayError(
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

enum GmailHTTPRequestEffect: Equatable {
    case safeToCancel
    case gmailMutation
}

func performGmailHTTPRequest(
    _ request: URLRequest,
    context: String,
    effect: GmailHTTPRequestEffect = .safeToCancel
) throws -> (data: Data, response: HTTPURLResponse) {
    let maxAttempts = gmailHTTPMaxAttempts(for: request)
    let mutationMayHaveIrreversibleEffect = effect == .gmailMutation
    var attempt = 1
    while true {
        try GmailGatewayProviderCancellationContext.throwIfCancelled()
        try GmailGatewayProviderAttemptBudgetContext.consumeAttempt()
        let resolved: (data: Data, response: HTTPURLResponse)
        var requestWasDispatched = false
        do {
            resolved = try performSingleGmailHTTPRequest(
                request,
                context: context,
                cancelsWhenExecutionIsCancelled: !mutationMayHaveIrreversibleEffect,
                requestWasDispatched: &requestWasDispatched
            )
        } catch {
            if mutationMayHaveIrreversibleEffect,
               requestWasDispatched {
                throw GmailGatewayError(
                    "Gmail mutation outcome is unknown after the response was lost; do not retry automatically",
                    code: .mutationOutcomeUnknown,
                    exitCode: .graphqlExecutionError
                )
            }
            throw error
        }
        if (200..<300).contains(resolved.response.statusCode) {
            return resolved
        }
        if mutationMayHaveIrreversibleEffect {
            throw gmailProviderHTTPError(context: context, response: resolved.response, data: resolved.data)
        }
        try GmailGatewayProviderCancellationContext.throwIfCancelled()
        if attempt < maxAttempts,
           gmailHTTPStatusIsRetryable(resolved.response.statusCode) {
            try GmailGatewayProviderCancellationContext.throwIfCancelled()
            Thread.sleep(forTimeInterval: gmailHTTPRetryDelay(attempt: attempt))
            try GmailGatewayProviderCancellationContext.throwIfCancelled()
            attempt += 1
            continue
        }
        throw gmailProviderHTTPError(context: context, response: resolved.response, data: resolved.data)
    }
}

private func performSingleGmailHTTPRequest(
    _ request: URLRequest,
    context: String,
    cancelsWhenExecutionIsCancelled: Bool,
    requestWasDispatched: inout Bool
) throws -> (data: Data, response: HTTPURLResponse) {
    let semaphore = DispatchSemaphore(value: 0)
    let box = HTTPResultBox()
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer {
            semaphore.signal()
        }
        if let httpResponse = response as? HTTPURLResponse {
            box.store(.success((data ?? Data(), httpResponse)))
            return
        }
        if let error {
            box.store(.failure(error))
            return
        }
        box.store(.failure(GmailGatewayError(
            "Gmail API response was empty",
            code: .providerApiError,
            exitCode: .providerApiError
        )))
    }
    let cancellationIdentifier = try GmailGatewayProviderCancellationContext.start(
        task,
        cancelsWhenExecutionIsCancelled: cancelsWhenExecutionIsCancelled
    )
    requestWasDispatched = cancellationIdentifier != nil
    defer { GmailGatewayProviderCancellationContext.finish(cancellationIdentifier) }
    if cancellationIdentifier == nil {
        task.resume()
        requestWasDispatched = true
    }
    if semaphore.wait(timeout: gmailHTTPResponseDeadline(for: request)) == .timedOut {
        task.cancel()
        throw GmailGatewayError(
            "Gmail API response did not arrive before the request deadline",
            code: .providerApiError,
            exitCode: .providerApiError
        )
    }
    if cancelsWhenExecutionIsCancelled {
        try GmailGatewayProviderCancellationContext.throwIfCancelled()
    }

    let resolved: (data: Data, response: HTTPURLResponse)
    do {
        resolved = try box.load()?.get() ?? {
            throw GmailGatewayError(
                "Gmail API request did not complete",
                code: .providerApiError,
                exitCode: .providerApiError
            )
        }()
    } catch let error as GmailGatewayError {
        throw error
    } catch {
        throw GmailGatewayError(
            context,
            code: .providerApiError,
            exitCode: .providerApiError,
            details: ["cause": error.localizedDescription]
        )
    }
    return resolved
}

/// Applies an absolute application deadline to a response that may otherwise keep
/// delivering bytes and reset URLSession's inactivity timeout. Gmail request builders
/// use 30 seconds; the cap prevents a caller-owned request from extending a provider
/// worker beyond that bounded interval.
private func gmailHTTPResponseDeadline(for request: URLRequest) -> DispatchTime {
    let configuredInterval = request.timeoutInterval
    let interval = configuredInterval > 0
        ? min(configuredInterval, gmailHTTPMaximumResponseWait)
        : gmailHTTPMaximumResponseWait
    return .now() + interval
}

private let gmailHTTPMaximumResponseWait: TimeInterval = 30

private func gmailHTTPMaxAttempts(for request: URLRequest) -> Int {
    let method = request.httpMethod?.uppercased() ?? "GET"
    return method == "GET" ? 3 : 1
}

private func gmailProviderHTTPError(
    context: String,
    response: HTTPURLResponse,
    data: Data
) -> GmailGatewayError {
    let code: GmailGatewayErrorCode = response.statusCode == 429 ? .providerRateLimited : .providerApiError
    return GmailGatewayError(
        context,
        code: code,
        exitCode: .providerApiError,
        details: gmailProviderErrorDetails(statusCode: response.statusCode, data: data)
    )
}

private func gmailHTTPStatusIsRetryable(_ statusCode: Int) -> Bool {
    statusCode == 429 || (500...599).contains(statusCode)
}

private func gmailHTTPRetryDelay(attempt: Int) -> TimeInterval {
    0.05 * Double(attempt)
}

func gmailProviderErrorDetails(statusCode: Int, data: Data) -> [String: String] {
    var details = ["httpStatus": String(statusCode)]
    guard let error = try? JSONDecoder().decode(GoogleProviderErrorResponse.self, from: data).error else {
        return details
    }

    if let code = error.code {
        details["providerErrorCode"] = String(code)
    }
    // Google error strings are provider-controlled and may echo a bearer token, client secret,
    // or a request parameter. Do not surface any provider string field: there is no reliable
    // allow-list for values that can be returned by a proxy or future provider response.
    return details
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
    exitCode: GmailGatewayExitCode,
    replacing expectedState: PersistentTokenFileExpectedState? = nil
) throws {
    do {
        let data = try JSONEncoder().encode(tokenStore)
        if let expectedState {
            let credential = CredentialConfig(
                id: "persistent-token-file",
                provider: .gmail,
                accessMode: tokenStore.accessMode,
                oauthClientSecretPath: "",
                oauthClientSecretJSON: nil,
                tokenStorePath: path,
                tokenStoreJSON: nil
            )
            try writeSecureGmailOAuthTokenData(
                data,
                to: path,
                credential: credential,
                errorMessage: errorMessage,
                exitCode: exitCode,
                replacing: expectedState
            )
        } else {
            try writeLegacyGmailOAuthTokenData(data, to: path)
        }
    } catch let error as GmailGatewayError {
        throw error
    } catch {
        throw GmailGatewayError(
            errorMessage,
            code: .authRequired,
            exitCode: exitCode,
            details: ["path": path, "cause": error.localizedDescription]
        )
    }
}

/// The legacy executables intentionally retain their established atomic token
/// replacement behavior. Persistent coordinator flows pass an expected state
/// and use the descriptor-relative transaction writer while holding its
/// lifecycle lock.
private func writeLegacyGmailOAuthTokenData(_ data: Data, to path: String) throws {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
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
            throw GmailGatewayError(
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
            throw GmailGatewayError(
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

private func invalidOAuthClientError(credential: CredentialConfig, use: GoogleOAuthClientUse) -> GmailGatewayError {
    GmailGatewayError(
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

private func oauthClientLoadExitCode(_ use: GoogleOAuthClientUse) -> GmailGatewayExitCode {
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
                throw GmailGatewayError(
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
            throw GmailGatewayError(
                "Stored Gmail token scope does not match configured access mode",
                code: .authRequired,
                exitCode: .graphqlExecutionError,
                details: ["credentialId": credential.id]
            )
        }
        return tokenStore
    } catch let error as GmailGatewayError {
        throw error
    } catch {
        throw GmailGatewayError(
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
    let refreshed = try refreshedGmailOAuthTokenStore(credential: credential, tokenStore: tokenStore)
    guard credential.tokenStoreJSON == nil else {
        return refreshed.accessToken
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
    return refreshed.accessToken
}

func refreshedGmailOAuthTokenStore(
    credential: CredentialConfig,
    tokenStore: GmailOAuthTokenStore
) throws -> GmailOAuthTokenStore {
    guard let refreshToken = nonBlank(tokenStore.refreshToken) else {
        throw GmailGatewayError(
            "Stored Gmail access token is expired and has no refresh token",
            code: .authRequired,
            exitCode: .graphqlExecutionError,
            details: ["credentialId": credential.id]
        )
    }
    let client = try loadGoogleOAuthClient(credential: credential, use: .tokenRefresh)
    guard let tokenURI = nonBlank(client.tokenURI),
          let tokenURL = URL(string: tokenURI) else {
        throw GmailGatewayError(
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
    let tokenResponse: GmailTokenRefreshResponse
    do {
        tokenResponse = try JSONDecoder().decode(GmailTokenRefreshResponse.self, from: response.data).normalized()
    } catch {
        throw GmailGatewayError(
            "Gmail token refresh response did not include an access token",
            code: .authRequired,
            exitCode: .graphqlExecutionError,
            details: ["credentialId": credential.id]
        )
    }
    guard let accessToken = nonBlank(tokenResponse.accessToken) else {
        throw GmailGatewayError(
            "Gmail token refresh response did not include an access token",
            code: .authRequired,
            exitCode: .graphqlExecutionError,
            details: ["credentialId": credential.id]
        )
    }
    if tokenStore.clientFingerprint != nil,
       let returnedScope = tokenResponse.scope,
       Set(normalizedGmailScopes(returnedScope)) != Set(gmailScopes(accessMode: credential.accessMode)) {
        throw GmailGatewayError(
            "Gmail token refresh returned incompatible scopes",
            code: .authRequired,
            exitCode: .graphqlExecutionError,
            details: ["credentialId": credential.id]
        )
    }

    let refreshed = GmailOAuthTokenStore(
        accessMode: tokenStore.accessMode,
        accessToken: accessToken,
        refreshToken: tokenStore.refreshToken,
        tokenType: tokenResponse.tokenType ?? tokenStore.tokenType,
        scope: tokenResponse.scope ?? tokenStore.scope,
        expiresAt: tokenResponse.expiresIn.map {
            ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval($0)))
        },
        emailAddress: tokenStore.emailAddress,
        clientFingerprint: tokenStore.clientFingerprint,
        schemaVersion: tokenStore.schemaVersion,
        provider: tokenStore.provider,
        credentialId: tokenStore.credentialId
    )
    return refreshed
}
