import Foundation
import Darwin
import Testing
@testable import MailGatewayCore

@Test func readerHelpUsesReaderExecutableName() {
    let result = MailGatewayCLI().run(arguments: ["--help"], environment: [:])
    #expect(result.exitCode == MailGatewayExitCode.success.rawValue)
    #expect(result.stdout.contains("mail-gateway-reader"))
}

@Test func draftHelpUsesDraftExecutableName() {
    let result = MailGatewayCLI(mode: .draftGateway).run(arguments: ["--help"], environment: [:])
    #expect(result.exitCode == MailGatewayExitCode.success.rawValue)
    #expect(result.stdout.contains("mail-gateway-draft"))
}

@Test func senderHelpUsesSenderExecutableName() {
    let result = MailGatewayCLI(mode: .directSender).run(arguments: ["--help"], environment: [:])
    #expect(result.exitCode == MailGatewayExitCode.success.rawValue)
    #expect(result.stdout.contains("mail-gateway-sender"))
}

@Test func versionFlagReturnsVersionForAllBinaries() {
    let expected = "0.1.5\n"

    #expect(MailGatewayCLI().run(arguments: ["--version"], environment: [:]).stdout == expected)
    #expect(MailGatewayCLI(mode: .draftGateway).run(arguments: ["--version"], environment: [:]).stdout == expected)
    #expect(MailGatewayCLI(mode: .directSender).run(arguments: ["version"], environment: [:]).stdout == expected)
}

@Test func tokenRefreshOAuthClientUsesConfiguredTokenURIAndAllowsPublicClient() throws {
    let credential = testCredential(oauthClientSecretJSON: """
        {
          "installed": {
            "client_id": " client-id ",
            "auth_uri": " https://accounts.example.test/o/oauth2/auth ",
            "token_uri": " https://tokens.example.test/token "
          }
        }
        """)

    let client = try loadGoogleOAuthClient(credential: credential, use: .tokenRefresh)

    #expect(client.clientId == "client-id")
    #expect(client.clientSecret == nil)
    #expect(client.tokenURI == "https://tokens.example.test/token")
}

@Test func tokenRefreshOAuthClientAcceptsWebClient() throws {
    let credential = testCredential(oauthClientSecretJSON: """
        {
          "web": {
            "client_id": "web-client-id",
            "client_secret": "web-secret",
            "token_uri": "https://tokens.example.test/token"
          }
        }
        """)

    let client = try loadGoogleOAuthClient(credential: credential, use: .tokenRefresh)

    #expect(client.clientId == "web-client-id")
    #expect(client.clientSecret == "web-secret")
    #expect(client.tokenURI == "https://tokens.example.test/token")
}

@Test func tokenRefreshOAuthClientRejectsWebClientWithoutSecret() throws {
    let credential = testCredential(oauthClientSecretJSON: """
        {
          "web": {
            "client_id": "web-client-id",
            "token_uri": "https://tokens.example.test/token"
          }
        }
        """)

    let error = try requireMailGatewayError {
        _ = try loadGoogleOAuthClient(credential: credential, use: .tokenRefresh)
    }

    #expect(error.code == .configInvalid)
    #expect(error.exitCode == .configurationError)
}

@Test func desktopLoginRejectsWebOnlyOAuthClient() throws {
    let credential = testCredential(oauthClientSecretJSON: """
        {
          "web": {
            "client_id": "web-client-id",
            "client_secret": "web-secret",
            "token_uri": "https://tokens.example.test/token"
          }
        }
        """)

    let error = try requireMailGatewayError {
        _ = try loadGoogleOAuthClient(credential: credential, use: .desktopLogin)
    }

    #expect(error.code == .configInvalid)
    #expect(error.exitCode == .authenticationBootstrapError)
}

@Test func malformedAccessTokenExpiryIsNotFresh() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-06-26T00:00:00Z"))

    #expect(gmailAccessTokenIsFresh(expiresAt: nil, now: now))
    #expect(!gmailAccessTokenIsFresh(expiresAt: "not-a-date", now: now))
    #expect(!gmailAccessTokenIsFresh(expiresAt: "2026-06-26T00:00:30Z", now: now, refreshLeeway: 60))
    #expect(gmailAccessTokenIsFresh(expiresAt: "2026-06-26T00:02:00Z", now: now, refreshLeeway: 60))
}

