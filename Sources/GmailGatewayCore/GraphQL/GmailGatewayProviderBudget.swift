import GatewaySDKKit

enum GmailGatewayProviderBudget {
    static let maximumRequests = 1_000

    static func exceedsLimit(
        _ operation: ValidatedOperation,
        mode: GmailGatewayCLIMode,
        hydrationPlan: GmailGatewayHydrationPlan
    ) -> Bool {
        guard operation.rootFields.allSatisfy({ isAuthorized($0, in: mode) }) else {
            return false
        }
        return operation.rootFields.reduce(0) {
            $0 + requestCost(of: $1, hydrationPlan: hydrationPlan)
        } > maximumRequests
    }

    private static func isAuthorized(_ root: ValidatedOperation.RootField, in mode: GmailGatewayCLIMode) -> Bool {
        GatewaySchemaCatalog.gmail(mode: mode).operations.contains {
            $0.name == root.name && $0.kind == root.operation.kind
        }
    }

    private static func requestCost(
        of root: ValidatedOperation.RootField,
        hydrationPlan: GmailGatewayHydrationPlan
    ) -> Int {
        switch root.name {
        case "threads":
            return 1 + (hydrationPlan.threads.includeFullNodeDetails ? pageSize(for: root, input: true) : 0)
        case "drafts":
            return 1 + (hydrationPlan.drafts.includeNodeDetails ? pageSize(for: root, input: false) : 0)
        case "createReplyDraft", "replyMessage", "updateDraft":
            return 2
        case "createForwardDraft", "forwardMessage":
            return 3
        default:
            return 1
        }
    }

    private static func pageSize(for root: ValidatedOperation.RootField, input: Bool) -> Int {
        let arguments: [String: GatewayJSONValue]
        if input, case .object(let value) = root.arguments["input"] {
            arguments = value
        } else {
            arguments = root.arguments
        }
        guard case .int(let first) = arguments["first"], (1 ... 500).contains(first) else {
            return 20
        }
        return first
    }
}
