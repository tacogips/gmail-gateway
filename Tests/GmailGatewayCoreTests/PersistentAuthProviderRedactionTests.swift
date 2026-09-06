import Foundation
@testable import GmailGatewayCore
import Testing

struct PersistentAuthProviderRedactionTests {
    @Test func stripsSecretValuesFromProviderMessageStatusAndReason() throws {
        let secrets = ["access-token-value", "refresh-token-value", "client-secret-value"]
        let details = gmailProviderErrorDetails(statusCode: 400, data: Data("""
        {"error":{"code":400,"message":"\(secrets[0])","status":"\(secrets[1])","errors":[{"reason":"\(secrets[2])"}]}}
        """.utf8))
        let output = details.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        for secret in secrets {
            #expect(!output.contains(secret))
        }
    }
}
