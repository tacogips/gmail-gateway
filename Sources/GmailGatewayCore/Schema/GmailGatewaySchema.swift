import GatewaySDKKit

// swiftlint:disable line_length

extension GmailGatewayCLIMode {
    var gatewayTier: String {
        switch self {
        case .reader: "reader"
        case .draftGateway: "draft"
        case .directSender: "sender"
        case .mailboxThreads: "threads"
        case .messageBox: "message-box"
        }
    }

    var gatewaySendEnabled: Bool {
        self == .draftGateway || self == .directSender
    }
}

extension GatewaySchemaCatalog {
    static let gmailFull = GatewaySchemaCatalog(
        provider: "gmail-gateway", tier: "full", operations: gmailOperations, types: gmailTypes
    )

    static func gmail(mode: GmailGatewayCLIMode) -> GatewaySchemaCatalog {
        let names = authorizedOperationNames(for: mode)
        return GatewaySchemaCatalog(
            provider: "gmail-gateway",
            tier: mode.gatewayTier,
            operations: gmailOperations.filter { names.contains($0.name) },
            types: gmailTypes
        )
    }
}

private func authorizedOperationNames(for mode: GmailGatewayCLIMode) -> Set<String> {
    let reads: Set<String> = [
        "accounts", "account", "threads", "thread", "message", "messageFileSet",
        "attachment", "labels", "profile"
    ]
    let drafts: Set<String> = [
        "drafts", "draft", "createDraft", "createReplyDraft", "createForwardDraft",
        "updateDraft", "deleteDraft"
    ]
    let sender: Set<String> = ["sendMessage", "replyMessage", "forwardMessage", "sendDraft"]
    let mailbox: Set<String> = [
        "modifyThreadLabels", "modifyMessageLabels", "batchModifyMessageLabels", "trashThread",
        "untrashThread", "trashMessage", "untrashMessage", "deleteThread", "deleteMessage",
        "batchDeleteMessages", "createLabel", "updateLabel", "deleteLabel"
    ]
    let ingest: Set<String> = ["importMessage", "insertMessage"]

    return switch mode {
    case .reader: reads
    case .draftGateway: reads.union(drafts)
    case .directSender: reads.union(drafts).union(sender)
    case .mailboxThreads: reads.union(mailbox)
    case .messageBox: reads.union(ingest)
    }
}

private func type(_ text: String) -> GatewayTypeRef {
    do {
        return try GatewayTypeRef.parse(text)
    } catch {
        preconditionFailure("Static Gmail schema has invalid type: \(text)")
    }
}

private func arg(
    _ name: String,
    _ text: String,
    required: Bool = false,
    defaultValue: GatewayJSONValue? = nil
) -> GatewayArgument {
    GatewayArgument(name: name, type: type(text), isRequired: required, defaultValue: defaultValue)
}

private func field(_ name: String, _ text: String) -> GatewayField {
    GatewayField(name: name, type: type(text))
}

private func object(_ name: String, _ fields: [GatewayField]) -> GatewayNamedType {
    GatewayNamedType(name: name, kind: .object(fields))
}

private func input(_ name: String, _ fields: [GatewayArgument]) -> GatewayNamedType {
    GatewayNamedType(name: name, kind: .inputObject(fields))
}

private func enumeration(_ name: String, _ values: [String]) -> GatewayNamedType {
    GatewayNamedType(name: name, kind: .enumeration(values))
}

private func inputArg(_ name: String) -> [GatewayArgument] {
    [arg("input", "\(name)!", required: true)]
}

private func op(
    _ name: String,
    _ kind: GatewayOperation.Kind,
    _ tier: String,
    _ arguments: [GatewayArgument],
    _ result: String,
    _ summary: String,
    destructive: Bool = false
) -> GatewayOperation {
    GatewayOperation(
        name: name,
        kind: kind,
        tier: tier,
        arguments: arguments,
        result: type(result),
        summary: summary,
        isDestructive: destructive,
        domain: "mail"
    )
}