@Test func formURLEncodedEscapesReservedCharacters() {
    let encoded = formURLEncoded([
        ("redirect_uri", "http://127.0.0.1:1234/oauth2callback"),
        ("literal", "a+b c%")
    ])

    #expect(encoded == "redirect_uri=http%3A%2F%2F127.0.0.1%3A1234%2Foauth2callback&literal=a%2Bb%20c%25")
}

@Test func oauthLoginRejectsNonLoopbackRedirectURI() throws {
    let credential = testCredential(oauthClientSecretJSON: """
        {
          "installed": {
            "client_id": "client-id",
            "auth_uri": "https://accounts.example.test/o/oauth2/auth",
            "token_uri": "https://tokens.example.test/token"
          }
        }
        """)

    let error = try requireMailGatewayError {
        _ = try GmailOAuthBootstrapper().login(
            credential: credential,
            options: GmailOAuthLoginOptions(
                redirectURI: "https://example.com/oauth2callback",
                openBrowser: false,
                timeoutSeconds: 1
            )
        )
    }

    #expect(error.code == .authRequired)
    #expect(error.exitCode == .authenticationBootstrapError)
    #expect(error.message.contains("loopback"))
}

@Test func loopbackOAuthReceiverAcceptsLocalCallback() throws {
    let receiver = try LoopbackOAuthReceiver()
    let resultBox = OAuthCallbackResultBox()
    let semaphore = DispatchSemaphore(value: 0)

    DispatchQueue.global(qos: .userInitiated).async {
        resultBox.result = Result {
            try receiver.waitForCode(expectedState: "state-value", timeoutSeconds: 5)
        }
        semaphore.signal()
    }

    let response = try sendRawHTTPRequest(to: receiver.redirectURI + "?state=state-value&code=auth-code")
    #expect(response.contains("HTTP/1.1 200 OK"))
    #expect(response.contains("Gmail authentication completed"))
    #expect(semaphore.wait(timeout: .now() + .seconds(5)) == .success)
    #expect(try resultBox.result?.get() == "auth-code")
}

@Test func loopbackOAuthReceiverIgnoresWrongPathBeforeCallback() throws {
    let receiver = try LoopbackOAuthReceiver()
    let resultBox = OAuthCallbackResultBox()
    let semaphore = DispatchSemaphore(value: 0)

    DispatchQueue.global(qos: .userInitiated).async {
        resultBox.result = Result {
            try receiver.waitForCode(expectedState: "state-value", timeoutSeconds: 5)
        }
        semaphore.signal()
    }

    let faviconResponse = try sendRawHTTPRequest(to: receiver.redirectURI.replacingOccurrences(
        of: "/oauth2callback",
        with: "/favicon.ico"
    ))
    #expect(faviconResponse.contains("HTTP/1.1 404 Not Found"))

    let callbackResponse = try sendRawHTTPRequest(to: receiver.redirectURI + "?state=state-value&code=auth-code")
    #expect(callbackResponse.contains("HTTP/1.1 200 OK"))
    #expect(semaphore.wait(timeout: .now() + .seconds(5)) == .success)
    #expect(try resultBox.result?.get() == "auth-code")
}

@Test func loopbackOAuthReceiverRewritesLocalhostRedirectURIToIPv4() throws {
    let port = try reserveFreeLoopbackPort()
    let receiver = try LoopbackOAuthReceiver(redirectURI: "http://localhost:\(port)/callback")

    #expect(receiver.redirectURI == "http://127.0.0.1:\(port)/callback")
}

@Test func base64URLDecoderRejectsStandardBase64Alphabet() throws {
    #expect(dataFromBase64URLString("-w") == Data([251]))
    #expect(dataFromBase64URLString("-w==") == Data([251]))
    #expect(dataFromBase64URLString("+w==") == nil)
    #expect(dataFromBase64URLString("abc=d") == nil)
    #expect(dataFromBase64URLString("a") == nil)
}

