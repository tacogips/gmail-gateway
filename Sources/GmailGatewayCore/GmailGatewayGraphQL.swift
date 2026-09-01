import Foundation

func executeReaderGraphQL(
    config: GmailGatewayConfig,
    query: String
) throws -> (body: [String: Any], exitCode: GmailGatewayExitCode) {
    let service = GmailGatewayService(config: config)
    do {
        let scannedQuery = try prepareGraphQLQuery(query)
        return (["data": try executeReaderGraphQLData(service: service, query: scannedQuery)], .success)
    } catch let error as GmailGatewayError where shouldReturnGraphQLError(error) {
        return (graphQLErrorBody(error), .graphqlExecutionError)
    }
}

private let writeMutationRootFields = sendMutationRootFields + draftMutationRootFields

private func executeReaderGraphQLData(service: GmailGatewayService, query: String) throws -> [String: Any] {
    if writeMutationRootFields.contains(where: { rootFieldSource($0, in: query) != nil }) {
        throw GmailGatewayError(
            "Mail write mutations are disabled in gmail-gateway-reader",
            code: .sendDisabledInReader,
            exitCode: .graphqlExecutionError
        )
    }
    if let field = draftQueryRootFields.first(where: { rootFieldSource($0, in: query) != nil }) {
        throw GmailGatewayError(
            "\(field) is not part of the gmail-gateway-reader schema; use gmail-gateway-draft or gmail-gateway-sender",
            code: .sendDisabledInReader,
            exitCode: .graphqlExecutionError
        )
    }
    if rootFieldSource("accounts", in: query) != nil {
        return ["accounts": service.graphQLAccounts()]
    }
    if let source = rootFieldSource("account", in: query) {
        return [
            "account": service.graphQLAccount(id: try extractStringArgument("id", from: source)) as Any? ?? NSNull()
        ]
    }
    if let source = rootFieldSource("threads", in: query) {
        try rejectUnsupportedThreadSearchArguments(in: source)
        try rejectUnsupportedThreadSearchInputFields(in: source)
        let selection = selectionBody(for: "threads", in: source, atBraceDepth: 0) ?? ""
        let edgeSelection = selectionBody(for: "edges", in: selection, atBraceDepth: 0) ?? ""
        let nodeSelection = selectionBody(for: "node", in: edgeSelection, atBraceDepth: 0) ?? ""
        return [
            "threads": projectThreadConnectionSelection(
                try service.searchThreads(
                    accountId: try extractStringArgument("accountId", from: source),
                    query: try extractOptionalStringArgument("query", from: source),
                    starred: try extractOptionalBooleanArgument("starred", from: source) ?? false,
                    direction: try extractOptionalThreadSearchDirectionArgument("direction", from: source),
                    labelIds: try extractOptionalStringArrayArgument("labelIds", from: source),
                    receivedAfter: try extractOptionalStringArgument("receivedAfter", from: source),
                    receivedBefore: try extractOptionalStringArgument("receivedBefore", from: source),
                    first: try extractOptionalIntArgument("first", from: source) ?? 20,
                    after: try extractOptionalStringArgument("after", from: source),
                    includeEdges: directFieldExists("edges", in: selection),
                    includeNodeDetails: directFieldExists("node", in: edgeSelection),
                    includeFullNodeDetails: threadNodeSelectionRequiresFullHydration(nodeSelection)
                ),
                selection: selection
            )
        ]
    }
    if let source = rootFieldSource("thread", in: query) {
        return try graphQLThreadData(service: service, query: source)
    }
    if let source = rootFieldSource("messageFileSet", in: query) {
        return try graphQLMessageFileSetData(service: service, query: source)
    }
    if let source = rootFieldSource("message", in: query) {
        return try graphQLMessageData(service: service, query: source)
    }
    if let source = rootFieldSource("attachment", in: query) {
        return try graphQLAttachmentData(service: service, query: source)
    }
    throw GmailGatewayError(
        "Unsupported GraphQL query",
        code: .invalidArgument,
        exitCode: .graphqlExecutionError
    )
}

private func threadNodeSelectionRequiresFullHydration(_ selection: String) -> Bool {
    directFieldExists("messages", in: selection) ||
        directFieldExists("subject", in: selection) ||
        directFieldExists("labels", in: selection)
}

