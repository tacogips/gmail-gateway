import Foundation
import GmailGatewayCore

func testReaderRejectsSendMutation(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let sendResult = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", outboundMutation()
    ])
    try assert(sendResult.exitCode == 1, "reader send mutation should fail")
    try assert(sendResult.stdout.contains("CAPABILITY_DENIED"), "reader should reject send mutation before dispatch")
    let draftResult = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", draftMutation()
    ])
    try assert(draftResult.exitCode == 1, "reader draft mutation should fail")
    try assert(draftResult.stdout.contains("CAPABILITY_DENIED"), "reader should reject draft mutation before dispatch")
    for query in [updateDraftMutation(), deleteDraftMutation(), draftsQuery(), sendDraftMutation(), replyDraftMutation()] {
        let result = runCli([
            "graphql",
            "--config", fixture.configPath,
            "--query", query
        ])
        try assert(
            result.exitCode == 1,
            "reader draft surface should fail"
        )
        try assert(
            result.stdout.contains("CAPABILITY_DENIED"),
            "reader should reject the draft surface before dispatch"
        )
    }
}
func testDraftGatewayRejectsSendMutations(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    for query in [outboundMutation(), replyMutation(), forwardMutation(), sendDraftMutation()] {
        let result = runCli([
            "graphql",
            "--config", fixture.configPath,
            "--query", query
        ], mode: .draftGateway)
        try assert(
            result.exitCode == 1,
            "draft gateway should reject send mutations"
        )
        try assert(
            result.stdout.contains("CAPABILITY_DENIED"),
            "draft gateway should reject sender operations before dispatch"
        )
    }
}

func testDraftGatewayRoutesDraftMutations(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    for query in [draftMutation(), replyDraftMutation(), updateDraftMutation(), deleteDraftMutation()] {
        let result = runCli([
            "graphql",
            "--config", fixture.configPath,
            "--query", query
        ], mode: .draftGateway)
        try assert(
            result.exitCode == 1,
            "draft gateway should stop before provider call"
        )
        try assert(!result.stdout.contains("CAPABILITY_DENIED"), "draft gateway should own draft operations")
    }
}

func senderHelpDocumentsSendDraft() -> Bool {
    runCli(["--help"], mode: .directSender).stdout.contains("sendDraft sends a draft")
}

func testSenderRoutesSendDraftToDirectSend(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", sendDraftMutation()
    ], mode: .directSender)
    try assert(
        result.exitCode == 1,
        "sender sendDraft should stop before provider call"
    )
    try assert(!result.stdout.contains("CAPABILITY_DENIED"), "sender should own sendDraft")
}

func testReaderExposesLabelAndProfileReads(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    for query in [labelsQuery(), profileQuery()] {
        let result = runCli([
            "graphql",
            "--config", fixture.configPath,
            "--query", query
        ])
        try assert(
            result.exitCode == 1,
            "reader mailbox metadata should stop at the auth boundary, not at schema dispatch"
        )
        try assert(
            !result.stdout.contains("CAPABILITY_DENIED"),
            "reader should recognize the label and profile root fields"
        )
        try assert(
            result.stdout.contains("AUTH_REQUIRED"),
            "reader mailbox metadata should fail on missing auth rather than an unknown field"
        )
    }
}

func testThreadsBinaryOwnsMailboxMutations(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let threadsHelp = runCli(["--help"], mode: .mailboxThreads)
    try assert(threadsHelp.stdout.contains("gmail-gateway-threads"), "threads help should name its executable")
    try assert(threadsHelp.stdout.contains("irreversible"), "threads help should warn about permanent delete")

    // The mutation is owned here, so it must reach the credential check rather than schema dispatch.
    let owned = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", trashMessageMutation()
    ], mode: .mailboxThreads)
    try assert(
        owned.exitCode == 1,
        "threads mutation should stop before the provider call"
    )
    try assert(
        !owned.stdout.contains("CAPABILITY_DENIED"),
        "threads binary must not reject its own mutations"
    )

    for mode in [GmailGatewayCLIMode.reader, .draftGateway, .directSender, .messageBox] {
        let result = runCli([
            "graphql",
            "--config", fixture.configPath,
            "--query", trashMessageMutation()
        ], mode: mode)
        try assert(
            result.stdout.contains("CAPABILITY_DENIED"),
            "mailbox mutations should be rejected outside gmail-gateway-threads"
        )
    }
}

