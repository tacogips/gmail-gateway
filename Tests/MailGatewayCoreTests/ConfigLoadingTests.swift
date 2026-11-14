import Foundation
@testable import MailGatewayCore
import Testing

@Test func configLoadRejectsCredentialEnvironmentSuffixCollisions() throws {
    let paths = temporaryConfigPaths()
    defer {
        try? FileManager.default.removeItem(atPath: paths.root)
    }
    try writeConfigFixture(
        paths: paths,
        credentials: [
            TestCredentialFixture("gmail-personal", tokenStorePath: "tokens/one.json", clientSecretPath: "client-one.json"),
            TestCredentialFixture("gmail.personal", tokenStorePath: "tokens/two.json", clientSecretPath: "client-two.json")
        ],
        accounts: [
            ("personal", "gmail-personal"),
            ("work", "gmail.personal")
        ]
    )

    let error = try requireMailGatewayError {
        _ = try MailGatewayConfigLoader.loadConfig(configPath: paths.root + "/config.toml", environment: [:])
    }

    #expect(error.code == .configInvalid)
    #expect(error.message.contains("environment variable suffix"))
}

@Test func cachePruneDoesNotRequireUnreadableOAuthClientSecret() throws {
    let paths = temporaryConfigPaths()
    defer {
        try? FileManager.default.removeItem(atPath: paths.root)
    }
    try writeConfigFixture(
        paths: paths,
        credentials: [
            TestCredentialFixture(
                "gmail-personal",
                tokenStorePath: "tokens/personal.json",
                clientSecretPath: "missing-client.json"
            )
        ],
        accounts: [("personal", "gmail-personal")]
    )

    let pruneResult = MailGatewayCLI().run(
        arguments: ["cache", "prune", "--config", paths.root + "/config.toml", "--account", "personal"],
        environment: [:]
    )
    #expect(pruneResult.exitCode == MailGatewayExitCode.success.rawValue)

    let validateResult = MailGatewayCLI().run(
        arguments: ["config", "validate", "--config", paths.root + "/config.toml"],
        environment: [:]
    )
    #expect(validateResult.exitCode == MailGatewayExitCode.configurationError.rawValue)
    #expect(validateResult.stderr.contains("oauth_client_secret_path is not readable"))
}

@Test func tomlSubsetAcceptsTrailingCommentsAndDecodesBasicStringEscapes() throws {
    let paths = temporaryConfigPaths()
    defer {
        try? FileManager.default.removeItem(atPath: paths.root)
    }
    try writeConfigSource(
        paths: paths,
        source: """
        [storage] # storage comment
        cache_dir = "cache # literal" # trailing comment
        attachment_dir = "attachments\\\\root"
        allowed_send_attachment_roots = ["send", "send # hash", "tab\\troot"] # array comment

        [[credentials]]
        id = "gmail-personal"
        provider = "gmail"
        access_mode = "read"
        oauth_client_secret_path = "secrets/client\\\"quoted\\\".json"
        token_store_path = "tokens/personal\\nline.json"

        [[accounts]]
        id = "personal"
        provider = "gmail"
        email_address = "person@example.com"
        credential_id = "gmail-personal"
        default_label_ids = ["INBOX", "Label # not comment", "Line\\nBreak"]
        """
    )

    let config = try MailGatewayConfigLoader.loadConfig(configPath: paths.root + "/config.toml", environment: [:])
    let account = try #require(config.accounts.first)
    let credential = try #require(config.credentials.first)

    #expect(config.storage.cacheDir.hasSuffix("cache # literal"))
    #expect(config.storage.attachmentDir.hasSuffix("attachments\\root"))
    #expect(config.storage.allowedSendAttachmentRoots.contains { $0.hasSuffix("send # hash") })
    #expect(config.storage.allowedSendAttachmentRoots.contains { $0.hasSuffix("tab\troot") })
    #expect(credential.oauthClientSecretPath.hasSuffix("secrets/client\"quoted\".json"))
    #expect(credential.tokenStorePath.hasSuffix("tokens/personal\nline.json"))
    #expect(account.defaultLabelIds == ["INBOX", "Label # not comment", "Line\nBreak"])
}

