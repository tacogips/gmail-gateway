import Foundation
import GatewaySDKKit

// swiftlint:disable line_length

struct GmailRuntimeResolverError: GatewayResolverError {
    let code: String
    let message: String
}

enum GmailGatewayResolvers {
    private static let raw: [String: GatewayGraphQLRuntime.Resolver] = [
        "accounts": { _, context in
            try value(
                GmailGatewayService(config: try config(context)).graphQLAccounts(
                    sendEnabled: sendEnabled(context)
                )
            )
        },
        "account": { args, context in
            try value(
                GmailGatewayService(config: try config(context)).graphQLAccount(
                    id: string(args, "id"),
                    sendEnabled: sendEnabled(context)
                ) ?? NSNull()
            )
        },
        "threads": { args, context in
            let input = object(args, "input")
            let service = GmailGatewayService(config: try config(context))
            let hydration = GmailGatewaySelectionHydration.threads(in: context)
            return try value(service.searchThreads(accountId: string(input, "accountId"), query: optionalString(input, "query"), starred: bool(input, "starred"), direction: direction(input, "direction"), labelIds: strings(input, "labelIds"), receivedAfter: optionalString(input, "receivedAfter"), receivedBefore: optionalString(input, "receivedBefore"), first: optionalInt(input, "first") ?? 20, after: optionalString(input, "after"), includeEdges: hydration.includeEdges, includeNodeDetails: hydration.includeNodeDetails, includeFullNodeDetails: hydration.includeFullNodeDetails))
        },
        "thread": { args, context in try value(GmailGatewayService(config: try config(context)).getThread(accountId: string(args, "accountId"), threadId: string(args, "threadId"))) },
        "message": { args, context in try value(GmailGatewayService(config: try config(context)).getMessage(accountId: string(args, "accountId"), messageId: string(args, "messageId"))) },
        "messageFileSet": { args, context in try value(GmailGatewayService(config: try config(context)).getMessageFileSet(accountId: string(args, "accountId"), messageId: string(args, "messageId"))) },
        "attachment": { args, context in try value(GmailGatewayService(config: try config(context)).getAttachment(accountId: string(args, "accountId"), messageId: string(args, "messageId"), attachmentId: string(args, "attachmentId"))) },
        "labels": { args, context in try value(GmailGatewayService(config: try config(context)).listLabels(accountId: string(args, "accountId"))) },
        "profile": { args, context in try value(GmailGatewayService(config: try config(context)).getProfile(accountId: string(args, "accountId"))) },
        "drafts": { args, context in
            let hydration = GmailGatewaySelectionHydration.drafts(in: context)
            return try value(GmailGatewayWriteService(config: try config(context)).listDrafts(accountId: string(args, "accountId"), first: optionalInt(args, "first") ?? 20, after: optionalString(args, "after"), includeEdges: hydration.includeEdges, includeNodeDetails: hydration.includeNodeDetails))
        },
        "draft": { args, context in try value(GmailGatewayWriteService(config: try config(context)).getDraft(accountId: string(args, "accountId"), draftId: string(args, "draftId"))) },
        "createDraft": { args, context in try value(GmailGatewayWriteService(config: try config(context)).sendMessage(input: outbound(object(args, "input")), mode: .draftDefault)) },
        "createReplyDraft": { args, context in try value(GmailGatewayWriteService(config: try config(context)).createReplyDraft(input: reply(object(args, "input")))) },
        "createForwardDraft": { args, context in try value(GmailGatewayWriteService(config: try config(context)).createForwardDraft(input: forward(object(args, "input")))) },
        "updateDraft": { args, context in try value(GmailGatewayWriteService(config: try config(context)).updateDraft(input: update(object(args, "input")))) },
        "deleteDraft": { args, context in let input = object(args, "input"); return try value(GmailGatewayWriteService(config: try config(context)).deleteDraft(accountId: string(input, "accountId"), draftId: string(input, "draftId"))) },
        "sendMessage": { args, context in try value(GmailGatewayWriteService(config: try config(context)).sendMessage(input: outbound(object(args, "input")), mode: .directSend)) },
        "replyMessage": { args, context in try value(GmailGatewayWriteService(config: try config(context)).replyMessage(input: reply(object(args, "input")), mode: .directSend)) },
        "forwardMessage": { args, context in try value(GmailGatewayWriteService(config: try config(context)).forwardMessage(input: forward(object(args, "input")), mode: .directSend)) },
        "sendDraft": { args, context in let input = object(args, "input"); return try value(GmailGatewayWriteService(config: try config(context)).sendDraft(accountId: string(input, "accountId"), draftId: string(input, "draftId"))) },
        "modifyThreadLabels": { args, context in let input = object(args, "input"); return try value(GmailGatewayWriteService(config: try config(context)).modifyThreadLabels(accountId: string(input, "accountId"), threadId: string(input, "threadId"), addLabelIds: strings(input, "addLabelIds") ?? [], removeLabelIds: strings(input, "removeLabelIds") ?? [])) },
        "modifyMessageLabels": { args, context in let input = object(args, "input"); return try value(GmailGatewayWriteService(config: try config(context)).modifyMessageLabels(accountId: string(input, "accountId"), messageId: string(input, "messageId"), addLabelIds: strings(input, "addLabelIds") ?? [], removeLabelIds: strings(input, "removeLabelIds") ?? [])) },
        "batchModifyMessageLabels": { args, context in let input = object(args, "input"); return try value(GmailGatewayWriteService(config: try config(context)).batchModifyMessageLabels(accountId: string(input, "accountId"), messageIds: strings(input, "messageIds") ?? [], addLabelIds: strings(input, "addLabelIds") ?? [], removeLabelIds: strings(input, "removeLabelIds") ?? [])) },
        "trashThread": { args, context in try trashThread(args, context, true) },
        "untrashThread": { args, context in try trashThread(args, context, false) },
        "trashMessage": { args, context in try trashMessage(args, context, true) },
        "untrashMessage": { args, context in try trashMessage(args, context, false) },
        "deleteThread": { args, context in let input = object(args, "input"); return try value(GmailGatewayWriteService(config: try config(context)).deleteThread(accountId: string(input, "accountId"), threadId: string(input, "threadId"))) },
        "deleteMessage": { args, context in let input = object(args, "input"); return try value(GmailGatewayWriteService(config: try config(context)).deleteMessage(accountId: string(input, "accountId"), messageId: string(input, "messageId"))) },
        "batchDeleteMessages": { args, context in let input = object(args, "input"); return try value(GmailGatewayWriteService(config: try config(context)).batchDeleteMessages(accountId: string(input, "accountId"), messageIds: strings(input, "messageIds") ?? [])) },
        "createLabel": { args, context in
            let input = object(args, "input")
            return try value(
                GmailGatewayWriteService(config: try config(context)).createLabel(
                    accountId: string(input, "accountId"),
                    input: label(input)
                )
            )
        },
        "updateLabel": { args, context in
            let input = object(args, "input")
            return try value(
                GmailGatewayWriteService(config: try config(context)).updateLabel(
                    accountId: string(input, "accountId"),
                    labelId: string(input, "labelId"),
                    input: label(input)
                )
            )
        },
        "deleteLabel": { args, context in let input = object(args, "input"); return try value(GmailGatewayWriteService(config: try config(context)).deleteLabel(accountId: string(input, "accountId"), labelId: string(input, "labelId"))) },
        "importMessage": { args, context in try value(GmailGatewayWriteService(config: try config(context)).importMessage(input: ingest(object(args, "input")))) },
        "insertMessage": { args, context in try value(GmailGatewayWriteService(config: try config(context)).insertMessage(input: ingest(object(args, "input")))) }
    ]

