import Foundation
import GatewaySDKKit

public struct GmailGatewaySDK: GatewaySDK {
    public let provider = "gmail-gateway"
    public let tier: String
    public let catalog: GatewaySchemaCatalog
    private let mode: GmailGatewayCLIMode

    public init(mode: GmailGatewayCLIMode) {
        self.mode = mode
        self.tier = mode.gatewayTier
        self.catalog = .gmail(mode: mode)
    }

    public func execute(document: String, variables: [String: GatewayJSONValue], environment: [String: String]) async -> GatewayEnvelope {
        await GmailGatewayGraphQLExecutor().run(
            query: document,
            variables: variables,
            mode: mode,
            environment: environment,
            configurationPolicy: .strictEnvironment
        )
    }

    public func invoke(
        _ request: GatewayOperationRequest,
        environment: [String: String]
    ) async -> GatewayEnvelope {
        do {
            let document = try GmailGatewayOperationBoundary.build(request)
            return await execute(
                document: document.document,
                variables: document.variables,
                environment: environment
            )
        } catch let error as GatewaySDKError {
            return GmailGatewayOperationBoundary.errorEnvelope(error)
        } catch {
            return GmailGatewayGraphQLEnvelopeSerializer.canonicalize(.init(
                data: nil,
                errors: [.init(message: String(describing: error), code: GmailGatewayErrorCode.unexpectedError.rawValue)],
                requestId: UUID().uuidString,
                exitCode: GmailGatewayExitCode.generalError.rawValue
            ))
        }
    }
}
