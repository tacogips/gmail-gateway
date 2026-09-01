import Foundation

let draftMutationRootFields = ["createDraft", "updateDraft", "deleteDraft"]
let sendMutationRootFields = ["sendMessage", "replyMessage", "forwardMessage"]
let draftQueryRootFields = ["drafts", "draft"]

private let supportedUpdateDraftFields: Set<String> = [
    "accountId",
    "draftId",
    "to",
    "cc",
    "bcc",
    "replyTo",
    "subject",
    "textBody",
    "htmlBody",
    "attachmentPaths",
    "keepAttachmentIds"
]

func executeDraftMutation(
    config: GmailGatewayConfig,
    query: String
) throws -> [String: Any]? {
    if let source = rootFieldSource("createDraft", in: query) {
        return [
            "createDraft": try GmailGatewayWriteService(config: config).sendMessage(
                input: try outboundMailInput(from: source),
                mode: .draftDefault
            )
        ]
    }
    if let source = rootFieldSource("updateDraft", in: query) {
        try rejectUnsupportedUpdateDraftFields(in: source)
        return [
            "updateDraft": try GmailGatewayWriteService(config: config).updateDraft(
                input: try updateDraftInput(from: source)
            )
        ]
    }
    if let source = rootFieldSource("deleteDraft", in: query) {
        return [
            "deleteDraft": try GmailGatewayWriteService(config: config).deleteDraft(
                accountId: try extractStringArgument("accountId", from: source),
                draftId: try extractStringArgument("draftId", from: source)
            )
        ]
    }
    return nil
}

func executeDraftQuery(
    config: GmailGatewayConfig,
    query: String
) throws -> [String: Any]? {
    if let source = rootFieldSource("drafts", in: query) {
        let selection = selectionBody(for: "drafts", in: source, atBraceDepth: 0) ?? ""
        let edgeSelection = selectionBody(for: "edges", in: selection, atBraceDepth: 0) ?? ""
        return [
            "drafts": try GmailGatewayWriteService(config: config).listDrafts(
                accountId: try extractStringArgument("accountId", from: source),
                first: try extractOptionalIntArgument("first", from: source) ?? 20,
                after: try extractOptionalStringArgument("after", from: source),
                includeEdges: directFieldExists("edges", in: selection),
                includeNodeDetails: directFieldExists("node", in: edgeSelection)
            )
        ]
    }
    if let source = rootFieldSource("draft", in: query) {
        return [
            "draft": try GmailGatewayWriteService(config: config).getDraft(
                accountId: try extractStringArgument("accountId", from: source),
                draftId: try extractStringArgument("draftId", from: source)
            )
        ]
    }
    return nil
}

func rejectSendMutationsOutsideSender(query: String, mode: GmailGatewayWriteMode) throws {
    guard mode != .directSend else {
        return
    }
    guard let field = sendMutationRootFields.first(where: { rootFieldSource($0, in: query) != nil }) else {
        return
    }
    throw GmailGatewayError(
        "\(field) is disabled in gmail-gateway-draft; use gmail-gateway-sender to send mail",
        code: .sendDisabledInDraftGateway,
        exitCode: .graphqlExecutionError
    )
}

private func updateDraftInput(from query: String) throws -> UpdateDraftInput {
    UpdateDraftInput(
        accountId: try extractStringArgument("accountId", from: query),
        draftId: try extractStringArgument("draftId", from: query),
        to: try extractOptionalStringArrayArgument("to", from: query),
        cc: try extractOptionalStringArrayArgument("cc", from: query),
        bcc: try extractOptionalStringArrayArgument("bcc", from: query),
        replyTo: try extractOptionalStringArgument("replyTo", from: query),
        subject: try extractOptionalStringArgument("subject", from: query),
        textBody: try extractOptionalStringArgument("textBody", from: query),
        htmlBody: try extractOptionalStringArgument("htmlBody", from: query),
        attachmentPaths: try extractOptionalStringArrayArgument("attachmentPaths", from: query) ?? [],
        keepAttachmentIds: try extractOptionalStringArrayArgument("keepAttachmentIds", from: query)
    )
}

private func rejectUnsupportedUpdateDraftFields(in query: String) throws {
    guard let argumentBody = extractFieldArgumentListBody(from: query) else {
        return
    }
    let supportedArguments = supportedUpdateDraftFields.union(["input"])
    let unsupportedArguments = objectFieldLabels(in: argumentBody).filter { !supportedArguments.contains($0) }
    guard unsupportedArguments.isEmpty else {
        throw GmailGatewayError(
            "Unsupported updateDraft argument(s): \(unsupportedArguments.joined(separator: ", "))",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    guard let inputBody = try extractObjectArgumentBody("input", from: query) else {
        return
    }
    let unsupportedFields = objectFieldLabels(in: inputBody).filter { !supportedUpdateDraftFields.contains($0) }
    guard unsupportedFields.isEmpty else {
        throw GmailGatewayError(
            "Unsupported UpdateDraftInput field(s): \(unsupportedFields.joined(separator: ", "))",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
}
