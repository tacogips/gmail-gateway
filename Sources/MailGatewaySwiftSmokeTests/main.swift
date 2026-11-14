import Foundation
import MailGatewayCore

func runSmokeTests() throws {
    var cleanup: [String] = []
    defer {
        for path in cleanup {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    try testRelativeConfig(cleanup: &cleanup)
    try testHelpOutput()
    try testCredentialEnvFallback(cleanup: &cleanup)
    try testCredentialEnvOverride(cleanup: &cleanup)
    try testPrettyConfigValidation(cleanup: &cleanup)
    try testEnvOnlyConfigValidation(cleanup: &cleanup)
    try testMissingDefaultConfigUsesFallback(cleanup: &cleanup)
    try testExplicitMissingConfigStillFails(cleanup: &cleanup)
    try testMissingAuthStatus(cleanup: &cleanup)
    try testReadyAuthStatus(cleanup: &cleanup)
    try testScopeMismatchAuthStatus(cleanup: &cleanup)
    try testRevokeMissingToken(cleanup: &cleanup)
    try testInvalidAuthLoginClientSecret(cleanup: &cleanup)
    try testAccountsGraphQL(cleanup: &cleanup)
    try testStructuredThreadSearchGmailQuery(cleanup: &cleanup)
    try testReaderRejectsSendMutation(cleanup: &cleanup)
    try testDraftGatewayRoutesSendMessageToDraft(cleanup: &cleanup)
    try testSenderRoutesSendMessageToDirectSend(cleanup: &cleanup)
    try testSenderAlsoRoutesCreateDraft(cleanup: &cleanup)
    try testMissingDefaultAuthThreadsGraphQLError(cleanup: &cleanup)
    try testInvalidInlineVariables(cleanup: &cleanup)
    try testInvalidVariablesFile(cleanup: &cleanup)
    try testMissingQueryFile(cleanup: &cleanup)
    try testAttachmentLookup(cleanup: &cleanup)
    try testMissingAttachmentLookup(cleanup: &cleanup)
    try testMessageFileDownload(cleanup: &cleanup)
    try testRemoteAttachmentDownload(cleanup: &cleanup)
    try testMissingAccountGraphQLError(cleanup: &cleanup)
    try testAccountCachePrune(cleanup: &cleanup)
    try testInvalidCachePruneOptions(cleanup: &cleanup)
}

func testHelpOutput() throws {
    let rootHelp = runCli(["--help"])
    try assert(rootHelp.exitCode == 0, "root help should succeed")
    try assert(
        rootHelp.stdout.contains("--key <download-key> [--key <download-key> ...]"),
        "root help should document repeated download keys"
    )
    let draftHelp = runCli(["--help"], mode: .draftGateway)
    try assert(draftHelp.stdout.contains("sendMessage creates a provider draft"), "draft help should document draft default")
    let senderHelp = runCli(["--help"], mode: .directSender)
    try assert(senderHelp.stdout.contains("sendMessage directly sends mail"), "sender help should document direct send")
    let fileHelp = runCli(["file", "download", "--help"])
    try assert(fileHelp.exitCode == 0, "file download help should succeed")
    try assert(fileHelp.stdout.contains("Repeat this option"), "file download help should describe batch download")
    try assert(fileHelp.stdout.contains("\"fileCount\""), "file download help should describe batch output")
}

func testRelativeConfig(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let config = try MailGatewayConfigLoader.loadConfig(configPath: fixture.configPath, environment: [:])
    try assert(config.storage.attachmentDir == fixture.attachmentRoot, "relative attachment path should resolve")
    try assert(config.storage.allowedSendAttachmentRoots == [fixture.sendRoot], "send root should resolve")
    try assert(config.credentials.first?.accessMode == .read, "access mode should parse")
}

func testCredentialEnvFallback(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup, includeCredentialPaths: false)
    let config = try MailGatewayConfigLoader.loadConfig(
        configPath: fixture.configPath,
        environment: credentialEnv(fixture: fixture)
    )
    try assert(
        config.credentials.first?.oauthClientSecretPath == fixture.clientSecretPath,
        "env oauth path should load"
    )
    try assert(config.credentials.first?.tokenStorePath == fixture.tokenPath, "env token path should load")
}

func testCredentialEnvOverride(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let alternateSecretsDir = URL(fileURLWithPath: fixture.rootDir)
        .appendingPathComponent("alt-secrets", isDirectory: true)
        .path
    let alternateTokensDir = URL(fileURLWithPath: fixture.rootDir)
        .appendingPathComponent("alt-tokens", isDirectory: true)
        .path
    try FileManager.default.createDirectory(atPath: alternateSecretsDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: alternateTokensDir, withIntermediateDirectories: true)

    let alternateClientSecretPath = URL(fileURLWithPath: alternateSecretsDir)
        .appendingPathComponent("client.json")
        .path
    let alternateTokenPath = URL(fileURLWithPath: alternateTokensDir)
        .appendingPathComponent("account.json")
        .path
    try writeText(alternateClientSecretPath, "{\"installed\":true}\n")
    let config = try MailGatewayConfigLoader.loadConfig(
        configPath: fixture.configPath,
        environment: credentialEnv(
            fixture: fixture,
            oauthPath: alternateClientSecretPath,
            tokenPath: alternateTokenPath
        )
    )
    try assert(
        config.credentials.first?.oauthClientSecretPath == alternateClientSecretPath,
        "env oauth path should override TOML"
    )
    try assert(config.credentials.first?.tokenStorePath == alternateTokenPath, "env token path should override TOML")
}

func testPrettyConfigValidation(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli(["--pretty", "config", "validate", "--config", fixture.configPath])
    try assert(result.exitCode == 0, "pretty config validation should succeed")
    try assert(
        containsEither(result.stdout, "\n  \"ok\" : true", "\n  \"ok\": true"),
        "pretty output should contain ok"
    )
}

func testEnvOnlyConfigValidation(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup, includeCredentialPaths: false)
    var env = credentialEnv(fixture: fixture)
    env["MAIL_GATEWAY_CONFIG"] = fixture.configPath
    let result = runCli(["config", "validate", "--config", fixture.configPath], env: env)
    try assert(result.exitCode == 0, "CLI config validation should use provided env")
    try assert(result.stderr.isEmpty, "env-only CLI config validation should not write stderr")
}