@Test func tomlSubsetRejectsUnsupportedStringEscapes() throws {
    let paths = temporaryConfigPaths()
    defer {
        try? FileManager.default.removeItem(atPath: paths.root)
    }
    try writeConfigSource(
        paths: paths,
        source: """
        [storage]
        cache_dir = "cache\\x"
        attachment_dir = "attachments"
        allowed_send_attachment_roots = ["send"]
        """
    )

    let error = try requireMailGatewayError {
        _ = try MailGatewayConfigLoader.loadConfig(configPath: paths.root + "/config.toml", environment: [:])
    }

    #expect(error.code == .configInvalid)
    #expect(error.message.contains("unsupported string escape"))
}

@Test func tomlSubsetRejectsUnterminatedStrings() throws {
    let paths = temporaryConfigPaths()
    defer {
        try? FileManager.default.removeItem(atPath: paths.root)
    }
    try writeConfigSource(
        paths: paths,
        source: """
        [storage]
        cache_dir = "cache
        attachment_dir = "attachments"
        allowed_send_attachment_roots = ["send"]
        """
    )

    let error = try requireMailGatewayError {
        _ = try MailGatewayConfigLoader.loadConfig(configPath: paths.root + "/config.toml", environment: [:])
    }

    #expect(error.code == .configInvalid)
    #expect(error.message.contains("unterminated string"))
}

@Test func configLoadRejectsInvalidAccountEmailAddresses() throws {
    let invalidEmailAddresses = [
        "@example.com",
        "person@",
        "personexample.com",
        "person@@example.com",
        "person @example.com",
        "person@example.com\nInjected: header",
        "person@example",
        "person@.example.com",
        "person@example.com.",
        "person@example..com",
        ".person@example.com",
        "person.@example.com"
    ]

    for emailAddress in invalidEmailAddresses {
        let paths = temporaryConfigPaths()
        defer {
            try? FileManager.default.removeItem(atPath: paths.root)
        }
        try writeSingleAccountConfig(paths: paths, emailAddress: emailAddress)

        let error = try requireMailGatewayError {
            _ = try MailGatewayConfigLoader.loadConfig(configPath: paths.root + "/config.toml", environment: [:])
        }

        #expect(error.code == .configInvalid)
        #expect(error.message.contains("accounts[0].email_address"))
    }
}

@Test func configLoadAcceptsValidAccountEmailAddress() throws {
    let paths = temporaryConfigPaths()
    defer {
        try? FileManager.default.removeItem(atPath: paths.root)
    }
    try writeSingleAccountConfig(paths: paths, emailAddress: "person@example.com")

    let config = try MailGatewayConfigLoader.loadConfig(configPath: paths.root + "/config.toml", environment: [:])

    #expect(config.accounts.first?.emailAddress == "person@example.com")
}

@Test func missingDefaultConfigMarksFallbackAccount() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mail-gateway-default-tests-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let environment = [
        "XDG_CONFIG_HOME": root.appendingPathComponent("config-home", isDirectory: true).path,
        "XDG_DATA_HOME": root.appendingPathComponent("data-home", isDirectory: true).path,
        "XDG_CACHE_HOME": root.appendingPathComponent("cache-home", isDirectory: true).path
    ]
    let config = try MailGatewayConfigLoader.loadConfig(environment: environment)
    let account = try #require(config.accounts.first)
    let validation = try MailGatewayConfigLoader.validateConfig(environment: environment)
    let projected = try #require(MailGatewayService(config: config).graphQLAccounts(sendEnabled: true).first)
    let capabilities = try #require(projected["capabilities"] as? [String: Any])

    #expect(account.isFallback)
    #expect(validation["fallbackConfig"] as? Bool == true)
    #expect(projected["isFallback"] as? Bool == true)
    #expect(capabilities["isFallback"] as? Bool == true)
    #expect(capabilities["canSend"] as? Bool == false)
}

