import GatewaySDKKit
import Testing
@testable import GmailGatewayCore

@Test func gmailCatalogMatchesTheCompleteTestOwnedSchemaContractAndResolverParity() throws {
    let catalog = GatewaySchemaCatalog.gmailFull
    #expect(catalog.validate().isEmpty)
    #expect(try catalog.operations.map(operationSignature) == GmailGatewayAcceptedCatalogContract.operations)
    #expect(try catalog.types.map(namedTypeSignature) == GmailGatewayAcceptedCatalogContract.namedTypes)
    #expect(Set(catalog.operations.map(\.name)) == Set(GmailGatewayResolvers.all.keys))
}

@Test func everyModeCatalogMatchesTheIndependentAcceptedOperationContract() {
    let modes: [GmailGatewayCLIMode] = [
        .reader, .draftGateway, .directSender, .mailboxThreads, .messageBox
    ]
    for mode in modes {
        let catalog = GatewaySchemaCatalog.gmail(mode: mode)
        #expect(catalog.validate().isEmpty)
        #expect(
            Set(catalog.operations.map(\.name)) == GmailGatewayAcceptedRuntimeContract.operations(for: mode),
            "\(mode.gatewayTier) must expose exactly its accepted operations"
        )
        #expect(catalog.tier == mode.gatewayTier)
    }
}

@Test func catalogUsesOnlyTheAcceptedDestructiveOperations() {
    let destructive = Set(
        GatewaySchemaCatalog.gmailFull.operations
            .filter(\.isDestructive)
            .map(\.name)
    )
    #expect(destructive == [
        "deleteDraft", "deleteThread", "deleteMessage", "batchDeleteMessages", "deleteLabel",
        "trashThread", "trashMessage"
    ])
}

private func operationSignature(_ operation: GatewayOperation) throws -> String {
    let arguments = try operation.arguments.map(argumentSignature).joined(separator: ";")
    return [
        operation.name,
        operation.kind.rawValue,
        operation.tier,
        arguments,
        operation.result?.graphQLString ?? "-",
        operation.summary,
        String(operation.isDestructive)
    ].joined(separator: "|")
}

private func namedTypeSignature(_ namedType: GatewayNamedType) throws -> String {
    let payload: String
    switch namedType.kind {
    case .scalar:
        payload = "scalar"
    case .object(let fields):
        payload = "object|" + (try fields.map(fieldSignature).joined(separator: ";"))
    case .inputObject(let fields):
        payload = "input|" + (try fields.map(argumentSignature).joined(separator: ";"))
    case .enumeration(let values):
        payload = "enum|" + values.joined(separator: ";")
    }
    return "\(namedType.name)|\(payload)"
}

private func fieldSignature(_ field: GatewayField) throws -> String {
    let arguments = try field.arguments.map(argumentSignature).joined(separator: ",")
    return "\(field.name):\(field.type.graphQLString)[\(arguments)]"
}

private func argumentSignature(_ argument: GatewayArgument) throws -> String {
    let defaultValue = try argument.defaultValue?.jsonString(pretty: false) ?? "-"
    return "\(argument.name):\(argument.type.graphQLString):required=\(argument.isRequired):default=\(defaultValue)"
}

