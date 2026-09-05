import Foundation
import GmailGatewayCore

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
    try testDraftGatewayRejectsSendMutations(cleanup: &cleanup)
    try testDraftGatewayRoutesDraftMutations(cleanup: &cleanup)
    try testSenderRoutesSendMessageToDirectSend(cleanup: &cleanup)
    try testSenderRoutesSendDraftToDirectSend(cleanup: &cleanup)
    try testReaderExposesLabelAndProfileReads(cleanup: &cleanup)
    try testThreadsBinaryOwnsMailboxMutations(cleanup: &cleanup)
    try testMessageBoxBinaryOwnsMailIngestion(cleanup: &cleanup)
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
    try assert(draftHelp.stdout.contains("This binary is draft-only"), "draft help should document the draft-only surface")
    try assert(
        draftHelp.stdout.contains("CAPABILITY_DENIED"),
        "draft help should document the rejected send mutations"
    )
    try assert(draftHelp.stdout.contains("keepAttachmentIds"), "draft help should document attachment replacement")
    try assert(draftHelp.stdout.contains("createReplyDraft"), "draft help should document threaded draft creation")
    try assert(senderHelpDocumentsSendDraft(), "sender help should document sendDraft")
    let readerHelp = runCli(["--help"])
    try assert(readerHelp.stdout.contains("labels, and profile"), "reader help should document the label and profile reads")
    let senderHelp = runCli(["--help"], mode: .directSender)
    try assert(senderHelp.stdout.contains("sendMessage directly sends mail"), "sender help should document direct send")
    let fileHelp = runCli(["file", "download", "--help"])
    try assert(fileHelp.exitCode == 0, "file download help should succeed")
    try assert(fileHelp.stdout.contains("Repeat this option"), "file download help should describe batch download")
    try assert(fileHelp.stdout.contains("\"fileCount\""), "file download help should describe batch output")
}

func testRelativeConfig(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let config = try GmailGatewayConfigLoader.loadConfig(configPath: fixture.configPath, environment: [:])
    try assert(config.storage.attachmentDir == fixture.attachmentRoot, "relative attachment path should resolve")
    try assert(config.storage.allowedSendAttachmentRoots == [fixture.sendRoot], "send root should resolve")
    try assert(config.credentials.first?.accessMode == .read, "access mode should parse")
}

func testCredentialEnvFallback(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup, includeCredentialPaths: false)
    let config = try GmailGatewayConfigLoader.loadConfig(
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
    let config = try GmailGatewayConfigLoader.loadConfig(
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
    env["GMAIL_GATEWAY_CONFIG"] = fixture.configPath
    let result = runCli(["config", "validate", "--config", fixture.configPath], env: env)
    try assert(result.exitCode == 0, "CLI config validation should use provided env")
    try assert(result.stderr.isEmpty, "env-only CLI config validation should not write stderr")
}

func testMissingDefaultConfigUsesFallback(cleanup: inout [String]) throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("gmail-gateway-default-\(UUID().uuidString)", isDirectory: true)
    cleanup.append(root.path)
    let env = [
        "XDG_CONFIG_HOME": root.appendingPathComponent("config-home", isDirectory: true).path,
        "XDG_DATA_HOME": root.appendingPathComponent("data-home", isDirectory: true).path,
        "XDG_CACHE_HOME": root.appendingPathComponent("cache-home", isDirectory: true).path
    ]

    let validate = runCli(["config", "validate"], env: env)
    try assert(validate.exitCode == 0, "missing default config should use fallback config")
    let validationOutput = try decodeObject(validate.stdout)
    try assert(validationOutput["fallbackConfig"] as? Bool == true, "fallback config should be marked")
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
        .appendingPathComponent("gmail-gateway-explicit-\(UUID().uuidString)", isDirectory: true)
    cleanup.append(root.path)
    let missingConfig = root.appendingPathComponent("missing.toml").path
    let result = runCli(["config", "validate", "--config", missingConfig])
    try assert(result.exitCode == GmailGatewayExitCode.configurationError.rawValue, "explicit missing config should fail")
    let output = try decodeObject(result.stderr)
    let error = output["error"] as? [String: Any]
    try assert(error?["code"] as? String == GmailGatewayErrorCode.configInvalid.rawValue, "missing explicit config is invalid")
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
    try assert(result.exitCode == GmailGatewayExitCode.authenticationBootstrapError.rawValue, "invalid login should fail")
    let output = try decodeObject(result.stderr)
    let error = output["error"] as? [String: Any]
    try assert(error?["code"] as? String == GmailGatewayErrorCode.configInvalid.rawValue, "invalid client JSON should be config error")
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
    env[GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
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
        capturedGmailQuery(at: 4) == "in:sent after:1782345600 before:2026/06/26 subject:receipt",
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
        #"{ threads(input: { accountId: "personal", direction: RECEIVED, labelIds: ["IMPORTANT"], query: "from:bob@example.com" }) { totalCount } }"#
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

do {
    try runSmokeTests()
    print("GmailGateway Swift smoke tests passed")
} catch {
    FileHandle.standardError.write(Data("Smoke test failure: \(error)\n".utf8))
    exit(1)
}