private let gmailOperations: [GatewayOperation] = [
    op("accounts", .query, "reader", [], "[MailAccount!]!", "List configured mail accounts."),
    op("account", .query, "reader", [arg("id", "ID!", required: true)], "MailAccount", "Fetch one configured mail account."),
    op("threads", .query, "reader", inputArg("ThreadSearchInput"), "ThreadConnection!", "Search mail threads."),
    op("thread", .query, "reader", accountThreadArgs, "MailThread", "Fetch one mail thread."),
    op("message", .query, "reader", accountMessageArgs, "MailMessage", "Fetch one mail message."),
    op("messageFileSet", .query, "reader", accountMessageArgs, "MailMessageFileSet!", "List materialized message files."),
    op("attachment", .query, "reader", accountAttachmentArgs, "MailAttachment", "Fetch attachment metadata."),
    op("labels", .query, "reader", accountArgs, "[MailLabel!]!", "List mailbox labels."),
    op("profile", .query, "reader", accountArgs, "MailProfile!", "Fetch mailbox profile."),
    op("drafts", .query, "draft", draftListArgs, "MailDraftConnection!", "List mail drafts."),
    op("draft", .query, "draft", draftArgs, "MailDraft", "Fetch one draft."),
    op("createDraft", .mutation, "draft", inputArg("SendMessageInput"), "SendMessagePayload!", "Create a draft."),
    op("createReplyDraft", .mutation, "draft", inputArg("ReplyMessageInput"), "SendMessagePayload!", "Create a reply draft."),
    op("createForwardDraft", .mutation, "draft", inputArg("ForwardMessageInput"), "SendMessagePayload!", "Create a forward draft."),
    op("updateDraft", .mutation, "draft", inputArg("UpdateDraftInput"), "SendMessagePayload!", "Update a draft."),
    op("deleteDraft", .mutation, "draft", inputArg("DeleteDraftInput"), "SendMessagePayload!", "Delete a draft.", destructive: true),
    op("sendMessage", .mutation, "sender", inputArg("SendMessageInput"), "SendMessagePayload!", "Send a message."),
    op("replyMessage", .mutation, "sender", inputArg("ReplyMessageInput"), "SendMessagePayload!", "Send a reply."),
    op("forwardMessage", .mutation, "sender", inputArg("ForwardMessageInput"), "SendMessagePayload!", "Send a forward."),
    op("sendDraft", .mutation, "sender", inputArg("SendDraftInput"), "SendMessagePayload!", "Send a draft."),
    op("modifyThreadLabels", .mutation, "threads", inputArg("ModifyThreadLabelsInput"), "MailboxMutationPayload!", "Modify thread labels."),
    op("modifyMessageLabels", .mutation, "threads", inputArg("ModifyMessageLabelsInput"), "MailboxMutationPayload!", "Modify message labels."),
    op("batchModifyMessageLabels", .mutation, "threads", inputArg("BatchModifyMessageLabelsInput"), "MailboxMutationPayload!", "Modify labels on messages."),
    op("trashThread", .mutation, "threads", inputArg("ThreadMailboxActionInput"), "MailboxMutationPayload!", "Move a thread to trash.", destructive: true),
    op("untrashThread", .mutation, "threads", inputArg("ThreadMailboxActionInput"), "MailboxMutationPayload!", "Restore a thread from trash."),
    op("trashMessage", .mutation, "threads", inputArg("MessageMailboxActionInput"), "MailboxMutationPayload!", "Move a message to trash.", destructive: true),
    op("untrashMessage", .mutation, "threads", inputArg("MessageMailboxActionInput"), "MailboxMutationPayload!", "Restore a message from trash."),
    op("deleteThread", .mutation, "threads", inputArg("ThreadMailboxActionInput"), "MailboxMutationPayload!", "Permanently delete a thread.", destructive: true),
    op("deleteMessage", .mutation, "threads", inputArg("MessageMailboxActionInput"), "MailboxMutationPayload!", "Permanently delete a message.", destructive: true),
    op("batchDeleteMessages", .mutation, "threads", inputArg("BatchDeleteMessagesInput"), "MailboxMutationPayload!", "Permanently delete messages.", destructive: true),
    op("createLabel", .mutation, "threads", inputArg("CreateLabelInput"), "MailboxMutationPayload!", "Create a mailbox label."),
    op("updateLabel", .mutation, "threads", inputArg("UpdateLabelInput"), "MailboxMutationPayload!", "Update a mailbox label."),
    op("deleteLabel", .mutation, "threads", inputArg("DeleteLabelInput"), "MailboxMutationPayload!", "Delete a mailbox label.", destructive: true),
    op("importMessage", .mutation, "message-box", inputArg("MailboxIngestInput"), "MailboxMutationPayload!", "Import an RFC 822 message."),
    op("insertMessage", .mutation, "message-box", inputArg("MailboxIngestInput"), "MailboxMutationPayload!", "Insert an RFC 822 message.")
]

private let accountArgs = [arg("accountId", "ID!", required: true)]
private let accountThreadArgs = accountArgs + [arg("threadId", "ID!", required: true)]
private let accountMessageArgs = accountArgs + [arg("messageId", "ID!", required: true)]
private let accountAttachmentArgs = accountMessageArgs + [arg("attachmentId", "ID!", required: true)]
private let draftArgs = accountArgs + [arg("draftId", "ID!", required: true)]
private let draftListArgs = accountArgs + [arg("first", "Int", defaultValue: .int(20)), arg("after", "String")]