    static let all: [String: GatewayGraphQLRuntime.Resolver] = raw.mapValues { resolver in
        { arguments, context in
            do {
                return try await resolver(arguments, context)
            } catch {
                throw resolverError(error)
            }
        }
    }
}

private func config(_ context: GatewayResolverContext) throws -> GmailGatewayConfig {
    let policy: GmailGatewayConfigurationPolicy
    if case .string(let rawValue) = context.userInfo["gmailGateway.configurationPolicy"],
       let configured = GmailGatewayConfigurationPolicy(rawValue: rawValue) {
        policy = configured
    } else {
        policy = .strictEnvironment
    }
    return try GmailGatewayConfigLoader.loadConfig(
        configPath: context.environment["GMAIL_GATEWAY_CONFIG"],
        environment: context.environment,
        policy: policy
    )
}

private func sendEnabled(_ context: GatewayResolverContext) -> Bool {
    guard case .bool(let enabled) = context.userInfo["sendEnabled"] else {
        return false
    }
    return enabled
}

private func value(_ any: Any) throws -> GatewayJSONValue { try normalize(GatewayJSONValue(any: any)) }
private func normalize(_ value: GatewayJSONValue) -> GatewayJSONValue {
    switch value {
    case .array(let values): return .array(values.map(normalize))
    case .object(let values):
        var normalized = values.filter { $0.key != "localPath" }.mapValues(normalize)
        if let raw = normalized["raw"], normalized["address"] == nil, case .string(let text) = raw {
            normalized["address"] = .string(text)
        }
        return .object(normalized)
    default: return value
    }
}
private func resolverError(_ error: Error) -> GmailRuntimeResolverError {
    if let gmail = error as? GmailGatewayError { return .init(code: gmail.code.rawValue, message: gmail.message) }
    return .init(code: "RESOLVER_ERROR", message: "resolver failed")
}
private func object(_ arguments: [String: GatewayJSONValue], _ name: String) -> [String: GatewayJSONValue] { if case .object(let value) = arguments[name] { return value }; return [:] }
private func string(_ arguments: [String: GatewayJSONValue], _ name: String) -> String { if case .string(let value) = arguments[name] { return value }; return "" }
private func optionalString(_ arguments: [String: GatewayJSONValue], _ name: String) -> String? { if case .string(let value) = arguments[name] { return value }; return nil }
private func strings(_ arguments: [String: GatewayJSONValue], _ name: String) -> [String]? { if case .array(let values) = arguments[name] { return values.compactMap { if case .string(let value) = $0 { return value }; return nil } }; return nil }
private func optionalInt(_ arguments: [String: GatewayJSONValue], _ name: String) -> Int? { if case .int(let value) = arguments[name] { return value }; return nil }
private func bool(_ arguments: [String: GatewayJSONValue], _ name: String) -> Bool { if case .bool(let value) = arguments[name] { return value }; return false }
private func direction(
    _ arguments: [String: GatewayJSONValue],
    _ name: String
) -> ThreadSearchDirection? {
    switch optionalString(arguments, name)?.uppercased() {
    case "SENT": .sent
    case "RECEIVED": .received
    case "ALL": .all
    default: nil
    }
}

