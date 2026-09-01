import Foundation

let mailboxMutationRootFields = [
    "modifyThreadLabels",
    "modifyMessageLabels",
    "batchModifyMessageLabels",
    "trashThread",
    "untrashThread",
    "trashMessage",
    "untrashMessage",
    "deleteThread",
    "deleteMessage",
    "batchDeleteMessages",
    "createLabel",
    "updateLabel",
    "deleteLabel"
]

let ingestMutationRootFields = ["importMessage", "insertMessage"]

private let supportedIngestFields: Set<String> = [
    "accountId",
    "rfc822Path",
    "labelIds",
    "internalDateSource",
    "neverMarkSpam",
    "processForCalendar",
    "deleted"
]

func executeMailboxMutation(
    config: GmailGatewayConfig,
    query: String
) throws -> [String: Any]? {
    let service = GmailGatewayWriteService(config: config)
    if let source = rootFieldSource("modifyThreadLabels", in: query) {
        return ["modifyThreadLabels": try service.modifyThreadLabels(
            accountId: try extractStringArgument("accountId", from: source),
            threadId: try extractStringArgument("threadId", from: source),
            addLabelIds: try extractOptionalStringArrayArgument("addLabelIds", from: source) ?? [],
            removeLabelIds: try extractOptionalStringArrayArgument("removeLabelIds", from: source) ?? []
        )]
    }
    if let source = rootFieldSource("modifyMessageLabels", in: query) {
        return ["modifyMessageLabels": try service.modifyMessageLabels(
            accountId: try extractStringArgument("accountId", from: source),
            messageId: try extractStringArgument("messageId", from: source),
            addLabelIds: try extractOptionalStringArrayArgument("addLabelIds", from: source) ?? [],
            removeLabelIds: try extractOptionalStringArrayArgument("removeLabelIds", from: source) ?? []
        )]
    }
    if let source = rootFieldSource("batchModifyMessageLabels", in: query) {
        return ["batchModifyMessageLabels": try service.batchModifyMessageLabels(
            accountId: try extractStringArgument("accountId", from: source),
            messageIds: try extractOptionalStringArrayArgument("messageIds", from: source) ?? [],
            addLabelIds: try extractOptionalStringArrayArgument("addLabelIds", from: source) ?? [],
            removeLabelIds: try extractOptionalStringArrayArgument("removeLabelIds", from: source) ?? []
        )]
    }
    if let data = try executeTrashMutation(service: service, query: query) {
        return data
    }
    if let data = try executeDeleteMutation(service: service, query: query) {
        return data
    }
    return try executeLabelMutation(service: service, query: query)
}

func executeIngestMutation(
    config: GmailGatewayConfig,
    query: String
) throws -> [String: Any]? {
    let service = GmailGatewayWriteService(config: config)
    if let source = rootFieldSource("importMessage", in: query) {
        try rejectUnsupportedIngestFields(in: source, mutation: "importMessage")
        return ["importMessage": try service.importMessage(input: try ingestInput(from: source))]
    }
    if let source = rootFieldSource("insertMessage", in: query) {
        try rejectUnsupportedIngestFields(in: source, mutation: "insertMessage")
        return ["insertMessage": try service.insertMessage(input: try ingestInput(from: source))]
    }
    return nil
}

/// Rejects mailbox mutations in the binaries that do not own them, naming the one that does.
func rejectMailboxMutations(query: String, executableName: String) throws {
    guard let field = mailboxMutationRootFields.first(where: { rootFieldSource($0, in: query) != nil }) else {
        return
    }
    throw GmailGatewayError(
        "\(field) is not available in \(executableName); use gmail-gateway-threads for mailbox mutations",
        code: .mailboxMutationNotSupported,
        exitCode: .graphqlExecutionError
    )
}

/// Rejects mail ingestion in the binaries that do not own it, naming the one that does.
func rejectIngestMutations(query: String, executableName: String) throws {
    guard let field = ingestMutationRootFields.first(where: { rootFieldSource($0, in: query) != nil }) else {
        return
    }
    throw GmailGatewayError(
        "\(field) is not available in \(executableName); use gmail-gateway-message-box to ingest mail",
        code: .mailIngestNotSupported,
        exitCode: .graphqlExecutionError
    )
}