// This fixture is deliberately a test-owned transcription of the accepted Phase 1d
// contract. Do not derive any entry from GatewaySchemaCatalog: it is the drift oracle.
// swiftlint:disable line_length
private enum GmailGatewayAcceptedCatalogContract {
    static let operations = [
        "accounts|query|reader||[MailAccount!]!|List configured mail accounts.|false",
        "account|query|reader|id:ID!:required=true:default=-|MailAccount|Fetch one configured mail account.|false",
        "threads|query|reader|input:ThreadSearchInput!:required=true:default=-|ThreadConnection!|Search mail threads.|false",
        "thread|query|reader|accountId:ID!:required=true:default=-;threadId:ID!:required=true:default=-|MailThread|Fetch one mail thread.|false",
        "message|query|reader|accountId:ID!:required=true:default=-;messageId:ID!:required=true:default=-|MailMessage|Fetch one mail message.|false",
        "messageFileSet|query|reader|accountId:ID!:required=true:default=-;messageId:ID!:required=true:default=-|MailMessageFileSet!|List materialized message files.|false",
        "attachment|query|reader|accountId:ID!:required=true:default=-;messageId:ID!:required=true:default=-;attachmentId:ID!:required=true:default=-|MailAttachment|Fetch attachment metadata.|false",
        "labels|query|reader|accountId:ID!:required=true:default=-|[MailLabel!]!|List mailbox labels.|false",
        "profile|query|reader|accountId:ID!:required=true:default=-|MailProfile!|Fetch mailbox profile.|false",
        "drafts|query|draft|accountId:ID!:required=true:default=-;first:Int:required=false:default=20;after:String:required=false:default=-|MailDraftConnection!|List mail drafts.|false",
        "draft|query|draft|accountId:ID!:required=true:default=-;draftId:ID!:required=true:default=-|MailDraft|Fetch one draft.|false",
        "createDraft|mutation|draft|input:SendMessageInput!:required=true:default=-|SendMessagePayload!|Create a draft.|false",
        "createReplyDraft|mutation|draft|input:ReplyMessageInput!:required=true:default=-|SendMessagePayload!|Create a reply draft.|false",
        "createForwardDraft|mutation|draft|input:ForwardMessageInput!:required=true:default=-|SendMessagePayload!|Create a forward draft.|false",
        "updateDraft|mutation|draft|input:UpdateDraftInput!:required=true:default=-|SendMessagePayload!|Update a draft.|false",
        "deleteDraft|mutation|draft|input:DeleteDraftInput!:required=true:default=-|SendMessagePayload!|Delete a draft.|true",
        "sendMessage|mutation|sender|input:SendMessageInput!:required=true:default=-|SendMessagePayload!|Send a message.|false",
        "replyMessage|mutation|sender|input:ReplyMessageInput!:required=true:default=-|SendMessagePayload!|Send a reply.|false",
        "forwardMessage|mutation|sender|input:ForwardMessageInput!:required=true:default=-|SendMessagePayload!|Send a forward.|false",
        "sendDraft|mutation|sender|input:SendDraftInput!:required=true:default=-|SendMessagePayload!|Send a draft.|false",
        "modifyThreadLabels|mutation|threads|input:ModifyThreadLabelsInput!:required=true:default=-|MailboxMutationPayload!|Modify thread labels.|false",
        "modifyMessageLabels|mutation|threads|input:ModifyMessageLabelsInput!:required=true:default=-|MailboxMutationPayload!|Modify message labels.|false",
        "batchModifyMessageLabels|mutation|threads|input:BatchModifyMessageLabelsInput!:required=true:default=-|MailboxMutationPayload!|Modify labels on messages.|false",
        "trashThread|mutation|threads|input:ThreadMailboxActionInput!:required=true:default=-|MailboxMutationPayload!|Move a thread to trash.|true",
        "untrashThread|mutation|threads|input:ThreadMailboxActionInput!:required=true:default=-|MailboxMutationPayload!|Restore a thread from trash.|false",
        "trashMessage|mutation|threads|input:MessageMailboxActionInput!:required=true:default=-|MailboxMutationPayload!|Move a message to trash.|true",
        "untrashMessage|mutation|threads|input:MessageMailboxActionInput!:required=true:default=-|MailboxMutationPayload!|Restore a message from trash.|false",
        "deleteThread|mutation|threads|input:ThreadMailboxActionInput!:required=true:default=-|MailboxMutationPayload!|Permanently delete a thread.|true",
        "deleteMessage|mutation|threads|input:MessageMailboxActionInput!:required=true:default=-|MailboxMutationPayload!|Permanently delete a message.|true",
        "batchDeleteMessages|mutation|threads|input:BatchDeleteMessagesInput!:required=true:default=-|MailboxMutationPayload!|Permanently delete messages.|true",
        "createLabel|mutation|threads|input:CreateLabelInput!:required=true:default=-|MailboxMutationPayload!|Create a mailbox label.|false",
        "updateLabel|mutation|threads|input:UpdateLabelInput!:required=true:default=-|MailboxMutationPayload!|Update a mailbox label.|false",
        "deleteLabel|mutation|threads|input:DeleteLabelInput!:required=true:default=-|MailboxMutationPayload!|Delete a mailbox label.|true",
        "importMessage|mutation|message-box|input:MailboxIngestInput!:required=true:default=-|MailboxMutationPayload!|Import an RFC 822 message.|false",
        "insertMessage|mutation|message-box|input:MailboxIngestInput!:required=true:default=-|MailboxMutationPayload!|Insert an RFC 822 message.|false"
    ]