@Test func intValueRejectsBooleansAndNonIntegralNumbers() {
    #expect(intValue(42) == 42)
    #expect(intValue(NSNumber(value: 1)) == 1)
    #expect(intValue(" 42 ") == 42)
    #expect(intValue(true) == nil)
    #expect(intValue(NSNumber(value: true)) == nil)
    #expect(intValue(NSNumber(value: 1.25)) == nil)
}

@Test func accountCachePruneRejectsUnknownAccountWithoutForceUnwrap() throws {
    try withReaderService { service, _ in
        let error = try requireMailGatewayError {
            _ = try service.pruneCache(accountId: "missing", all: false)
        }

        #expect(error.code == .accountNotFound)
        #expect(error.exitCode == .graphqlExecutionError)
    }
}

@Test func accountCachePruneRequiresSelector() throws {
    try withReaderService { service, paths in
        let error = try requireMailGatewayError {
            _ = try service.pruneCache(accountId: nil, all: false)
        }

        #expect(error.code == .invalidArgument)
        #expect(error.exitCode == .invalidCliUsage)
        #expect(!FileManager.default.fileExists(atPath: paths.attachmentDir))
    }
}

@Test func accountCachePruneDoesNotClaimMissingAccountDirectory() throws {
    try withReaderService { service, _ in
        let result = try service.pruneCache(accountId: "personal", all: false)

        #expect((result["prunedPaths"] as? [String]) == [])
    }
}

@Test func accountCachePruneReportsOnlyRemovedDirectory() throws {
    try withReaderService { service, paths in
        let accountDirectory = URL(fileURLWithPath: paths.attachmentDir)
            .appendingPathComponent("personal", isDirectory: true)
        try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true, attributes: nil)
        try Data("cached".utf8).write(to: accountDirectory.appendingPathComponent("file.txt"))

        let result = try service.pruneCache(accountId: "personal", all: false)

        #expect((result["prunedPaths"] as? [String]) == [accountDirectory.path])
        #expect(!FileManager.default.fileExists(atPath: accountDirectory.path))
    }
}

@Test func cachedAttachmentLookupUsesHashedPrefixAndReportsSize() throws {
    try withReaderService { service, paths in
        let messageDirectory = URL(fileURLWithPath: paths.attachmentDir)
            .appendingPathComponent("personal", isDirectory: true)
            .appendingPathComponent("message-id", isDirectory: true)
        try FileManager.default.createDirectory(at: messageDirectory, withIntermediateDirectories: true)
        try Data("wrong".utf8).write(to: messageDirectory.appendingPathComponent(
            mailGatewayAttachmentStorageFilename(attachmentId: "abc-def", filename: "wrong.txt")
        ))

        let missing = try service.getAttachment(accountId: "personal", messageId: "message-id", attachmentId: "abc")
        #expect(missing is NSNull)

        let cachedName = mailGatewayAttachmentStorageFilename(attachmentId: "abc", filename: "right.txt")
        try Data("right-payload".utf8).write(to: messageDirectory.appendingPathComponent(cachedName))

        let attachment = try #require(try service.getAttachment(
            accountId: "personal",
            messageId: "message-id",
            attachmentId: "abc"
        ) as? [String: Any])

        #expect(attachment["filename"] as? String == "right.txt")
        #expect((attachment["sizeBytes"] as? NSNumber)?.intValue == "right-payload".utf8.count)
        #expect(attachment["materializationState"] as? String == AttachmentMaterializationState.cached.rawValue)
    }
}

@Test func graphqlVariablesAreRejectedInsteadOfIgnored() throws {
    let result = MailGatewayCLI().run(
        arguments: [
            "graphql",
            "--query", "{ accounts { id } }",
            "--variables", #"{"accountId":"personal"}"#
        ],
        environment: [:]
    )

    #expect(result.exitCode == MailGatewayExitCode.invalidCliUsage.rawValue)
    #expect(result.stderr.contains("GraphQL variables are not supported yet"))
    let output = try #require(JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: Any])
    let error = try #require(output["error"] as? [String: Any])
    let requestId = try #require(error["requestId"] as? String)
    #expect(!requestId.isEmpty)
}