private func executeTrashMutation(
    service: GmailGatewayWriteService,
    query: String
) throws -> [String: Any]? {
    let threadTrashFields: [(field: String, trashed: Bool)] = [
        ("trashThread", true),
        ("untrashThread", false)
    ]
    for entry in threadTrashFields {
        guard let source = rootFieldSource(entry.field, in: query) else {
            continue
        }
        return [entry.field: try service.setThreadTrashed(
            accountId: try extractStringArgument("accountId", from: source),
            threadId: try extractStringArgument("threadId", from: source),
            trashed: entry.trashed
        )]
    }
    let messageTrashFields: [(field: String, trashed: Bool)] = [
        ("trashMessage", true),
        ("untrashMessage", false)
    ]
    for entry in messageTrashFields {
        guard let source = rootFieldSource(entry.field, in: query) else {
            continue
        }
        return [entry.field: try service.setMessageTrashed(
            accountId: try extractStringArgument("accountId", from: source),
            messageId: try extractStringArgument("messageId", from: source),
            trashed: entry.trashed
        )]
    }
    return nil
}

private func executeDeleteMutation(
    service: GmailGatewayWriteService,
    query: String
) throws -> [String: Any]? {
    if let source = rootFieldSource("deleteThread", in: query) {
        return ["deleteThread": try service.deleteThread(
            accountId: try extractStringArgument("accountId", from: source),
            threadId: try extractStringArgument("threadId", from: source)
        )]
    }
    if let source = rootFieldSource("deleteMessage", in: query) {
        return ["deleteMessage": try service.deleteMessage(
            accountId: try extractStringArgument("accountId", from: source),
            messageId: try extractStringArgument("messageId", from: source)
        )]
    }
    if let source = rootFieldSource("batchDeleteMessages", in: query) {
        return ["batchDeleteMessages": try service.batchDeleteMessages(
            accountId: try extractStringArgument("accountId", from: source),
            messageIds: try extractOptionalStringArrayArgument("messageIds", from: source) ?? []
        )]
    }
    return nil
}

private func executeLabelMutation(
    service: GmailGatewayWriteService,
    query: String
) throws -> [String: Any]? {
    if let source = rootFieldSource("createLabel", in: query) {
        return ["createLabel": try service.createLabel(
            accountId: try extractStringArgument("accountId", from: source),
            input: try labelWriteInput(from: source)
        )]
    }
    if let source = rootFieldSource("updateLabel", in: query) {
        return ["updateLabel": try service.updateLabel(
            accountId: try extractStringArgument("accountId", from: source),
            labelId: try extractStringArgument("labelId", from: source),
            input: try labelWriteInput(from: source)
        )]
    }
    if let source = rootFieldSource("deleteLabel", in: query) {
        return ["deleteLabel": try service.deleteLabel(
            accountId: try extractStringArgument("accountId", from: source),
            labelId: try extractStringArgument("labelId", from: source)
        )]
    }
    return nil
}

private func labelWriteInput(from query: String) throws -> LabelWriteInput {
    LabelWriteInput(
        name: try extractOptionalStringArgument("name", from: query),
        messageListVisibility: try extractOptionalStringOrEnumArgument("messageListVisibility", from: query),
        labelListVisibility: try extractOptionalStringOrEnumArgument("labelListVisibility", from: query)
    )
}

private func ingestInput(from query: String) throws -> MailboxIngestInput {
    MailboxIngestInput(
        accountId: try extractStringArgument("accountId", from: query),
        rfc822Path: try extractStringArgument("rfc822Path", from: query),
        labelIds: try extractOptionalStringArrayArgument("labelIds", from: query) ?? [],
        internalDateSource: try extractOptionalStringOrEnumArgument("internalDateSource", from: query),
        neverMarkSpam: try extractOptionalBooleanArgument("neverMarkSpam", from: query),
        processForCalendar: try extractOptionalBooleanArgument("processForCalendar", from: query),
        deleted: try extractOptionalBooleanArgument("deleted", from: query)
    )
}

private func rejectUnsupportedIngestFields(in query: String, mutation: String) throws {
    guard let argumentBody = extractFieldArgumentListBody(from: query) else {
        return
    }
    let supportedArguments = supportedIngestFields.union(["input"])
    let unsupportedArguments = objectFieldLabels(in: argumentBody).filter { !supportedArguments.contains($0) }
    guard unsupportedArguments.isEmpty else {
        throw GmailGatewayError(
            "Unsupported \(mutation) argument(s): \(unsupportedArguments.joined(separator: ", "))",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    guard let inputBody = try extractObjectArgumentBody("input", from: query) else {
        return
    }
    let unsupportedFields = objectFieldLabels(in: inputBody).filter { !supportedIngestFields.contains($0) }
    guard unsupportedFields.isEmpty else {
        throw GmailGatewayError(
            "Unsupported \(mutation) input field(s): \(unsupportedFields.joined(separator: ", "))",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
}
