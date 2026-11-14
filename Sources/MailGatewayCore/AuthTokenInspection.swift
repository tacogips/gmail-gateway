import Foundation

struct TokenInspectionResult {
    let state: AuthState
    let exists: Bool
    let grantedAccessMode: AccessMode?
    let expiresAt: String?
    let hasRefreshToken: Bool
}

func inspectTokenStore(credential: CredentialConfig) -> TokenInspectionResult {
    let exists: Bool
    let data: Data?
    if let tokenStoreJSON = credential.tokenStoreJSON {
        exists = true
        data = Data(tokenStoreJSON.utf8)
    } else if FileManager.default.isReadableFile(atPath: credential.tokenStorePath) {
        exists = true
        data = FileManager.default.contents(atPath: credential.tokenStorePath)
    } else {
        return missingTokenResult()
    }

    guard let data,
          let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return invalidTokenResult()
    }

    let accessMode = AccessMode(rawValue: parsed["accessMode"] as? String ?? "")
    let refreshToken = parsed["refreshToken"] as? String
    let hasRefreshToken = refreshToken?.isEmpty == false
    let expiresAt = (parsed["expiresAt"] as? String).flatMap(nonBlank)

    if let mismatch = scopeMismatchResult(
        grantedAccessMode: accessMode,
        configuredAccessMode: credential.accessMode,
        expiresAt: expiresAt,
        hasRefreshToken: hasRefreshToken
    ) {
        return mismatch
    }

    if let expiration = expirationResult(
        accessMode: accessMode,
        expiresAt: expiresAt,
        hasRefreshToken: hasRefreshToken
    ) {
        return expiration
    }

    return TokenInspectionResult(
        state: accessMode == nil ? .unknown : .ready,
        exists: exists,
        grantedAccessMode: accessMode,
        expiresAt: expiresAt,
        hasRefreshToken: hasRefreshToken
    )
}

private func missingTokenResult() -> TokenInspectionResult {
    TokenInspectionResult(
        state: .missing,
        exists: false,
        grantedAccessMode: nil,
        expiresAt: nil,
        hasRefreshToken: false
    )
}

private func invalidTokenResult() -> TokenInspectionResult {
    TokenInspectionResult(
        state: .invalid,
        exists: true,
        grantedAccessMode: nil,
        expiresAt: nil,
        hasRefreshToken: false
    )
}

private func scopeMismatchResult(
    grantedAccessMode: AccessMode?,
    configuredAccessMode: AccessMode,
    expiresAt: String?,
    hasRefreshToken: Bool
) -> TokenInspectionResult? {
    guard let grantedAccessMode,
          grantedAccessMode != configuredAccessMode else {
        return nil
    }
    return TokenInspectionResult(
        state: .scopeMismatch,
        exists: true,
        grantedAccessMode: grantedAccessMode,
        expiresAt: expiresAt,
        hasRefreshToken: hasRefreshToken
    )
}

private func expirationResult(
    accessMode: AccessMode?,
    expiresAt: String?,
    hasRefreshToken: Bool
) -> TokenInspectionResult? {
    guard let expiresAt else {
        return nil
    }
    guard let expiresAtDate = parseDate(expiresAt) else {
        return TokenInspectionResult(
            state: .invalid,
            exists: true,
            grantedAccessMode: accessMode,
            expiresAt: expiresAt,
            hasRefreshToken: hasRefreshToken
        )
    }
    guard expiresAtDate <= Date(),
          !hasRefreshToken else {
        return nil
    }
    return TokenInspectionResult(
        state: .expired,
        exists: true,
        grantedAccessMode: accessMode,
        expiresAt: expiresAt,
        hasRefreshToken: hasRefreshToken
    )
}

private func parseDate(_ value: String) -> Date? {
    if let date = ISO8601DateFormatter().date(from: value) {
        return date
    }
    return nil
}