private let mailInputFields = [
    arg("accountId", "ID!", required: true), arg("to", "[String!]"), arg("cc", "[String!]"),
    arg("bcc", "[String!]"), arg("replyTo", "String"), arg("subject", "String"),
    arg("textBody", "String"), arg("htmlBody", "String"), arg("attachmentPaths", "[String!]")
]

private let gmailTypes: [GatewayNamedType] = [
    GatewayNamedType(name: "DateTime", kind: .scalar),
    object("MailAddress", [field("address", "String!"), field("raw", "String!")]),
    object("MailAccount", [field("id", "ID!"), field("provider", "MailProvider!"), field("emailAddress", "String!"), field("isFallback", "Boolean!"), field("capabilities", "MailCapabilities!")]),
    object("MailCapabilities", [field("canRead", "Boolean!"), field("canSend", "Boolean!"), field("configuredAccessMode", "AccessMode!"), field("authState", "AuthState!"), field("isFallback", "Boolean!")]),
    object("MailThread", [field("id", "ID!"), field("accountId", "ID!"), field("subject", "String"), field("snippet", "String"), field("messages", "[MailMessage!]!"), field("labels", "[String!]!"), field("providerMetadata", "ProviderMetadata")]),
    object("MailMessage", [field("id", "ID!"), field("threadId", "ID!"), field("accountId", "ID!"), field("subject", "String"), field("from", "[MailAddress!]!"), field("to", "[MailAddress!]!"), field("cc", "[MailAddress!]!"), field("bcc", "[MailAddress!]!"), field("replyTo", "[MailAddress!]!"), field("sentAt", "DateTime"), field("receivedAt", "DateTime"), field("snippet", "String"), field("textBody", "String"), field("htmlBody", "String"), field("attachments", "[MailAttachment!]!"), field("labels", "[String!]!"), field("historyId", "String"), field("providerMetadata", "ProviderMetadata")]),
    object("MailAttachment", [field("id", "ID!"), field("accountId", "ID"), field("messageId", "ID"), field("filename", "String"), field("mimeType", "String!"), field("sizeBytes", "Int"), field("downloadKey", "String"), field("materializationState", "AttachmentMaterializationState!"), field("providerMetadata", "ProviderMetadata")]),
    object("MailMessageFileSet", [field("accountId", "ID!"), field("messageId", "ID!"), field("hasFiles", "Boolean!"), field("files", "[MailMessageFile!]!")]),
    object("MailMessageFile", [field("kind", "MessageMaterializedFileKind!"), field("filename", "String!"), field("hasPayload", "Boolean!"), field("mimeType", "String"), field("sizeBytes", "Int"), field("downloadKey", "String!"), field("materializationState", "AttachmentMaterializationState!")]),
    object("MailThreadEdge", [field("cursor", "String!"), field("node", "MailThread!")]),
    object("PageInfo", [field("hasNextPage", "Boolean!"), field("endCursor", "String")]),
    object("ThreadConnection", [field("edges", "[MailThreadEdge!]!"), field("pageInfo", "PageInfo!"), field("totalCount", "Int!")]),
    object("ProviderMetadata", [field("gmail", "GmailProviderMetadata")]),
    object("GmailProviderMetadata", [field("accountId", "ID"), field("messageId", "ID"), field("threadId", "ID"), field("attachmentId", "ID"), field("partId", "ID"), field("labelIds", "[String!]"), field("historyId", "String")]),
    object("MailLabel", [field("id", "ID!"), field("accountId", "ID!"), field("name", "String"), field("type", "String"), field("messageListVisibility", "String"), field("labelListVisibility", "String")]),
    object("MailProfile", [field("accountId", "ID!"), field("emailAddress", "String"), field("messagesTotal", "Int"), field("threadsTotal", "Int"), field("historyId", "String")]),
    object("MailDraft", [field("id", "ID!"), field("accountId", "ID!"), field("message", "MailMessage")]),
    object("MailDraftEdge", [field("cursor", "String!"), field("node", "MailDraft!")]),
    object("MailDraftConnection", [field("edges", "[MailDraftEdge!]!"), field("pageInfo", "PageInfo!"), field("totalCount", "Int!")]),
    object("SendMessagePayload", [field("operation", "String!"), field("accountId", "ID!"), field("provider", "MailProvider!"), field("draftId", "ID"), field("messageId", "ID"), field("threadId", "ID"), field("status", "String!"), field("rejectedAttachments", "[RejectedAttachment!]!")]),
    object("RejectedAttachment", [field("path", "String!"), field("code", "String!"), field("reason", "String!")]),
    object("MailboxMutationPayload", [field("operation", "String!"), field("accountId", "ID!"), field("provider", "MailProvider!"), field("status", "String!"), field("threadId", "ID"), field("messageId", "ID"), field("messageIds", "[ID!]"), field("labelId", "ID"), field("label", "MailLabel"), field("labelIds", "[String!]")]),
    input("ThreadSearchInput", [arg("accountId", "ID!", required: true), arg("query", "String"), arg("starred", "Boolean"), arg("labelIds", "[String!]"), arg("direction", "MailDirectionFilter"), arg("receivedAfter", "DateTime"), arg("receivedBefore", "DateTime"), arg("first", "Int", defaultValue: .int(20)), arg("after", "String")]),
    input("SendMessageInput", mailInputFields),
    input("SendDraftInput", draftArgs),
    input("UpdateDraftInput", draftArgs + mailInputFields.dropFirst() + [arg("keepAttachmentIds", "[String!]")]),
    input("DeleteDraftInput", draftArgs),
    input("ReplyMessageInput", [arg("accountId", "ID!", required: true), arg("messageId", "ID!", required: true), arg("to", "[String!]"), arg("cc", "[String!]"), arg("bcc", "[String!]"), arg("replyAll", "Boolean", defaultValue: .bool(false)), arg("textBody", "String"), arg("htmlBody", "String"), arg("attachmentPaths", "[String!]")]),
    input("ForwardMessageInput", [arg("accountId", "ID!", required: true), arg("messageId", "ID!", required: true), arg("to", "[String!]!", required: true), arg("cc", "[String!]"), arg("bcc", "[String!]"), arg("textBody", "String"), arg("htmlBody", "String"), arg("includeAttachments", "Boolean", defaultValue: .bool(true)), arg("attachmentPaths", "[String!]")]),
    input("ModifyThreadLabelsInput", accountThreadArgs + [arg("addLabelIds", "[String!]"), arg("removeLabelIds", "[String!]")]),
    input("ModifyMessageLabelsInput", accountMessageArgs + [arg("addLabelIds", "[String!]"), arg("removeLabelIds", "[String!]")]),
    input("BatchModifyMessageLabelsInput", accountArgs + [arg("messageIds", "[ID!]!", required: true), arg("addLabelIds", "[String!]"), arg("removeLabelIds", "[String!]")]),
    input("ThreadMailboxActionInput", accountThreadArgs),
    input("MessageMailboxActionInput", accountMessageArgs),
    input("BatchDeleteMessagesInput", accountArgs + [arg("messageIds", "[ID!]!", required: true)]),
    input("CreateLabelInput", [arg("accountId", "ID!", required: true), arg("name", "String!", required: true), arg("messageListVisibility", "MessageListVisibility"), arg("labelListVisibility", "LabelListVisibility")]),
    input("UpdateLabelInput", [arg("accountId", "ID!", required: true), arg("labelId", "ID!", required: true), arg("name", "String"), arg("messageListVisibility", "MessageListVisibility"), arg("labelListVisibility", "LabelListVisibility")]),
    input("DeleteLabelInput", accountArgs + [arg("labelId", "ID!", required: true)]),
    input("MailboxIngestInput", [arg("accountId", "ID!", required: true), arg("rfc822Path", "String!", required: true), arg("labelIds", "[String!]"), arg("internalDateSource", "InternalDateSource"), arg("neverMarkSpam", "Boolean"), arg("processForCalendar", "Boolean"), arg("deleted", "Boolean")]),
    enumeration("MailProvider", ["GMAIL"]),
    enumeration("MailDirectionFilter", ["SENT", "RECEIVED", "ALL"]),
    enumeration("MessageMaterializedFileKind", ["ATTACHMENT", "BODY_TEXT", "BODY_HTML", "TEMPORARY_FILE"]),
    enumeration("AttachmentMaterializationState", ["NOT_MATERIALIZED", "CACHED", "MATERIALIZED"]),
    enumeration("AccessMode", ["READ", "READ_SEND", "READ_MODIFY", "FULL"]),
    enumeration("AuthState", ["MISSING", "READY", "EXPIRED", "SCOPE_MISMATCH", "INVALID", "UNKNOWN"]),
    enumeration("MessageListVisibility", ["show", "hide"]),
    enumeration("LabelListVisibility", ["labelShow", "labelShowIfUnread", "labelHide"]),
    enumeration("InternalDateSource", ["RECEIVED_TIME", "DATE_HEADER"])
]

// swiftlint:enable line_length