@Test func fallbackAccountCannotSendEvenWithReadSendCredential() throws {
    let paths = temporaryConfigPaths()
    defer {
        try? FileManager.default.removeItem(atPath: paths.root)
    }
    let config = MailGatewayConfig(
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
                accessMode: .readSend,
                oauthClientSecretPath: paths.root + "/client.json",
                oauthClientSecretJSON: nil,
                tokenStorePath: paths.root + "/token.json",
                tokenStoreJSON: nil
            )
        ],
        accounts: [
            AccountConfig(
                id: "personal",
                provider: .gmail,
                emailAddress: "personal@example.invalid",
                credentialId: "gmail-personal",
                defaultLabelIds: ["INBOX"],
                isFallback: true
            )
        ]
    )
    let input = OutboundMailInput(
        accountId: "personal",
        to: ["recipient@example.com"],
        textBody: "Body"
    )

    let error = try requireMailGatewayError {
        _ = try MailGatewayWriteService(config: config).sendMessage(input: input, mode: .directSend)
    }

    #expect(error.code == .configInvalid)
    #expect(error.message.contains("Fallback account"))
}

private struct TestCredentialFixture {
    let id: String
    let tokenStorePath: String
    let clientSecretPath: String

    init(_ id: String, tokenStorePath: String, clientSecretPath: String) {
        self.id = id
        self.tokenStorePath = tokenStorePath
        self.clientSecretPath = clientSecretPath
    }
}

private func writeConfigFixture(
    paths: TestConfigPaths,
    credentials: [TestCredentialFixture],
    accounts: [(id: String, credentialId: String)]
) throws {
    try FileManager.default.createDirectory(atPath: paths.root, withIntermediateDirectories: true, attributes: nil)
    let credentialTables = credentials.map { credential in
        """
        [[credentials]]
        id = "\(credential.id)"
        provider = "gmail"
        access_mode = "read"
        oauth_client_secret_path = "\(credential.clientSecretPath)"
        token_store_path = "\(credential.tokenStorePath)"
        """
    }.joined(separator: "\n")
    let accountTables = accounts.map { account in
        """
        [[accounts]]
        id = "\(account.id)"
        provider = "gmail"
        email_address = "\(account.id)@example.com"
        credential_id = "\(account.credentialId)"
        default_label_ids = ["INBOX"]
        """
    }.joined(separator: "\n")
    let source = """
    [storage]
    cache_dir = "cache"
    attachment_dir = "attachments"
    allowed_send_attachment_roots = ["send"]

    \(credentialTables)

    \(accountTables)
    """
    try writeConfigSource(paths: paths, source: source)
}

private func writeConfigSource(paths: TestConfigPaths, source: String) throws {
    try FileManager.default.createDirectory(atPath: paths.root, withIntermediateDirectories: true, attributes: nil)
    try Data(source.utf8).write(to: URL(fileURLWithPath: paths.root).appendingPathComponent("config.toml"))
}

private func writeSingleAccountConfig(paths: TestConfigPaths, emailAddress: String) throws {
    try writeConfigSource(
        paths: paths,
        source: """
        [storage]
        cache_dir = "cache"
        attachment_dir = "attachments"
        allowed_send_attachment_roots = ["send"]

        [[credentials]]
        id = "gmail-personal"
        provider = "gmail"
        access_mode = "read"
        oauth_client_secret_path = "client.json"
        token_store_path = "token.json"

        [[accounts]]
        id = "personal"
        provider = "gmail"
        email_address = "\(tomlBasicStringEscaped(emailAddress))"
        credential_id = "gmail-personal"
        default_label_ids = ["INBOX"]
        """
    )
}

private func tomlBasicStringEscaped(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}
