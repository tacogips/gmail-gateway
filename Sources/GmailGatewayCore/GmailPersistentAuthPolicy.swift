import Foundation

/// Persistent authentication is deliberately opt-in so existing library callers
/// and the two excluded executables keep their historical file-based behavior.
public enum GmailAuthPolicy: Sendable {
    case legacy
    case persistent(requiredAccessMode: AccessMode)

    var requiredAccessMode: AccessMode? {
        if case let .persistent(requiredAccessMode) = self {
            return requiredAccessMode
        }
        return nil
    }
}

enum GmailCredentialSourceKind: String, Sendable {
    case environmentJSON = "ENVIRONMENT_JSON"
    case environmentPath = "ENVIRONMENT_PATH"
    case configuredPath = "CONFIGURED_PATH"
    case relocatedPath = "RELOCATED_PATH"
    case secureVault = "SECURE_VAULT"
    case synthesizedDefault = "SYNTHESIZED_DEFAULT"
}

struct ResolvedCredentialSource<Value: Sendable>: Sendable {
    let value: Value
    let kind: GmailCredentialSourceKind
    let writable: Bool
}

func validatePersistentCredential(_ credential: CredentialConfig, policy: GmailAuthPolicy) throws {
    guard credential.id.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
        throw GmailGatewayError("credential ID is invalid", code: .invalidArgument, exitCode: .invalidCliUsage)
    }
    guard let required = policy.requiredAccessMode else { return }
    guard credential.provider == .gmail, credential.accessMode == required else {
        throw GmailGatewayError(
            "credential access mode does not match this executable",
            code: .authRequired,
            exitCode: .authenticationBootstrapError,
            details: ["credentialId": credential.id, "requiredAccessMode": required.rawValue]
        )
    }
}

func persistentPolicy(for mode: GmailGatewayCLIMode) -> GmailAuthPolicy {
    switch mode {
    case .reader:
        return .persistent(requiredAccessMode: .read)
    case .draftGateway, .directSender:
        return .persistent(requiredAccessMode: .readSend)
    case .mailboxThreads, .messageBox:
        return .legacy
    }
}
