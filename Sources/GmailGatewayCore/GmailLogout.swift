import Foundation
import GoogleGatewayAuth

extension GmailGatewayService {
    public func logoutAuth(credentialId: String) throws -> [String: Any] {
        let credential = try requireCredential(credentialId)
        let external = credential.directAccessToken != nil || credential.tokenStoreJSON != nil
            || credential.tokenStoreSource == .environmentPath
        let result = try GatewayLogout.perform(externalCredential: external) {
            try migrateGmailDefaultTokenStore(credential)
            guard let selected = try readPersistentTokenFileData(
                credential.tokenStorePath, credential: credential, exitCode: .authenticationBootstrapError
            ) else { return false }
            try removePersistentTokenFile(at: credential.tokenStorePath, expectedState: .identity(selected.identity),
                                          credential: credential, exitCode: .authenticationBootstrapError)
            return true
        }
        return ["credentialId": credential.id, "state": result.state,
                "localTokenDeleted": result.localTokenDeleted,
                "externalCredentialPreserved": result.externalCredentialPreserved]
    }
}
