import Foundation
import GatewaySDKKit

enum GmailGatewayOperationBoundary {
    static func build(_ request: GatewayOperationRequest) throws -> GatewayBuiltDocument {
        try GatewayDocumentBuilder(catalog: .gmailFull).build(request)
    }

    static func errorEnvelope(_ error: GatewaySDKError) -> GatewayEnvelope {
        GmailGatewayGraphQLEnvelopeSerializer.canonicalize(.init(
            data: nil,
            errors: [.init(message: error.description, code: errorCode(error))],
            requestId: UUID().uuidString,
            exitCode: GmailGatewayExitCode.invalidCliUsage.rawValue
        ))
    }

    private static func errorCode(_ error: GatewaySDKError) -> String {
        switch error {
        case .unknownOperation:
            return "UNKNOWN_OPERATION"
        case .unknownVariable:
            return "UNKNOWN_VARIABLE"
        case .missingRequiredVariable:
            return "MISSING_VARIABLE"
        case .invalidSelectionPath, .emptySelection:
            return "INVALID_SELECTION"
        case .commandOperationNeedsArgv, .graphQLOperationNeedsDocument:
            return "INVALID_OPERATION"
        case .invalidPattern:
            return "INVALID_PATTERN"
        case .variableTypeMismatch:
            return "VARIABLE_TYPE"
        case .unusedVariable:
            return "UNUSED_VARIABLE"
        case .undeclaredVariable:
            return "UNDECLARED_VARIABLE"
        case .malformedDocument, .invalidTypeReference, .invalidJSON, .invalidJSONValue:
            return "INVALID_ARGUMENT"
        case .syntax:
            return "SYNTAX"
        case .validation(let code, _, _):
            return code
        }
    }
}