    static let namedTypes = [
        "DateTime|scalar",
        "MailAddress|object|address:String![];raw:String![]",
        "MailAccount|object|id:ID![];provider:MailProvider![];emailAddress:String![];isFallback:Boolean![];capabilities:MailCapabilities![]",
        "MailCapabilities|object|canRead:Boolean![];canSend:Boolean![];configuredAccessMode:AccessMode![];authState:AuthState![];isFallback:Boolean![]",
        "MailThread|object|id:ID![];accountId:ID![];subject:String[];snippet:String[];messages:[MailMessage!]![];labels:[String!]![];providerMetadata:ProviderMetadata[]",
        "MailMessage|object|id:ID![];threadId:ID![];accountId:ID![];subject:String[];from:[MailAddress!]![];to:[MailAddress!]![];cc:[MailAddress!]![];bcc:[MailAddress!]![];replyTo:[MailAddress!]![];sentAt:DateTime[];receivedAt:DateTime[];snippet:String[];textBody:String[];htmlBody:String[];attachments:[MailAttachment!]![];labels:[String!]![];historyId:String[];providerMetadata:ProviderMetadata[]",
        "MailAttachment|object|id:ID![];accountId:ID[];messageId:ID[];filename:String[];mimeType:String![];sizeBytes:Int[];downloadKey:String[];materializationState:AttachmentMaterializationState![];providerMetadata:ProviderMetadata[]",
        "MailMessageFileSet|object|accountId:ID![];messageId:ID![];hasFiles:Boolean![];files:[MailMessageFile!]![]",
        "MailMessageFile|object|kind:MessageMaterializedFileKind![];filename:String![];hasPayload:Boolean![];mimeType:String[];sizeBytes:Int[];downloadKey:String![];materializationState:AttachmentMaterializationState![]",
        "MailThreadEdge|object|cursor:String![];node:MailThread![]",
        "PageInfo|object|hasNextPage:Boolean![];endCursor:String[]",
        "ThreadConnection|object|edges:[MailThreadEdge!]![];pageInfo:PageInfo![];totalCount:Int![]",
        "ProviderMetadata|object|gmail:GmailProviderMetadata[]",
        "GmailProviderMetadata|object|accountId:ID[];messageId:ID[];threadId:ID[];attachmentId:ID[];partId:ID[];labelIds:[String!][];historyId:String[]",
        "MailLabel|object|id:ID![];accountId:ID![];name:String[];type:String[];messageListVisibility:String[];labelListVisibility:String[]",
        "MailProfile|object|accountId:ID![];emailAddress:String[];messagesTotal:Int[];threadsTotal:Int[];historyId:String[]",
        "MailDraft|object|id:ID![];accountId:ID![];message:MailMessage[]",
        "MailDraftEdge|object|cursor:String![];node:MailDraft![]",
        "MailDraftConnection|object|edges:[MailDraftEdge!]![];pageInfo:PageInfo![];totalCount:Int![]",
        "SendMessagePayload|object|operation:String![];accountId:ID![];provider:MailProvider![];draftId:ID[];messageId:ID[];threadId:ID[];status:String![];rejectedAttachments:[RejectedAttachment!]![]",
        "RejectedAttachment|object|path:String![];code:String![];reason:String![]",
        "MailboxMutationPayload|object|operation:String![];accountId:ID![];provider:MailProvider![];status:String![];threadId:ID[];messageId:ID[];messageIds:[ID!][];labelId:ID[];label:MailLabel[];labelIds:[String!][]",
        "ThreadSearchInput|input|accountId:ID!:required=true:default=-;query:String:required=false:default=-;starred:Boolean:required=false:default=-;labelIds:[String!]:required=false:default=-;direction:MailDirectionFilter:required=false:default=-;receivedAfter:DateTime:required=false:default=-;receivedBefore:DateTime:required=false:default=-;first:Int:required=false:default=20;after:String:required=false:default=-",
        "SendMessageInput|input|accountId:ID!:required=true:default=-;to:[String!]:required=false:default=-;cc:[String!]:required=false:default=-;bcc:[String!]:required=false:default=-;replyTo:String:required=false:default=-;subject:String:required=false:default=-;textBody:String:required=false:default=-;htmlBody:String:required=false:default=-;attachmentPaths:[String!]:required=false:default=-",
        "SendDraftInput|input|accountId:ID!:required=true:default=-;draftId:ID!:required=true:default=-",
        "UpdateDraftInput|input|accountId:ID!:required=true:default=-;draftId:ID!:required=true:default=-;to:[String!]:required=false:default=-;cc:[String!]:required=false:default=-;bcc:[String!]:required=false:default=-;replyTo:String:required=false:default=-;subject:String:required=false:default=-;textBody:String:required=false:default=-;htmlBody:String:required=false:default=-;attachmentPaths:[String!]:required=false:default=-;keepAttachmentIds:[String!]:required=false:default=-",
        "DeleteDraftInput|input|accountId:ID!:required=true:default=-;draftId:ID!:required=true:default=-",
        "ReplyMessageInput|input|accountId:ID!:required=true:default=-;messageId:ID!:required=true:default=-;to:[String!]:required=false:default=-;cc:[String!]:required=false:default=-;bcc:[String!]:required=false:default=-;replyAll:Boolean:required=false:default=false;textBody:String:required=false:default=-;htmlBody:String:required=false:default=-;attachmentPaths:[String!]:required=false:default=-",
        "ForwardMessageInput|input|accountId:ID!:required=true:default=-;messageId:ID!:required=true:default=-;to:[String!]!:required=true:default=-;cc:[String!]:required=false:default=-;bcc:[String!]:required=false:default=-;textBody:String:required=false:default=-;htmlBody:String:required=false:default=-;includeAttachments:Boolean:required=false:default=true;attachmentPaths:[String!]:required=false:default=-",
        "ModifyThreadLabelsInput|input|accountId:ID!:required=true:default=-;threadId:ID!:required=true:default=-;addLabelIds:[String!]:required=false:default=-;removeLabelIds:[String!]:required=false:default=-",
        "ModifyMessageLabelsInput|input|accountId:ID!:required=true:default=-;messageId:ID!:required=true:default=-;addLabelIds:[String!]:required=false:default=-;removeLabelIds:[String!]:required=false:default=-",
        "BatchModifyMessageLabelsInput|input|accountId:ID!:required=true:default=-;messageIds:[ID!]!:required=true:default=-;addLabelIds:[String!]:required=false:default=-;removeLabelIds:[String!]:required=false:default=-",
        "ThreadMailboxActionInput|input|accountId:ID!:required=true:default=-;threadId:ID!:required=true:default=-",
        "MessageMailboxActionInput|input|accountId:ID!:required=true:default=-;messageId:ID!:required=true:default=-",
        "BatchDeleteMessagesInput|input|accountId:ID!:required=true:default=-;messageIds:[ID!]!:required=true:default=-",
        "CreateLabelInput|input|accountId:ID!:required=true:default=-;name:String!:required=true:default=-;messageListVisibility:MessageListVisibility:required=false:default=-;labelListVisibility:LabelListVisibility:required=false:default=-",
        "UpdateLabelInput|input|accountId:ID!:required=true:default=-;labelId:ID!:required=true:default=-;name:String:required=false:default=-;messageListVisibility:MessageListVisibility:required=false:default=-;labelListVisibility:LabelListVisibility:required=false:default=-",
        "DeleteLabelInput|input|accountId:ID!:required=true:default=-;labelId:ID!:required=true:default=-",
        "MailboxIngestInput|input|accountId:ID!:required=true:default=-;rfc822Path:String!:required=true:default=-;labelIds:[String!]:required=false:default=-;internalDateSource:InternalDateSource:required=false:default=-;neverMarkSpam:Boolean:required=false:default=-;processForCalendar:Boolean:required=false:default=-;deleted:Boolean:required=false:default=-",
        "MailProvider|enum|GMAIL",
        "MailDirectionFilter|enum|SENT;RECEIVED;ALL",
        "MessageMaterializedFileKind|enum|ATTACHMENT;BODY_TEXT;BODY_HTML;TEMPORARY_FILE",
        "AttachmentMaterializationState|enum|NOT_MATERIALIZED;CACHED;MATERIALIZED",
        "AccessMode|enum|READ;READ_SEND;READ_MODIFY;FULL",
        "AuthState|enum|MISSING;READY;EXPIRED;SCOPE_MISMATCH;INVALID;UNKNOWN",
        "MessageListVisibility|enum|show;hide",
        "LabelListVisibility|enum|labelShow;labelShowIfUnread;labelHide",
        "InternalDateSource|enum|RECEIVED_TIME;DATE_HEADER"
    ]
}
// swiftlint:enable line_length