@Test func threadSearchRejectsUnsupportedInputFilters() throws {
    let result = try executeReaderGraphQL(
        config: testConfig(paths: temporaryConfigPaths()),
        query: #"{ threads(input: { accountId: "personal", unread: true }) { totalCount } }"#
    )

    #expect(result.exitCode == .graphqlExecutionError)
    #expect("\(result.body)".contains("Unsupported ThreadSearchInput field(s): unread"))
    let errors = try #require(result.body["errors"] as? [[String: Any]])
    let extensions = try #require(errors.first?["extensions"] as? [String: Any])
    let requestId = try #require(extensions["requestId"] as? String)
    #expect(!requestId.isEmpty)
}

@Test func threadSearchRejectsInvalidFirstBeforeProviderCall() throws {
    let result = try executeReaderGraphQL(
        config: testConfig(paths: temporaryConfigPaths()),
        query: #"{ threads(input: { accountId: "personal", first: 0 }) { totalCount } }"#
    )

    #expect(result.exitCode == .graphqlExecutionError)
    #expect("\(result.body)".contains("ThreadSearchInput.first"))
}

@Test func readerAllowsWriteFieldNameAliasForReadRootField() throws {
    let result = try executeReaderGraphQL(
        config: testConfig(paths: temporaryConfigPaths()),
        query: #"{ sendMessage: account(id: "personal") { id } }"#
    )

    #expect(result.exitCode == .success)
    #expect(!"\(result.body)".contains("SEND_DISABLED_IN_READER"))
}

@Test func readerRejectsAliasedWriteRootField() throws {
    let result = try executeReaderGraphQL(
        config: testConfig(paths: temporaryConfigPaths()),
        query: #"{ x: sendMessage(input: { accountId: "personal", to: ["a@example.com"], subject: "Hi", textBody: "Body" }) { messageId } }"#
    )

    #expect(result.exitCode == .graphqlExecutionError)
    #expect("\(result.body)".contains("SEND_DISABLED_IN_READER"))
}

@Test func outboundMailRejectsHeaderLineBreaksBeforeProviderCall() throws {
    try withWriteService { service in
        let input = OutboundMailInput(
            accountId: "personal",
            to: ["recipient@example.com"],
            subject: "Hello\nInjected: header",
            textBody: "Body"
        )

        let error = try requireMailGatewayError {
            _ = try service.sendMessage(input: input, mode: .directSend)
        }

        #expect(error.code == .invalidArgument)
        #expect(error.message.contains("line breaks"))
    }
}

@Test func outboundMailRejectsBlankRecipientsBeforeProviderCall() throws {
    try withWriteService { service in
        let input = OutboundMailInput(
            accountId: "personal",
            to: ["   "],
            subject: "Hello",
            textBody: "Body"
        )

        let error = try requireMailGatewayError {
            _ = try service.sendMessage(input: input, mode: .directSend)
        }

        #expect(error.code == .invalidArgument)
        #expect(error.message.contains("recipient values"))
    }
}

@Test func outboundMailRejectsConfiguredSenderLineBreaksBeforeProviderCall() throws {
    try withWriteService(emailAddress: "person@example.com\nInjected: header") { service in
        let input = OutboundMailInput(
            accountId: "personal",
            to: ["recipient@example.com"],
            subject: "Hello",
            textBody: "Body"
        )

        let error = try requireMailGatewayError {
            _ = try service.sendMessage(input: input, mode: .directSend)
        }

        #expect(error.code == .invalidArgument)
        #expect(error.message.contains("line breaks"))
    }
}

@Test func outboundMailRejectsAuthenticatedSenderMismatchBeforeProviderCall() throws {
    let tokenStoreJSON = """
    {
      "accessMode": "read_send",
      "accessToken": "test-access-token",
      "refreshToken": null,
      "tokenType": "Bearer",
      "scope": "https://www.googleapis.com/auth/gmail.send",
      "expiresAt": "2999-01-01T00:00:00Z",
      "emailAddress": "other@example.com"
    }
    """
    try withWriteService(tokenStoreJSON: tokenStoreJSON) { service in
        let input = OutboundMailInput(
            accountId: "personal",
            to: ["recipient@example.com"],
            subject: "Hello",
            textBody: "Body"
        )

        let error = try requireMailGatewayError {
            _ = try service.sendMessage(input: input, mode: .directSend)
        }

        #expect(error.code == .configInvalid)
        #expect(error.message.contains("authenticated Gmail identity"))
    }
}