func testMissingDefaultConfigUsesFallback(cleanup: inout [String]) throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mail-gateway-default-\(UUID().uuidString)", isDirectory: true)
    cleanup.append(root.path)
    let env = [
        "XDG_CONFIG_HOME": root.appendingPathComponent("config-home", isDirectory: true).path,
        "XDG_DATA_HOME": root.appendingPathComponent("data-home", isDirectory: true).path,
        "XDG_CACHE_HOME": root.appendingPathComponent("cache-home", isDirectory: true).path
    ]

    let validate = runCli(["config", "validate"], env: env)
    try assert(validate.exitCode == 0, "missing default config should use fallback config")
    let validationOutput = try decodeObject(validate.stdout)
    try assert(validationOutput["accountIds"] as? [String] == ["personal"], "fallback account id should be personal")
    try assert(
        validationOutput["credentialIds"] as? [String] == ["gmail-personal"],
        "fallback credential id should be gmail-personal"
    )

    let status = runCli(["auth", "status", "--credential", "gmail-personal"], env: env)
    try assert(status.exitCode == 0, "fallback auth status should succeed")
    let statusOutput = try decodeObject(status.stdout)
    try assert(statusOutput["state"] as? String == "MISSING", "fallback token state should be missing")
    try assert(statusOutput["tokenStoreExists"] as? Bool == false, "fallback token store should be absent")
}

func testExplicitMissingConfigStillFails(cleanup: inout [String]) throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mail-gateway-explicit-\(UUID().uuidString)", isDirectory: true)
    cleanup.append(root.path)
    let missingConfig = root.appendingPathComponent("missing.toml").path
    let result = runCli(["config", "validate", "--config", missingConfig])
    try assert(result.exitCode == MailGatewayExitCode.configurationError.rawValue, "explicit missing config should fail")
    let output = try decodeObject(result.stderr)
    let error = output["error"] as? [String: Any]
    try assert(error?["code"] as? String == MailGatewayErrorCode.configInvalid.rawValue, "missing explicit config is invalid")
}

