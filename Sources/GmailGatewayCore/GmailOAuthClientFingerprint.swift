import CryptoKit
import Foundation

func gmailOAuthClientFingerprint(_ client: GmailOAuthClientRecord) throws -> String {
    let object: [String: Any] = [
        "authorizationEndpoint": client.authorizationEndpoint,
        "clientId": client.clientId,
        "kind": client.kind,
        "projectId": client.projectId as Any,
        "redirectURIs": client.redirectURIs.sorted(),
        "tokenEndpoint": client.tokenEndpoint
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
