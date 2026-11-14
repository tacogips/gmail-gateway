import Foundation
import GatewaySDKKit
@testable import GmailGatewayCore
import Testing

struct GmailErrorDiagnosticsTests {
    @Test func onlyBoundedASCIIDecimalsAreForwarded() {
        for invalid in ["", "SECRET", " 403", "+403", "-1", "403.0", "4e2", "４０３", "999999", "403\n"] {
            let error = failure(["httpStatus": invalid, "providerErrorCode": invalid, "token": "SECRET"])
            #expect(error.gatewayDiagnostics.isEmpty)
        }
        #expect(failure(["httpStatus": "99", "providerErrorCode": "100000"]).gatewayDiagnostics.isEmpty)
        #expect(failure(["httpStatus": "600", "providerErrorCode": "-1"]).gatewayDiagnostics.isEmpty)
        #expect(failure(["httpStatus": "100", "providerErrorCode": "0"]).gatewayDiagnostics == .init(httpStatus: 100, providerErrorCode: 0))
        #expect(failure(["httpStatus": "599", "providerErrorCode": "99999"]).gatewayDiagnostics == .init(httpStatus: 599, providerErrorCode: 99_999))
    }

    @Test func canonicalizationDropsArbitraryDetailsAndPreservesNumericExtensions() throws {
        let source = failure(["httpStatus": "401", "providerErrorCode": "17", "token": "SECRET", "body": "SECRET"])
        let error = GatewayEnvelopeError(message: source.message, code: source.code.rawValue, diagnostics: source.gatewayDiagnostics)
        let envelope = GatewayEnvelope(errors: [error], exitCode: 5, rawOutput: "STALE_SECRET")
        for pretty in [false, true] {
            let output = try GmailGatewayGraphQLEnvelopeSerializer.output(envelope, pretty: pretty)
            #expect(!output.contains("SECRET"))
            let parsed = GatewayEnvelope(parsingCLIOutput: output, exitCode: 5)
            #expect(parsed.errors == [error])
            let data = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
            let errors = try #require(data?["errors"] as? [[String: Any]])
            let fields = try #require(errors.first?["extensions"] as? [String: Int])
            #expect(fields == ["httpStatus": 401, "providerErrorCode": 17])
        }
        let empty = GatewayEnvelope(errors: [.init(message: "failed", diagnostics: failure(["body": "SECRET"]).gatewayDiagnostics)])
        #expect(!GmailGatewayGraphQLEnvelopeSerializer.canonicalize(empty).rawOutput.contains("extensions"))
    }

    private func failure(_ details: [String: String]) -> GmailGatewayError {
        GmailGatewayError("provider request failed", code: .providerApiError, exitCode: .providerApiError, details: details)
    }
}