func testMissingAuthStatus(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli(["auth", "status", "--config", fixture.configPath, "--credential", "gmail-personal"])
    try assert(result.exitCode == 0, "auth status should succeed")
    let output = try decodeObject(result.stdout)
    try assert(output["state"] as? String == "MISSING", "missing token state should be reported")
    try assert(output["tokenStoreExists"] as? Bool == false, "missing token existence should be false")
}

func testReadyAuthStatus(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    try writeText(
        fixture.tokenPath,
        """
        {
          "accessMode": "read",
          "accessToken": "access-token",
          "refreshToken": "refresh-token",
          "expiresAt": "2999-01-01T00:00:00Z",
          "emailAddress": "person@example.com"
        }
        """
    )
    let result = runCli(["auth", "status", "--config", fixture.configPath, "--credential", "gmail-personal"])
    try assert(result.exitCode == 0, "ready auth status should succeed")
    let output = try decodeObject(result.stdout)
    try assert(output["state"] as? String == "READY", "ready token state should be reported")
    try assert(output["grantedAccessMode"] as? String == AccessMode.read.rawValue, "granted mode should be read")
    try assert(output["hasRefreshToken"] as? Bool == true, "refresh token should be detected")
    try assert(output["expiresAt"] as? String == "2999-01-01T00:00:00Z", "expiry should be reported")
}

