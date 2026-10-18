import GatewaySDKKit

extension GmailGatewayError {
    /// Only numeric provider diagnostics cross the GraphQL boundary. Never copy arbitrary details.
    var gatewayDiagnostics: GatewayErrorDiagnostics {
        GatewayErrorDiagnostics(
            httpStatus: boundedDecimal(details["httpStatus"], maximumDigits: 3),
            providerErrorCode: boundedDecimal(details["providerErrorCode"], maximumDigits: 5)
        )
    }
}

private func boundedDecimal(_ text: String?, maximumDigits: Int) -> Int? {
    guard let text, !text.isEmpty, text.utf8.count <= maximumDigits,
          text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
    return Int(text)
}