@Test func rawMessageOmitsEmptyToAndBuildsCrlfMultipartAlternative() throws {
    let paths = temporaryConfigPaths()
    defer {
        try? FileManager.default.removeItem(atPath: paths.root)
    }
    try FileManager.default.createDirectory(atPath: paths.sendDir, withIntermediateDirectories: true, attributes: nil)
    let attachmentPath = URL(fileURLWithPath: paths.sendDir).appendingPathComponent("note.txt")
    try Data("attachment".utf8).write(to: attachmentPath)

    let input = OutboundMailInput(
        accountId: "personal",
        to: [],
        cc: ["copy@example.com"],
        subject: "Hello",
        textBody: "Line 1\nLine 2",
        htmlBody: "<p>Line 1</p>\r<p>Line 2</p>"
    )

    let message = try decodedRawMessage(buildRawMessage(
        from: "person@example.com",
        input: input,
        attachmentPaths: [attachmentPath.path]
    ))

    #expect(!message.contains("\r\nTo:"))
    #expect(message.contains("\r\nCc: copy@example.com"))
    #expect(message.contains("Content-Type: multipart/mixed; boundary="))
    #expect(message.contains("Content-Type: multipart/alternative; boundary="))
    #expect(message.contains("Content-Type: text/plain; charset=utf-8"))
    #expect(message.contains("Content-Type: text/html; charset=utf-8"))
    #expect(message.contains("Line 1\r\nLine 2"))
    #expect(message.contains("<p>Line 1</p>\r\n<p>Line 2</p>"))
    #expect(mimeLineEndingsAreCRLF(message))
}

@Test func rawMessageUsesAttachmentMimeTypeFromExtension() throws {
    let paths = temporaryConfigPaths()
    defer {
        try? FileManager.default.removeItem(atPath: paths.root)
    }
    try FileManager.default.createDirectory(atPath: paths.sendDir, withIntermediateDirectories: true, attributes: nil)
    let attachmentPath = URL(fileURLWithPath: paths.sendDir).appendingPathComponent("report.pdf")
    try Data("attachment".utf8).write(to: attachmentPath)

    let input = OutboundMailInput(
        accountId: "personal",
        to: ["recipient@example.com"],
        textBody: "Body",
        attachmentPaths: [attachmentPath.path]
    )

    let message = try decodedRawMessage(buildRawMessage(
        from: "person@example.com",
        input: input,
        attachmentPaths: [attachmentPath.path]
    ))

    #expect(message.contains("Content-Type: application/pdf; name=\"report.pdf\""))
}

@Test func rawMessageWrapsAttachmentBase64Lines() throws {
    let paths = temporaryConfigPaths()
    defer {
        try? FileManager.default.removeItem(atPath: paths.root)
    }
    try FileManager.default.createDirectory(atPath: paths.sendDir, withIntermediateDirectories: true, attributes: nil)
    let attachmentPath = URL(fileURLWithPath: paths.sendDir).appendingPathComponent("blob.bin")
    try Data(repeating: 0xab, count: 180).write(to: attachmentPath)

    let input = OutboundMailInput(
        accountId: "personal",
        to: ["recipient@example.com"],
        textBody: "Body",
        attachmentPaths: [attachmentPath.path]
    )

    let message = try decodedRawMessage(buildRawMessage(
        from: "person@example.com",
        input: input,
        attachmentPaths: [attachmentPath.path]
    ))
    let lines = attachmentBase64Lines(in: message)

    #expect(!lines.isEmpty)
    #expect(lines.allSatisfy { $0.count <= 76 })
    #expect(lines.contains { $0.count == 76 })
}