private func outbound(_ input: [String: GatewayJSONValue]) -> OutboundMailInput { .init(accountId: string(input, "accountId"), to: strings(input, "to") ?? [], cc: strings(input, "cc") ?? [], bcc: strings(input, "bcc") ?? [], replyTo: optionalString(input, "replyTo"), subject: optionalString(input, "subject"), textBody: optionalString(input, "textBody"), htmlBody: optionalString(input, "htmlBody"), attachmentPaths: strings(input, "attachmentPaths") ?? []) }
private func reply(_ input: [String: GatewayJSONValue]) -> ReplyMessageInput { .init(accountId: string(input, "accountId"), messageId: string(input, "messageId"), to: strings(input, "to") ?? [], cc: strings(input, "cc") ?? [], bcc: strings(input, "bcc") ?? [], replyAll: bool(input, "replyAll"), textBody: optionalString(input, "textBody"), htmlBody: optionalString(input, "htmlBody"), attachmentPaths: strings(input, "attachmentPaths") ?? []) }
private func forward(_ input: [String: GatewayJSONValue]) -> ForwardMessageInput { .init(accountId: string(input, "accountId"), messageId: string(input, "messageId"), to: strings(input, "to") ?? [], cc: strings(input, "cc") ?? [], bcc: strings(input, "bcc") ?? [], textBody: optionalString(input, "textBody"), htmlBody: optionalString(input, "htmlBody"), includeAttachments: argumentsBool(input, "includeAttachments", true), attachmentPaths: strings(input, "attachmentPaths") ?? []) }
private func update(_ input: [String: GatewayJSONValue]) -> UpdateDraftInput { .init(accountId: string(input, "accountId"), draftId: string(input, "draftId"), to: strings(input, "to"), cc: strings(input, "cc"), bcc: strings(input, "bcc"), replyTo: optionalString(input, "replyTo"), subject: optionalString(input, "subject"), textBody: optionalString(input, "textBody"), htmlBody: optionalString(input, "htmlBody"), attachmentPaths: strings(input, "attachmentPaths") ?? [], keepAttachmentIds: strings(input, "keepAttachmentIds")) }
private func label(_ input: [String: GatewayJSONValue]) -> LabelWriteInput { .init(name: optionalString(input, "name"), messageListVisibility: optionalString(input, "messageListVisibility"), labelListVisibility: optionalString(input, "labelListVisibility")) }
private func ingest(_ input: [String: GatewayJSONValue]) -> MailboxIngestInput { .init(accountId: string(input, "accountId"), rfc822Path: string(input, "rfc822Path"), labelIds: strings(input, "labelIds") ?? [], internalDateSource: optionalString(input, "internalDateSource"), neverMarkSpam: optionalBool(input, "neverMarkSpam"), processForCalendar: optionalBool(input, "processForCalendar"), deleted: optionalBool(input, "deleted")) }
private func optionalBool(_ input: [String: GatewayJSONValue], _ name: String) -> Bool? { if case .bool(let value) = input[name] { return value }; return nil }
private func argumentsBool(_ input: [String: GatewayJSONValue], _ name: String, _ fallback: Bool) -> Bool { optionalBool(input, name) ?? fallback }
private func trashThread(_ args: [String: GatewayJSONValue], _ context: GatewayResolverContext, _ trashed: Bool) throws -> GatewayJSONValue { let input = object(args, "input"); return try value(GmailGatewayWriteService(config: try config(context)).setThreadTrashed(accountId: string(input, "accountId"), threadId: string(input, "threadId"), trashed: trashed)) }
private func trashMessage(_ args: [String: GatewayJSONValue], _ context: GatewayResolverContext, _ trashed: Bool) throws -> GatewayJSONValue { let input = object(args, "input"); return try value(GmailGatewayWriteService(config: try config(context)).setMessageTrashed(accountId: string(input, "accountId"), messageId: string(input, "messageId"), trashed: trashed)) }

// swiftlint:enable line_length