func testMessageBoxBinaryOwnsMailIngestion(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let messageBoxHelp = runCli(["--help"], mode: .messageBox)
    try assert(
        messageBoxHelp.stdout.contains("gmail-gateway-message-box"),
        "message-box help should name its executable"
    )
    try assert(
        messageBoxHelp.stdout.contains("importMessage and insertMessage"),
        "message-box help should document its mutations"
    )

    let owned = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", importMessageMutation()
    ], mode: .messageBox)
    try assert(
        !owned.stdout.contains("CAPABILITY_DENIED"),
        "message-box binary must not reject its own mutations"
    )

    for mode in [GmailGatewayCLIMode.reader, .draftGateway, .directSender, .mailboxThreads] {
        let result = runCli([
            "graphql",
            "--config", fixture.configPath,
            "--query", importMessageMutation()
        ], mode: mode)
        try assert(
            result.stdout.contains("CAPABILITY_DENIED"),
            "mail ingestion should be rejected outside gmail-gateway-message-box"
        )
    }
}

func trashMessageMutation() -> String {
    """
    mutation {
      trashMessage(input: {
        accountId: "personal",
        messageId: "message-1"
      }) {
        status
        operation
        messageId
      }
    }
    """
}

func importMessageMutation() -> String {
    """
    mutation {
      importMessage(input: {
        accountId: "personal",
        rfc822Path: "/tmp/smoke.eml"
      }) {
        status
        operation
        messageId
      }
    }
    """
}

func testSenderRoutesSendMessageToDirectSend(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", outboundMutation()
    ], mode: .directSender)
    try assert(result.exitCode == 1, "sender should stop before provider call")
    try assert(!result.stdout.contains("CAPABILITY_DENIED"), "sender should own sendMessage")
}

func testSenderAlsoRoutesCreateDraft(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", draftMutation()
    ], mode: .directSender)
    try assert(result.exitCode == 1, "sender draft should stop before provider call")
    try assert(!result.stdout.contains("CAPABILITY_DENIED"), "sender should own createDraft")
}

func outboundMutation() -> String {
    """
    mutation {
      sendMessage(input: {
        accountId: "personal",
        to: ["recipient@example.com"],
        subject: "Smoke test",
        textBody: "Smoke test body"
      }) {
        status
        operation
        messageId
      }
    }
    """
}

func draftMutation() -> String {
    """
    mutation {
      createDraft(input: {
        accountId: "personal",
        to: ["recipient@example.com"],
        subject: "Smoke draft",
        textBody: "Smoke draft body"
      }) {
        status
        operation
        draftId
        messageId
      }
    }
    """
}

func replyMutation() -> String {
    """
    mutation {
      replyMessage(input: {
        accountId: "personal",
        messageId: "message-1",
        textBody: "Smoke reply body"
      }) {
        status
      }
    }
    """
}

func forwardMutation() -> String {
    """
    mutation {
      forwardMessage(input: {
        accountId: "personal",
        messageId: "message-1",
        to: ["recipient@example.com"]
      }) {
        status
      }
    }
    """
}

func updateDraftMutation() -> String {
    """
    mutation {
      updateDraft(input: {
        accountId: "personal",
        draftId: "draft-1",
        subject: "Smoke draft update",
        keepAttachmentIds: []
      }) {
        status
        operation
        draftId
      }
    }
    """
}

func deleteDraftMutation() -> String {
    """
    mutation {
      deleteDraft(input: {
        accountId: "personal",
        draftId: "draft-1"
      }) {
        status
        operation
        draftId
      }
    }
    """
}

func sendDraftMutation() -> String {
    """
    mutation {
      sendDraft(input: {
        accountId: "personal",
        draftId: "draft-1"
      }) {
        status
        operation
        draftId
        messageId
      }
    }
    """
}

func replyDraftMutation() -> String {
    """
    mutation {
      createReplyDraft(input: {
        accountId: "personal",
        messageId: "message-1",
        textBody: "Smoke reply draft body"
      }) {
        status
        operation
        draftId
      }
    }
    """
}

func labelsQuery() -> String {
    """
    query {
      labels(accountId: "personal") {
        id
        name
      }
    }
    """
}

func profileQuery() -> String {
    """
    query {
      profile(accountId: "personal") {
        emailAddress
        messagesTotal
      }
    }
    """
}

func draftsQuery() -> String {
    """
    query {
      drafts(accountId: "personal", first: 5) {
        totalCount
      }
    }
    """
}

func testInvalidInlineVariables(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", "{ accounts { id } }",
        "--variables", "{bad-json}"
    ])
    try assert(result.exitCode == 2, "inline variables should be CLI usage error")
    try assert(
        result.stderr.contains("variables"),
        "invalid inline variables error should be explained"
    )
}