@Test func rawMessageRejectsOversizedPayloadBeforeProviderCall() throws {
    let input = OutboundMailInput(
        accountId: "personal",
        to: ["recipient@example.com"],
        textBody: String(repeating: "x", count: 26 * 1_024 * 1_024)
    )

    let error = try requireMailGatewayError {
        _ = try buildRawMessage(from: "person@example.com", input: input, attachmentPaths: [])
    }

    #expect(error.code == .invalidArgument)
    #expect(error.exitCode == .graphqlExecutionError)
    #expect(error.message.contains("size limit"))
}

@Test func invalidDateHeaderFallsBackToInternalDate() throws {
    let account = AccountConfig(
        id: "personal",
        provider: .gmail,
        emailAddress: "person@example.com",
        credentialId: "gmail-personal",
        defaultLabelIds: ["INBOX"]
    )
    let message = buildMessage(account: account, object: [
        "id": "message-id",
        "threadId": "thread-id",
        "internalDate": "1782936000000",
        "payload": [
            "headers": [
                ["name": "Date", "value": "not a valid date"]
            ]
        ]
    ])
    let expected = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_782_936_000))

    #expect(message["sentAt"] as? String == expected)
}

@Test func quotedAddressWithCommaStaysSingleRawAddress() throws {
    let account = AccountConfig(
        id: "personal",
        provider: .gmail,
        emailAddress: "person@example.com",
        credentialId: "gmail-personal",
        defaultLabelIds: ["INBOX"]
    )
    let message = buildMessage(account: account, object: [
        "id": "message-id",
        "threadId": "thread-id",
        "payload": [
            "headers": [
                ["name": "From", "value": #""Doe, John" <jd@example.com>, jane@example.com"#]
            ]
        ]
    ])
    let from = try #require(message["from"] as? [[String: String]])

    #expect(from.map { $0["raw"] } == [#""Doe, John" <jd@example.com>"#, "jane@example.com"])
}

func withReaderService(_ operation: (MailGatewayService, TestConfigPaths) throws -> Void) throws {
    try withReaderService(tokenStoreJSON: nil, operation)
}

func withReaderService(
    tokenStoreJSON: String?,
    _ operation: (MailGatewayService, TestConfigPaths) throws -> Void
) throws {
    let paths = temporaryConfigPaths()
    defer {
        try? FileManager.default.removeItem(atPath: paths.root)
    }
    try operation(MailGatewayService(config: testConfig(paths: paths, tokenStoreJSON: tokenStoreJSON)), paths)
}

private func withWriteService(
    accessMode: AccessMode = .readSend,
    emailAddress: String = "person@example.com",
    tokenStoreJSON: String? = nil,
    _ operation: (MailGatewayWriteService) throws -> Void
) throws {
    let paths = temporaryConfigPaths()
    defer {
        try? FileManager.default.removeItem(atPath: paths.root)
    }
    let config = testConfig(
        paths: paths,
        accessMode: accessMode,
        emailAddress: emailAddress,
        tokenStoreJSON: tokenStoreJSON
    )
    try operation(MailGatewayWriteService(config: config))
}

struct TestConfigPaths {
    let root: String
    let cacheDir: String
    let attachmentDir: String
    let sendDir: String
}

func temporaryConfigPaths() -> TestConfigPaths {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mail-gateway-tests-\(UUID().uuidString)", isDirectory: true)
    return TestConfigPaths(
        root: root.path,
        cacheDir: root.appendingPathComponent("cache", isDirectory: true).path,
        attachmentDir: root.appendingPathComponent("attachments", isDirectory: true).path,
        sendDir: root.appendingPathComponent("send", isDirectory: true).path
    )
}

func testConfig(
    paths: TestConfigPaths,
    accessMode: AccessMode = .read,
    emailAddress: String = "person@example.com",
    tokenStoreJSON: String? = nil
) -> MailGatewayConfig {
    MailGatewayConfig(
        configPath: paths.root + "/config.toml",
        storage: StorageConfig(
            cacheDir: paths.cacheDir,
            attachmentDir: paths.attachmentDir,
            allowedSendAttachmentRoots: [paths.sendDir]
        ),
        credentials: [
            CredentialConfig(
                id: "gmail-personal",
                provider: .gmail,
                accessMode: accessMode,
                oauthClientSecretPath: paths.root + "/client.json",
                oauthClientSecretJSON: nil,
                tokenStorePath: paths.root + "/token.json",
                tokenStoreJSON: tokenStoreJSON
            )
        ],
        accounts: [
            AccountConfig(
                id: "personal",
                provider: .gmail,
                emailAddress: emailAddress,
                credentialId: "gmail-personal",
                defaultLabelIds: ["INBOX"]
            )
        ]
    )
}

private func testCredential(oauthClientSecretJSON: String, accessMode: AccessMode = .readSend) -> CredentialConfig {
    CredentialConfig(
        id: "gmail-personal",
        provider: .gmail,
        accessMode: accessMode,
        oauthClientSecretPath: "/tmp/client.json",
        oauthClientSecretJSON: oauthClientSecretJSON,
        tokenStorePath: "/tmp/token.json",
        tokenStoreJSON: nil
    )
}

private final class OAuthCallbackResultBox: @unchecked Sendable {
    var result: Result<String, Error>?
}

private func sendRawHTTPRequest(to urlString: String) throws -> String {
    guard let components = URLComponents(string: urlString),
          let host = components.host,
          let port = components.port else {
        throw ExpectedMailGatewayError(description: "Invalid callback URL: \(urlString)")
    }
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
        throw ExpectedMailGatewayError(description: "Failed to create callback test socket")
    }
    defer {
        close(socketFD)
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr(host))
    let connectResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.connect(socketFD, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connectResult == 0 else {
        throw ExpectedMailGatewayError(description: "Failed to connect to callback test server")
    }

    var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
    if let query = components.percentEncodedQuery {
        target += "?\(query)"
    }
    let request = """
    GET \(target) HTTP/1.1\r
    Host: \(host):\(port)\r
    Connection: close\r
    \r

    """
    _ = request.withCString { pointer in
        Darwin.write(socketFD, pointer, strlen(pointer))
    }

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while true {
        let count = Darwin.read(socketFD, &buffer, buffer.count)
        if count <= 0 {
            break
        }
        response.append(contentsOf: buffer.prefix(Int(count)))
    }
    return String(data: response, encoding: .utf8) ?? ""
}

private func reserveFreeLoopbackPort() throws -> UInt16 {
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
        throw ExpectedMailGatewayError(description: "Failed to create port reservation socket")
    }
    defer {
        close(socketFD)
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(0).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.bind(socketFD, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        throw ExpectedMailGatewayError(description: "Failed to bind port reservation socket")
    }

    var boundAddress = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            getsockname(socketFD, socketAddress, &length)
        }
    }
    guard nameResult == 0 else {
        throw ExpectedMailGatewayError(description: "Failed to read reserved loopback port")
    }
    return UInt16(bigEndian: boundAddress.sin_port)
}