func testScopeMismatchAuthStatus(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    try writeText(fixture.tokenPath, #"{"accessMode":"read_send","refreshToken":"refresh-token"}"#)
    let result = runCli(["auth", "status", "--config", fixture.configPath, "--credential", "gmail-personal"])
    let output = try decodeObject(result.stdout)
    try assert(output["state"] as? String == "SCOPE_MISMATCH", "scope mismatch should be reported")
    try assert(output["grantedAccessMode"] as? String == "read_send", "granted mode should be read_send")
}

func testRevokeMissingToken(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli(["auth", "revoke", "--config", fixture.configPath, "--credential", "gmail-personal"])
    try assert(result.exitCode == 0, "revoke missing token should succeed")
    let output = try decodeObject(result.stdout)
    try assert(output["revoked"] as? Bool == false, "missing token revoke should be false")
}

func testInvalidAuthLoginClientSecret(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli(["auth", "login", "--config", fixture.configPath, "--credential", "gmail-personal"])
    try assert(result.exitCode == MailGatewayExitCode.authenticationBootstrapError.rawValue, "invalid login should fail")
    let output = try decodeObject(result.stderr)
    let error = output["error"] as? [String: Any]
    try assert(error?["code"] as? String == MailGatewayErrorCode.configInvalid.rawValue, "invalid client JSON should be config error")
}

func testAccountsGraphQL(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", """
        { accounts { id provider emailAddress capabilities \
        { canRead canSend configuredAccessMode authState } } }
        """
    ])
    try assert(result.exitCode == 0, "accounts GraphQL query should succeed")
    let output = try decodeObject(result.stdout)
    let data = output["data"] as? [String: Any]
    let account = (data?["accounts"] as? [[String: Any]])?.first
    try assert(account?["provider"] as? String == "GMAIL", "GraphQL provider should be uppercased")
    let capabilities = account?["capabilities"] as? [String: Any]
    try assert(
        capabilities?["configuredAccessMode"] as? String == "READ",
        "GraphQL access mode should be uppercased"
    )
    try assert(capabilities?["authState"] as? String == "MISSING", "GraphQL auth state should be missing")
}

func testStructuredThreadSearchGmailQuery(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let tokenStoreJSON = """
    {
      "accessMode": "read",
      "accessToken": "test-access-token",
      "refreshToken": null,
      "tokenType": "Bearer",
      "scope": "https://www.googleapis.com/auth/gmail.readonly",
      "expiresAt": "2999-01-01T00:00:00Z",
      "emailAddress": "person@example.com"
    }
    """
    var env = credentialEnv(fixture: fixture)
    env[MailGatewayConfigLoader.getCredentialJSONEnvVarName(
        credentialId: "gmail-personal",
        valueKey: "token_store_json"
    )] = tokenStoreJSON

    GmailRequestCaptureProtocol.reset()
    URLProtocol.registerClass(GmailRequestCaptureProtocol.self)
    defer {
        URLProtocol.unregisterClass(GmailRequestCaptureProtocol.self)
        GmailRequestCaptureProtocol.reset()
    }

    let starredOnly = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", #"{ threads(input: { accountId: "personal", starred: true }) { totalCount } }"#
    ], env: env)
    try assert(starredOnly.exitCode == 0, "starred-only thread search should succeed")
    try assert(
        capturedGmailQuery(at: 0) == "is:starred",
        "starred-only search should add Gmail starred query"
    )
    try assert(
        capturedGmailLabelIds(at: 0) == ["INBOX"],
        "starred search should preserve default label filters"
    )

    let starredWithQuery = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", #"{ threads(input: { accountId: "personal", starred: true, query: "from:alice@example.com" }) { totalCount } }"#
    ], env: env)
    try assert(starredWithQuery.exitCode == 0, "starred-plus-query thread search should succeed")
    try assert(
        capturedGmailQuery(at: 1) == "is:starred from:alice@example.com",
        "starred search should combine Gmail starred query and caller query"
    )

    let nullableStructuredFilters = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", #"{ threads(input: { accountId: "personal", starred: null, direction: ALL }) { totalCount } }"#
    ], env: env)
    try assert(nullableStructuredFilters.exitCode == 0, "nullable structured thread filters should succeed")
    try assert(
        capturedGmailQuery(at: 2) == nil,
        "null starred and ALL direction should not add a Gmail query"
    )
    try assert(
        capturedGmailLabelIds(at: 2) == ["INBOX"],
        "null structured filters should preserve default label filters"
    )

    let queryOnly = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", #"{ threads(input: { accountId: "personal", query: "subject:report" }) { totalCount } }"#
    ], env: env)
    try assert(queryOnly.exitCode == 0, "query-only thread search should continue to succeed")
    try assert(
        capturedGmailQuery(at: 3) == "subject:report",
        "query-only search should preserve caller query"
    )
    try assert(
        capturedGmailLabelIds(at: 3) == ["INBOX"],
        "query-only search should preserve default label filters"
    )

    let sentWithDateRange = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query",
        #"{ threads(input: { accountId: "personal", direction: SENT, receivedAfter: "2026-06-25T00:00:00Z", receivedBefore: "2026-06-26", query: "subject:receipt" }) { totalCount } }"#
    ], env: env)
    try assert(sentWithDateRange.exitCode == 0, "sent structured thread search should succeed")
    try assert(
        capturedGmailQuery(at: 4) == "in:sent after:2026/06/25 before:2026/06/26 subject:receipt",
        "sent structured search should combine direction, date range, and caller query"
    )
    try assert(
        capturedGmailLabelIds(at: 4).isEmpty,
        "sent structured search should not apply default inbox labels"
    )

    let receivedWithExplicitLabels = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query",
        #"{ threads(input: { accountId: "personal", direction: "RECEIVED", labelIds: ["IMPORTANT"], query: "from:bob@example.com" }) { totalCount } }"#
    ], env: env)
    try assert(receivedWithExplicitLabels.exitCode == 0, "received structured thread search should succeed")
    try assert(
        capturedGmailQuery(at: 5) == "-in:sent from:bob@example.com",
        "received structured search should combine direction and caller query"
    )
    try assert(
        capturedGmailLabelIds(at: 5) == ["IMPORTANT"],
        "explicit labelIds should override default labels"
    )
}

func capturedGmailQuery(at index: Int) -> String? {
    capturedGmailQueryItems(at: index).first(where: { $0.name == "q" })?.value
}

func capturedGmailLabelIds(at index: Int) -> [String] {
    capturedGmailQueryItems(at: index)
        .filter { $0.name == "labelIds" }
        .compactMap(\.value)
}

func capturedGmailQueryItems(at index: Int) -> [URLQueryItem] {
    guard GmailRequestCaptureProtocol.capturedURLs.indices.contains(index),
          let components = URLComponents(
            url: GmailRequestCaptureProtocol.capturedURLs[index],
            resolvingAgainstBaseURL: false
          ) else {
        return []
    }
    return components.queryItems ?? []
}

func testReaderRejectsSendMutation(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let sendResult = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", outboundMutation()
    ])
    try assert(sendResult.exitCode == MailGatewayExitCode.graphqlExecutionError.rawValue, "reader send mutation should fail")
    try assert(sendResult.stdout.contains("SEND_DISABLED_IN_READER"), "reader should reject send mutation with reader code")
    let draftResult = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", draftMutation()
    ])
    try assert(draftResult.exitCode == MailGatewayExitCode.graphqlExecutionError.rawValue, "reader draft mutation should fail")
    try assert(draftResult.stdout.contains("SEND_DISABLED_IN_READER"), "reader should reject draft mutation with reader code")
}

func testDraftGatewayRoutesSendMessageToDraft(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", outboundMutation()
    ], mode: .draftGateway)
    try assert(result.exitCode == MailGatewayExitCode.graphqlExecutionError.rawValue, "draft gateway should stop before provider call")
    try assert(result.stdout.contains("creating Gmail drafts"), "draft gateway should use draft auth context")
    try assert(!result.stdout.contains("sending Gmail messages"), "draft gateway should not use direct-send context")
}

func testSenderRoutesSendMessageToDirectSend(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", outboundMutation()
    ], mode: .directSender)
    try assert(result.exitCode == MailGatewayExitCode.graphqlExecutionError.rawValue, "sender should stop before provider call")
    try assert(result.stdout.contains("sending Gmail messages"), "sender should use direct-send auth context")
    try assert(!result.stdout.contains("creating Gmail drafts"), "sender should not use draft context")
}

func testSenderAlsoRoutesCreateDraft(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", draftMutation()
    ], mode: .directSender)
    try assert(result.exitCode == MailGatewayExitCode.graphqlExecutionError.rawValue, "sender draft should stop before provider call")
    try assert(result.stdout.contains("creating Gmail drafts"), "sender should include draft creation")
    try assert(!result.stdout.contains("sending Gmail messages"), "sender draft should not use direct-send context")
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

func testInvalidInlineVariables(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", "{ accounts { id } }",
        "--variables", "{bad-json}"
    ])
    try assert(result.exitCode == 2, "invalid inline variables should be CLI usage error")
    try assert(result.stderr.contains("--variables must be valid JSON"), "invalid variables error should be explained")
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
    try assert(result.exitCode == 2, "invalid variables file should be CLI usage error")
    try assert(
        result.stderr.contains("Failed to parse JSON variables file"),
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
        .appendingPathComponent("attachment-1-report.pdf")
        .path
    try writeText(attachmentPath, "payload")
    let result = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", """
        { attachment(accountId: "personal", messageId: "message-1", attachmentId: "attachment-1") \
        { id filename localPath downloadKey materializationState } }
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
        .appendingPathComponent("mimeType-report.pdf")
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
        .appendingPathComponent("accountId:-report.pdf")
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

    let nestedSelectionResult = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", """
        { attachment(accountId: "personal", messageId: "message-1", attachmentId: "attachment-1") \
        { id providerMetadata { mimeType } } }
        """
    ])
    try assert(nestedSelectionResult.exitCode == 0, "nested selection names should not project top-level fields")
    let nestedSelectionOutput = try decodeObject(nestedSelectionResult.stdout)
    let nestedSelectionData = nestedSelectionOutput["data"] as? [String: Any]
    let nestedSelectionAttachment = nestedSelectionData?["attachment"] as? [String: Any]
    try assert(nestedSelectionAttachment?["id"] as? String == "attachment-1", "direct id should project")
    try assert(
        nestedSelectionAttachment?["mimeType"] == nil,
        "nested selection field names should not project top-level attachment fields"
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
        { id filename localPath materializationState } }
        """
    ])
    try assert(result.exitCode == 0, "missing cached attachment query should succeed without live auth")
    let output = try decodeObject(result.stdout)
    let data = output["data"] as? [String: Any]
    try assert(data?["attachment"] is NSNull, "missing cached attachment should return null")
}

func testMissingDefaultAuthThreadsGraphQLError(cleanup: inout [String]) throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mail-gateway-no-auth-read-\(UUID().uuidString)", isDirectory: true)
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
        result.exitCode == MailGatewayExitCode.graphqlExecutionError.rawValue,
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
    try assert(result.exitCode == 5, "missing account GraphQL query should fail with GraphQL exit")
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

do {
    try runSmokeTests()
    print("MailGateway Swift smoke tests passed")
} catch {
    FileHandle.standardError.write(Data("Smoke test failure: \(error)\n".utf8))
    exit(1)
}