func testInvalidVariablesFile(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let variablesPath = URL(fileURLWithPath: fixture.rootDir).appendingPathComponent("variables.json").path
    try writeText(variablesPath, "{bad-json}")
    let result = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", "{ accounts { id } }",
        "--variables-file", variablesPath
    ])
    try assert(result.exitCode == 2, "variables file should be CLI usage error")
    try assert(
        result.stderr.contains("variables"),
        "invalid variables file error should be explained"
    )
}

func testMissingQueryFile(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let queryPath = URL(fileURLWithPath: fixture.rootDir).appendingPathComponent("missing.graphql").path
    let result = runCli(["graphql", "--config", fixture.configPath, "--query-file", queryPath])
    try assert(result.exitCode == 2, "missing query file should be CLI usage error")
    try assert(
        result.stderr.contains("Failed to read GraphQL query file"),
        "missing query file error should be explained"
    )
}

func testAttachmentLookup(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let messageDir = URL(fileURLWithPath: fixture.attachmentRoot)
        .appendingPathComponent("personal", isDirectory: true)
        .appendingPathComponent("message-1", isDirectory: true)
        .path
    try FileManager.default.createDirectory(atPath: messageDir, withIntermediateDirectories: true)
    let attachmentPath = URL(fileURLWithPath: messageDir)
        .appendingPathComponent(gmailGatewayAttachmentStorageFilename(
            attachmentId: "attachment-1",
            filename: "report.pdf"
        ))
        .path
    try writeText(attachmentPath, "payload")
    let result = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", """
        { attachment(accountId: "personal", messageId: "message-1", attachmentId: "attachment-1") \
        { id filename downloadKey materializationState } }
        """
    ])
    try assert(result.exitCode == 0, "attachment GraphQL query should succeed")
    try assert(
        containsEither(result.stdout, #""filename":"report.pdf""#, #""filename" : "report.pdf""#),
        "attachment filename should project"
    )
    try assert(
        containsEither(result.stdout, #""materializationState":"CACHED""#, #""materializationState" : "CACHED""#),
        "attachment state should be cached"
    )
    let output = try decodeObject(result.stdout)
    let data = output["data"] as? [String: Any]
    let attachment = data?["attachment"] as? [String: Any]
    try assert(attachment?["localPath"] == nil, "attachment GraphQL query should not expose local path")
    guard let downloadKey = attachment?["downloadKey"] as? String else {
        throw SmokeTestFailure.assertionFailed("cached attachment should include a download key")
    }
    try assertDownloadedFile(
        downloadKey: downloadKey,
        fixture: fixture,
        expectedKind: "ATTACHMENT",
        expectedContents: "payload"
    )

    let stringLiteralFieldNamePath = URL(fileURLWithPath: messageDir)
        .appendingPathComponent(gmailGatewayAttachmentStorageFilename(
            attachmentId: "mimeType",
            filename: "report.pdf"
        ))
        .path
    try writeText(stringLiteralFieldNamePath, "payload")
    let projectedResult = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", """
        { attachment(accountId: "personal", messageId: "message-1", attachmentId: "mimeType") { id } }
        """
    ])
    try assert(projectedResult.exitCode == 0, "attachment projection query should succeed")
    let projectedOutput = try decodeObject(projectedResult.stdout)
    let projectedData = projectedOutput["data"] as? [String: Any]
    let projectedAttachment = projectedData?["attachment"] as? [String: Any]
    try assert(projectedAttachment?["id"] as? String == "mimeType", "attachment id should project")
    try assert(projectedAttachment?["mimeType"] == nil, "field names in string literals should not project fields")
    try assert(projectedAttachment?["localPath"] == nil, "unrequested attachment localPath should not project")
    try assert(
        projectedAttachment?["materializationState"] == nil,
        "unrequested attachment materializationState should not project"
    )

    let stringLiteralArgumentNamePath = URL(fileURLWithPath: messageDir)
        .appendingPathComponent(gmailGatewayAttachmentStorageFilename(
            attachmentId: "accountId:",
            filename: "report.pdf"
        ))
        .path
    try writeText(stringLiteralArgumentNamePath, "payload")
    let reorderedResult = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", """
        { attachment(attachmentId: "accountId:", accountId: "personal", messageId: "message-1") { id filename } }
        """
    ])
    try assert(reorderedResult.exitCode == 0, "argument-like string literal should not affect parsing")
    let reorderedOutput = try decodeObject(reorderedResult.stdout)
    let reorderedData = reorderedOutput["data"] as? [String: Any]
    let reorderedAttachment = reorderedData?["attachment"] as? [String: Any]
    try assert(reorderedAttachment?["id"] as? String == "accountId:", "attachment id should allow argument-like text")
    try assert(reorderedAttachment?["filename"] as? String == "report.pdf", "attachment filename should parse")

    let spacedArgumentResult = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", """
        { attachment(accountId : "personal", messageId : "message-1", attachmentId : "attachment-1") \
        { id filename } }
        """
    ])
    try assert(spacedArgumentResult.exitCode == 0, "spaced GraphQL argument labels should parse")
    let spacedArgumentOutput = try decodeObject(spacedArgumentResult.stdout)
    let spacedArgumentData = spacedArgumentOutput["data"] as? [String: Any]
    let spacedArgumentAttachment = spacedArgumentData?["attachment"] as? [String: Any]
    try assert(
        spacedArgumentAttachment?["filename"] as? String == "report.pdf",
        "spaced argument labels should preserve attachment lookup"
    )

    let aliasedSelectionResult = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", """
        { attachment(accountId: "personal", messageId: "message-1", attachmentId: "attachment-1") \
        { id accountId: filename } }
        """
    ])
    try assert(aliasedSelectionResult.exitCode == 0, "selection aliases should not be parsed as arguments")
}

func testMissingAttachmentLookup(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", """
        { attachment(accountId: "personal", messageId: "message-1", attachmentId: "missing") \
        { id filename materializationState } }
        """
    ])
    try assert(result.exitCode == 0, "missing cached attachment query should succeed without live auth")
    let output = try decodeObject(result.stdout)
    let data = output["data"] as? [String: Any]
    try assert(data?["attachment"] is NSNull, "missing cached attachment should return null")
}

func testMissingDefaultAuthThreadsGraphQLError(cleanup: inout [String]) throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("gmail-gateway-no-auth-read-\(UUID().uuidString)", isDirectory: true)
    cleanup.append(root.path)
    let env = [
        "XDG_CONFIG_HOME": root.appendingPathComponent("config-home", isDirectory: true).path,
        "XDG_DATA_HOME": root.appendingPathComponent("data-home", isDirectory: true).path,
        "XDG_CACHE_HOME": root.appendingPathComponent("cache-home", isDirectory: true).path
    ]
    let result = runCli([
        "graphql",
        "--query", #"{ threads(input: { accountId: "personal" }) { totalCount } }"#
    ], env: env)
    try assert(
        result.exitCode == 1,
        "missing default auth threads query should fail with GraphQL exit"
    )
    try assert(result.stdout.contains("Authentication is required before reading Gmail"), "auth error should be explained")
    try assert(result.stdout.contains("AUTH_REQUIRED"), "GraphQL error should include auth required code")
}

func testMissingAccountGraphQLError(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", #"{ threads(input: { accountId: "missing-account" }) { totalCount } }"#
    ])
    try assert(result.exitCode == 1, "missing account GraphQL query should fail with GraphQL exit")
    try assert(result.stdout.contains("Unknown account: missing-account"), "GraphQL error should include app error")
    try assert(result.stdout.contains("ACCOUNT_NOT_FOUND"), "GraphQL error should include code")
}

func testAccountCachePrune(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let accountDir = URL(fileURLWithPath: fixture.attachmentRoot)
        .appendingPathComponent("personal", isDirectory: true)
        .path
    let otherDir = URL(fileURLWithPath: fixture.attachmentRoot)
        .appendingPathComponent("other", isDirectory: true)
        .path
    try FileManager.default.createDirectory(atPath: accountDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: otherDir, withIntermediateDirectories: true)
    try writeText(URL(fileURLWithPath: accountDir).appendingPathComponent("file.txt").path, "one")
    let otherFile = URL(fileURLWithPath: otherDir).appendingPathComponent("file.txt").path
    try writeText(otherFile, "two")
    let result = runCli(["cache", "prune", "--config", fixture.configPath, "--account", "personal"])
    try assert(result.exitCode == 0, "account cache prune should succeed")
    let output = try decodeObject(result.stdout)
    try assert((output["prunedPaths"] as? [String]) == [accountDir], "pruned path should be account directory")
    try assert((try? String(contentsOfFile: otherFile, encoding: .utf8)) == "two", "other account cache should remain")
}

func testInvalidCachePruneOptions(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli(["cache", "prune", "--config", fixture.configPath, "--all", "--account", "personal"])
    try assert(result.exitCode == 2, "combining --all and --account should fail")
    try assert(
        result.stderr.contains("cache prune accepts either --all or --account"),
        "cache prune error should be explained"
    )
}
