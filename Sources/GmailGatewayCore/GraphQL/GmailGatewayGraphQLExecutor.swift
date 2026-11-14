import Foundation
import GatewaySDKKit

public struct GmailGatewayGraphQLExecutor: Sendable {
    private let providerAttemptLimit: Int

    public init() {
        providerAttemptLimit = GmailGatewayProviderBudget.maximumRequests
    }

    init(providerAttemptLimit: Int) {
        self.providerAttemptLimit = providerAttemptLimit
    }

    public func run(
        query: String,
        variables: [String: GatewayJSONValue] = [:],
        mode: GmailGatewayCLIMode,
        environment: [String: String],
        configurationPolicy: GmailGatewayConfigurationPolicy = .strictEnvironment
    ) async -> GatewayEnvelope {
        do {
            let runtime = try GatewayGraphQLRuntime(catalog: .gmailFull, authorized: .gmail(mode: mode), resolvers: GmailGatewayResolvers.all)
            let requestId = UUID().uuidString
            var baseUserInfo: [String: GatewayJSONValue] = [
                "sendEnabled": .bool(mode.gatewaySendEnabled),
                "gmailGateway.configurationPolicy": .string(configurationPolicy.rawValue)
            ]
            let preflightContext = GatewayResolverContext(
                environment: environment,
                requestId: requestId,
                userInfo: baseUserInfo
            )

            do {
                let parsed = try GatewayGraphQLParser.parse(query)
                let validated = try GatewayGraphQLValidator(catalog: .gmailFull).validate(parsed, variables: variables)
                let hydrationPlan = GmailGatewaySelectionHydration.plan(for: parsed)
                if GmailGatewayProviderBudget.exceedsLimit(validated, mode: mode, hydrationPlan: hydrationPlan) {
                    return Self.envelope(
                        errors: [.init(
                            message: "RESOURCE_LIMIT: gmail provider request budget exceeds \(GmailGatewayProviderBudget.maximumRequests)",
                            code: "RESOURCE_LIMIT"
                        )],
                        context: preflightContext,
                        exitCode: 2
                    )
                }
                baseUserInfo.merge(GmailGatewaySelectionHydration.userInfo(for: parsed)) { _, new in new }
                return await execute(
                    runtime: runtime,
                    document: query,
                    variables: variables,
                    context: .init(environment: environment, requestId: requestId, userInfo: baseUserInfo)
                )
            } catch is GatewaySDKError {
                return await execute(
                    runtime: runtime,
                    document: query,
                    variables: variables,
                    context: preflightContext
                )
            }
        } catch {
            return GmailGatewayGraphQLEnvelopeSerializer.canonicalize(
                GatewayEnvelope.failure(error, exitCode: 2)
            )
        }
    }

    private static func envelope(
        errors: [GatewayEnvelopeError],
        context: GatewayResolverContext,
        exitCode: Int32
    ) -> GatewayEnvelope {
        GmailGatewayGraphQLEnvelopeSerializer.canonicalize(.init(
            data: nil,
            errors: errors,
            requestId: context.requestId,
            exitCode: exitCode
        ))
    }

    private func execute(
        runtime: GatewayGraphQLRuntime,
        document: String,
        variables: [String: GatewayJSONValue],
        context: GatewayResolverContext
    ) async -> GatewayEnvelope {
        let budget = GmailGatewayProviderAttemptBudget(maximumRequests: providerAttemptLimit)
        let cancellation = GmailGatewayProviderCancellation()
        return await withTaskCancellationHandler(operation: {
            await GmailGatewayProviderCancellationContext.$current.withValue(cancellation) {
                await GmailGatewayProviderAttemptBudgetContext.$current.withValue(budget) {
                    GmailGatewayGraphQLEnvelopeSerializer.canonicalize(
                        await runtime.execute(document: document, variables: variables, context: context)
                    )
                }
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }
}
