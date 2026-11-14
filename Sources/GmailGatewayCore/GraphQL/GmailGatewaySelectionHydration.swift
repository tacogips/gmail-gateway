import GatewaySDKKit

enum GmailGatewaySelectionHydration {
    private static let threadsEdgesKey = "gmailGateway.threads.includeEdges"
    private static let threadsNodeDetailsKey = "gmailGateway.threads.includeNodeDetails"
    private static let threadsFullNodeDetailsKey = "gmailGateway.threads.includeFullNodeDetails"
    private static let draftsEdgesKey = "gmailGateway.drafts.includeEdges"
    private static let draftsNodeDetailsKey = "gmailGateway.drafts.includeNodeDetails"

    static func userInfo(for document: String) -> [String: GatewayJSONValue] {
        guard let parsed = try? GatewayGraphQLParser.parse(document) else {
            return [:]
        }
        return userInfo(for: parsed)
    }

    static func userInfo(for document: GatewayGraphQLDocument) -> [String: GatewayJSONValue] {
        let plan = plan(for: document)
        let threads = plan.threads
        let drafts = plan.drafts
        return [
            threadsEdgesKey: .bool(threads.includeEdges),
            threadsNodeDetailsKey: .bool(threads.includeNodeDetails),
            threadsFullNodeDetailsKey: .bool(threads.includeFullNodeDetails),
            draftsEdgesKey: .bool(drafts.includeEdges),
            draftsNodeDetailsKey: .bool(drafts.includeNodeDetails)
        ]
    }

    static func plan(for document: GatewayGraphQLDocument) -> GmailGatewayHydrationPlan {
        .init(
            threads: threadHydration(from: document.selectionSet),
            drafts: draftHydration(from: document.selectionSet)
        )
    }

    static func threads(in context: GatewayResolverContext) -> ThreadHydration {
        guard let includeEdges = bool(threadsEdgesKey, in: context),
              let includeNodeDetails = bool(threadsNodeDetailsKey, in: context),
              let includeFullNodeDetails = bool(threadsFullNodeDetailsKey, in: context) else {
            return .full
        }
        return .init(
            includeEdges: includeEdges,
            includeNodeDetails: includeNodeDetails,
            includeFullNodeDetails: includeFullNodeDetails
        )
    }

    static func drafts(in context: GatewayResolverContext) -> DraftHydration {
        guard let includeEdges = bool(draftsEdgesKey, in: context),
              let includeNodeDetails = bool(draftsNodeDetailsKey, in: context) else {
            return .full
        }
        return .init(includeEdges: includeEdges, includeNodeDetails: includeNodeDetails)
    }

    static func threads(selectionSet: [GatewayGraphQLDocument.Selection]) -> ThreadHydration {
        let edgeSelections = selectionSet.filter { $0.name == "edges" }
        let nodeSelections = nestedSelections(named: "node", in: edgeSelections)
        return .init(
            includeEdges: !edgeSelections.isEmpty,
            includeNodeDetails: !nodeSelections.isEmpty,
            includeFullNodeDetails: nodeSelections.contains(where: requiresFullThreadHydration)
        )
    }

    static func drafts(selectionSet: [GatewayGraphQLDocument.Selection]) -> DraftHydration {
        let edgeSelections = selectionSet.filter { $0.name == "edges" }
        return .init(
            includeEdges: !edgeSelections.isEmpty,
            includeNodeDetails: !nestedSelections(named: "node", in: edgeSelections).isEmpty
        )
    }

    private static func threadHydration(from roots: [GatewayGraphQLDocument.Selection]) -> ThreadHydration {
        threads(selectionSet: roots.filter { $0.name == "threads" }.flatMap(\.selectionSet))
    }

    private static func draftHydration(from roots: [GatewayGraphQLDocument.Selection]) -> DraftHydration {
        drafts(selectionSet: roots.filter { $0.name == "drafts" }.flatMap(\.selectionSet))
    }

    private static func nestedSelections(
        named name: String,
        in selections: [GatewayGraphQLDocument.Selection]
    ) -> [GatewayGraphQLDocument.Selection] {
        selections.flatMap { selection in selection.selectionSet.filter { $0.name == name } }
    }

    private static func requiresFullThreadHydration(_ selection: GatewayGraphQLDocument.Selection) -> Bool {
        selection.selectionSet.contains { field in
            ["messages", "subject", "labels"].contains(field.name) ||
                requiresFullThreadMetadataHydration(field)
        }
    }

    private static func requiresFullThreadMetadataHydration(
        _ selection: GatewayGraphQLDocument.Selection
    ) -> Bool {
        guard selection.name == "providerMetadata" else {
            return false
        }
        let gmailSelections = nestedSelections(named: "gmail", in: [selection])
        return gmailSelections.contains { gmail in
            gmail.selectionSet.contains { $0.name == "labelIds" }
        }
    }

    private static func bool(_ key: String, in context: GatewayResolverContext) -> Bool? {
        guard case .bool(let value) = context.userInfo[key] else {
            return nil
        }
        return value
    }
}

struct GmailGatewayHydrationPlan: Sendable {
    let threads: ThreadHydration
    let drafts: DraftHydration
}

struct ThreadHydration: Sendable {
    static let full = Self(includeEdges: true, includeNodeDetails: true, includeFullNodeDetails: true)

    let includeEdges: Bool
    let includeNodeDetails: Bool
    let includeFullNodeDetails: Bool
}

struct DraftHydration: Sendable {
    static let full = Self(includeEdges: true, includeNodeDetails: true)

    let includeEdges: Bool
    let includeNodeDetails: Bool
}