private struct ExpectedMailGatewayError: Error, CustomStringConvertible {
    let description: String
}

final class TestGmailRequestCaptureProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedURLs: [URL] = []
    nonisolated(unsafe) static var capturedHTTPBodies: [Data] = []
    nonisolated(unsafe) static var responseStatusCode = 200
    nonisolated(unsafe) static var responseStatusCodes: [Int] = []
    nonisolated(unsafe) static var responseData = Data(#"{"threads":[],"resultSizeEstimate":0}"#.utf8)
    nonisolated(unsafe) static var threadListResponseData: Data?
    nonisolated(unsafe) static var threadGetResponseData: Data?
    nonisolated(unsafe) static var messageGetResponseData: Data?
    nonisolated(unsafe) static var attachmentResponseData: Data?
    nonisolated(unsafe) static var failAttachmentPayloadRequests = false
    nonisolated(unsafe) static var expectedListMaxResults: String?
    nonisolated(unsafe) static var expectedListPageToken: String?
    nonisolated(unsafe) static var expectedListQuery: String?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "gmail.googleapis.com"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let url = request.url {
            Self.capturedURLs.append(url)
        }
        if let body = request.httpBody ?? Self.data(from: request.httpBodyStream) {
            Self.capturedHTTPBodies.append(body)
        }
        if request.url?.path == "/gmail/v1/users/me/threads",
           let components = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) {
            let queryItems = components.queryItems ?? []
            let maxResults = queryItems.first(where: { $0.name == "maxResults" })?.value
            let pageToken = queryItems.first(where: { $0.name == "pageToken" })?.value
            let query = queryItems.first(where: { $0.name == "q" })?.value
            if let expected = Self.expectedListMaxResults,
               maxResults != expected {
                respondWithError(message: "unexpected maxResults")
                return
            }
            if let expected = Self.expectedListPageToken,
               pageToken != expected {
                respondWithError(message: "unexpected pageToken")
                return
            }
            if let expected = Self.expectedListQuery,
               query != expected {
                respondWithError(message: "unexpected query")
                return
            }
        }
        if Self.failAttachmentPayloadRequests,
           request.url?.path.contains("/attachments/") == true {
            respondWithError(message: "unexpected attachment payload request")
            return
        }
        let statusCode: Int
        if Self.responseStatusCodes.isEmpty {
            statusCode = Self.responseStatusCode
        } else {
            statusCode = Self.responseStatusCodes.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://gmail.googleapis.com/")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData(for: request))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func respondWithError(message: String) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://gmail.googleapis.com/")!,
            statusCode: 500,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":{"message":"\#(message)"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func responseData(for request: URLRequest) -> Data {
        guard let path = request.url?.path else {
            return Self.responseData
        }
        if path == "/gmail/v1/users/me/threads" {
            return Self.threadListResponseData ?? Self.responseData
        }
        if path.hasPrefix("/gmail/v1/users/me/threads/") {
            return Self.threadGetResponseData ?? Self.responseData
        }
        if path.contains("/attachments/") {
            return Self.attachmentResponseData ?? Self.responseData
        }
        if path.hasPrefix("/gmail/v1/users/me/messages/") {
            return Self.messageGetResponseData ?? Self.responseData
        }
        return Self.responseData
    }

    private static func data(from stream: InputStream?) -> Data? {
        guard let stream else {
            return nil
        }
        stream.open()
        defer {
            stream.close()
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }

    static func reset() {
        capturedURLs = []
        capturedHTTPBodies = []
        responseStatusCode = 200
        responseStatusCodes = []
        responseData = Data(#"{"threads":[],"resultSizeEstimate":0}"#.utf8)
        threadListResponseData = nil
        threadGetResponseData = nil
        messageGetResponseData = nil
        attachmentResponseData = nil
        failAttachmentPayloadRequests = false
        expectedListMaxResults = nil
        expectedListPageToken = nil
        expectedListQuery = nil
    }
}

private func decodedRawMessage(_ raw: String) throws -> String {
    let data = try #require(dataFromBase64URLString(raw))
    return try #require(String(data: data, encoding: .utf8))
}

private func mimeLineEndingsAreCRLF(_ value: String) -> Bool {
    let characters = Array(value)
    for index in characters.indices {
        let previousIsCR = index > characters.startIndex && characters[characters.index(before: index)] == "\r"
        if characters[index] == "\n",
           !previousIsCR {
            return false
        }
        if characters[index] == "\r" {
            let nextIndex = characters.index(after: index)
            if nextIndex == characters.endIndex || characters[nextIndex] != "\n" {
                return false
            }
        }
    }
    return true
}

private func attachmentBase64Lines(in message: String) -> [String] {
    let lines = message.components(separatedBy: "\r\n")
    guard let transferEncodingIndex = lines.firstIndex(of: "Content-Transfer-Encoding: base64") else {
        return []
    }
    let payloadStart = transferEncodingIndex + 2
    guard payloadStart < lines.endIndex else {
        return []
    }
    var output: [String] = []
    for line in lines[payloadStart...] {
        if line.hasPrefix("--") {
            break
        }
        output.append(line)
    }
    return output.filter { !$0.isEmpty }
}

func requireMailGatewayError(_ operation: () throws -> Void) throws -> MailGatewayError {
    do {
        try operation()
        throw ExpectedMailGatewayError(description: "Expected MailGatewayError, but operation succeeded")
    } catch let error as MailGatewayError {
        return error
    } catch {
        throw ExpectedMailGatewayError(description: "Expected MailGatewayError, got \(error)")
    }
}