public func executeWriteGraphQL(
    config: GmailGatewayConfig,
    query: String,
    mode: GmailGatewayWriteMode
) throws -> (body: [String: Any], exitCode: GmailGatewayExitCode) {
    let service = GmailGatewayService(config: config)
    do {
        let scannedQuery = try prepareGraphQLQuery(query)
        try rejectSendMutationsOutsideSender(query: scannedQuery, mode: mode)
        if let data = try executeDraftMutation(config: config, query: scannedQuery) {
            return (["data": data], .success)
        }
        if let source = rootFieldSource("sendMessage", in: scannedQuery) {
            return (
                [
                    "data": [
                        "sendMessage": try GmailGatewayWriteService(config: config).sendMessage(
                            input: try outboundMailInput(from: source),
                            mode: mode
                        )
                    ]
                ],
                .success
            )
        }
        if let source = rootFieldSource("replyMessage", in: scannedQuery) {
            return (
                [
                    "data": [
                        "replyMessage": try GmailGatewayWriteService(config: config).replyMessage(
                            input: try replyMessageInput(from: source),
                            mode: mode
                        )
                    ]
                ],
                .success
            )
        }
        if let source = rootFieldSource("forwardMessage", in: scannedQuery) {
            return (
                [
                    "data": [
                        "forwardMessage": try GmailGatewayWriteService(config: config).forwardMessage(
                            input: try forwardMessageInput(from: source),
                            mode: mode
                        )
                    ]
                ],
                .success
            )
        }
        return (
            ["data": try executeWriteQueryData(service: service, config: config, query: scannedQuery)],
            .success
        )
    } catch let error as GmailGatewayError where shouldReturnGraphQLError(error) {
        return (graphQLErrorBody(error), .graphqlExecutionError)
    }
}

private func shouldReturnGraphQLError(_ error: GmailGatewayError) -> Bool {
    error.exitCode == .graphqlExecutionError || error.exitCode == .providerApiError
}

private func graphQLErrorBody(_ error: GmailGatewayError) -> [String: Any] {
    let extensions: [String: Any] = [
        "code": error.code.rawValue,
        "exitCode": error.exitCode.rawValue,
        "requestId": UUID().uuidString
    ]
    let errors: [[String: Any]] = [[
        "message": error.message,
        "extensions": extensions
    ]]
    return [
        "data": NSNull(),
        "errors": errors
    ]
}

private func executeWriteQueryData(
    service: GmailGatewayService,
    config: GmailGatewayConfig,
    query: String
) throws -> [String: Any] {
    if let data = try executeDraftQuery(config: config, query: query) {
        return data
    }
    if rootFieldSource("accounts", in: query) != nil {
        return ["accounts": service.graphQLAccounts(sendEnabled: true)]
    }
    if let source = rootFieldSource("account", in: query) {
        return [
            "account": service.graphQLAccount(
                id: try extractStringArgument("id", from: source),
                sendEnabled: true
            ) as Any? ?? NSNull()
        ]
    }
    return try executeReaderGraphQLData(service: service, query: query)
}

private func projectThreadConnectionSelection(_ connection: [String: Any], selection: String) -> [String: Any] {
    var object: [String: Any] = [:]
    if directFieldExists("totalCount", in: selection),
       let totalCount = connection["totalCount"] {
        object["totalCount"] = totalCount
    }
    if directFieldExists("pageInfo", in: selection),
       let pageInfo = connection["pageInfo"] {
        object["pageInfo"] = pageInfo
    }
    if directFieldExists("edges", in: selection),
       let edges = connection["edges"] {
        object["edges"] = projectThreadEdgesSelection(
            edges,
            selection: selectionBody(for: "edges", in: selection, atBraceDepth: 0) ?? ""
        )
    }
    return object
}

private func projectThreadEdgesSelection(_ edges: Any, selection: String) -> Any {
    guard let edgeObjects = edges as? [[String: Any]] else {
        return edges
    }
    guard !directFieldExists("node", in: selection) else {
        return edgeObjects
    }
    return edgeObjects.map { edge in
        var projected: [String: Any] = [:]
        if directFieldExists("cursor", in: selection),
           let cursor = edge["cursor"] {
            projected["cursor"] = cursor
        }
        return projected
    }
}

private func graphQLThreadData(service: GmailGatewayService, query: String) throws -> [String: Any] {
    [
        "thread": try service.getThread(
            accountId: try extractStringArgument("accountId", from: query),
            threadId: try extractStringArgument("threadId", from: query)
        )
    ]
}

private func graphQLMessageFileSetData(service: GmailGatewayService, query: String) throws -> [String: Any] {
    [
        "messageFileSet": try service.getMessageFileSet(
            accountId: try extractStringArgument("accountId", from: query),
            messageId: try extractStringArgument("messageId", from: query)
        )
    ]
}

private func graphQLMessageData(service: GmailGatewayService, query: String) throws -> [String: Any] {
    [
        "message": try service.getMessage(
            accountId: try extractStringArgument("accountId", from: query),
            messageId: try extractStringArgument("messageId", from: query)
        )
    ]
}

private func graphQLAttachmentData(service: GmailGatewayService, query: String) throws -> [String: Any] {
    let selection = selectionBody(for: "attachment", in: query, atBraceDepth: 0) ?? ""
    return [
        "attachment": projectAttachmentSelection(
            try service.getAttachment(
                accountId: extractStringArgument("accountId", from: query),
                messageId: extractStringArgument("messageId", from: query),
                attachmentId: extractStringArgument("attachmentId", from: query)
            ),
            selection: selection
        )
    ]
}

private func projectAttachmentSelection(_ attachment: Any, selection: String) -> Any {
    guard var object = attachment as? [String: Any] else {
        return attachment
    }
    object.removeValue(forKey: "localPath")
    for field in object.keys where !directFieldExists(field, in: selection) {
        object.removeValue(forKey: field)
    }
    return object
}
