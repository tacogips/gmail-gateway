import Foundation
@testable import GmailGatewayCore
import XCTest

final class PersistentAuthConfigValidationTests: XCTestCase {
    func testExactClientOnlyVaultProfileValidatesEveryPersistentExecutable() async throws {
        for (mode, accessMode) in persistentModes {
            let fixture = try PersistentConfigFixture(accessMode: accessMode)
            defer { fixture.remove() }
            let store = TestSecureCredentialStore()
            try await GmailCredentialVault(store: store).replaceProfile(validProfile(accessMode: accessMode))

            let result = await persistentCLI(mode: mode, accessMode: accessMode, store: store).runPersistent(
                arguments: ["config", "validate", "--config", fixture.configPath], environment: [:]
            )
            XCTAssertEqual(result.exitCode, GmailGatewayExitCode.success.rawValue)
        }
    }

    func testMissingMalformedClientlessUnavailableAndMismatchedVaultProfilesFailValidation() async throws {
        let mismatchedData = try JSONEncoder().encode(GmailCredentialProfileEnvelope(
            schemaVersion: 1,
            provider: .gmail,
            credentialId: "different-credential",
            accessMode: .read,
            expectedScopes: gmailScopes(accessMode: .read).sorted(),
            client: testClient(),
            token: nil
        ))
        let cases: [(String, @Sendable (TestSecureCredentialStore) async -> Void)] = [
            ("empty", { _ in }),
            ("malformed", { store in await store.put(Data("not-json".utf8), account: "gmail-profile:gmail-personal:read") }),
            ("clientless", { store in await store.put(Data(#"{"schemaVersion":1,"credentialId":"gmail-personal"}"#.utf8), account: "gmail-profile:gmail-personal:read") }),
            ("unavailable", { store in await store.failNextRead() }),
            ("identity-mismatched", { store in
                await store.put(mismatchedData, account: "gmail-profile:gmail-personal:read")
            })
        ]
        for (_, seed) in cases {
            let fixture = try PersistentConfigFixture(accessMode: .read)
            defer { fixture.remove() }
            let store = TestSecureCredentialStore()
            await seed(store)
            let result = await persistentCLI(mode: .reader, accessMode: .read, store: store).runPersistent(
                arguments: ["config", "validate", "--config", fixture.configPath], environment: [:]
            )
            XCTAssertEqual(result.exitCode, GmailGatewayExitCode.configurationError.rawValue)
            XCTAssertTrue(result.stderr.contains("no persistent Keychain client is available"))
        }
    }

    func testExplicitClientPathRemainsAuthoritativeWithoutVaultFallback() async throws {
        let fixture = try PersistentConfigFixture(accessMode: .read, explicitClient: true)
        defer { fixture.remove() }
        let clientURL = URL(fileURLWithPath: fixture.root).appendingPathComponent("explicit-client.json")
        try Data(try testClient().legacyJSON().utf8).write(to: clientURL)
        let store = TestSecureCredentialStore()
        await store.failNextRead()

        let result = await persistentCLI(mode: .reader, accessMode: .read, store: store).runPersistent(
            arguments: ["config", "validate", "--config", fixture.configPath], environment: [:]
        )
        XCTAssertEqual(result.exitCode, GmailGatewayExitCode.success.rawValue)
    }

    func testMalformedSelectedClientSourcesFailWithoutVaultFallback() async throws {
        let clientPathEnvironment = GmailGatewayConfigLoader.getCredentialPathEnvVarName(
            credentialId: "gmail-personal",
            pathKey: "oauth_client_secret_path"
        )
        let clientJSONEnvironment = GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
            credentialId: "gmail-personal",
            valueKey: "oauth_client_secret_json"
        )
        let cases: [MalformedClientSourceCase] = [
            MalformedClientSourceCase(name: "configured-path", environment: [:], prepare: { fixture in
                try Data("not-client-json".utf8).write(
                    to: URL(fileURLWithPath: fixture.root).appendingPathComponent("explicit-client.json")
                )
            }),
            MalformedClientSourceCase(
                name: "environment-path",
                environment: [clientPathEnvironment: "environment-client.json"],
                prepare: { fixture in
                    try Data(try testClient().legacyJSON().utf8).write(
                        to: URL(fileURLWithPath: fixture.root).appendingPathComponent("explicit-client.json")
                    )
                    try Data("not-client-json".utf8).write(
                        to: URL(fileURLWithPath: fixture.root).appendingPathComponent("environment-client.json")
                    )
                }
            ),
            MalformedClientSourceCase(
                name: "environment-json",
                environment: [clientJSONEnvironment: "not-client-json"],
                prepare: { fixture in
                    try Data(try testClient().legacyJSON().utf8).write(
                        to: URL(fileURLWithPath: fixture.root).appendingPathComponent("explicit-client.json")
                    )
                }
            )
        ]

        for testCase in cases {
            let fixture = try PersistentConfigFixture(accessMode: .read, explicitClient: true)
            defer { fixture.remove() }
            try testCase.prepare(fixture)
            let store = TestSecureCredentialStore()
            try await GmailCredentialVault(store: store).replaceProfile(validProfile(accessMode: .read))

            let result = await persistentCLI(mode: .reader, accessMode: .read, store: store).runPersistent(
                arguments: ["config", "validate", "--config", fixture.configPath], environment: testCase.environment
            )

            XCTAssertEqual(result.exitCode, GmailGatewayExitCode.configurationError.rawValue, testCase.name)
            let vaultReads = await store.dataReadCount()
            XCTAssertEqual(vaultReads, 0, testCase.name)
        }
    }

    func testMalformedEnvironmentClientSourcesFailInFallbackConfigWithoutVaultFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let clientPathEnvironment = GmailGatewayConfigLoader.getCredentialPathEnvVarName(
            credentialId: "gmail-personal",
            pathKey: "oauth_client_secret_path"
        )
        let clientJSONEnvironment = GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
            credentialId: "gmail-personal",
            valueKey: "oauth_client_secret_json"
        )
        let invalidPath = root.appendingPathComponent("environment-client.json")
        try Data("not-client-json".utf8).write(to: invalidPath)
        let cases = [
            ("environment-path", [clientPathEnvironment: invalidPath.path]),
            ("environment-json", [clientJSONEnvironment: "not-client-json"])
        ]

        for (name, selectedSource) in cases {
            let store = TestSecureCredentialStore()
            try await GmailCredentialVault(store: store).replaceProfile(validProfile(accessMode: .read))
            var environment = selectedSource
            environment["XDG_CONFIG_HOME"] = root.path

            let result = await persistentCLI(mode: .reader, accessMode: .read, store: store).runPersistent(
                arguments: ["config", "validate"], environment: environment
            )

            XCTAssertEqual(result.exitCode, GmailGatewayExitCode.configurationError.rawValue, name)
            let vaultReads = await store.dataReadCount()
            XCTAssertEqual(vaultReads, 0, name)
        }
    }

    func testSynthesizedClientValidationPrefersValidVaultOverMalformedFile() async throws {
        let fixture = try PersistentConfigFixture(accessMode: .read)
        defer { fixture.remove() }
        try writeSynthesizedClient("not-client-json", fixture: fixture)
        let store = TestSecureCredentialStore()
        try await GmailCredentialVault(store: store).replaceProfile(validProfile(accessMode: .read))

        let result = await persistentCLI(mode: .reader, accessMode: .read, store: store).runPersistent(
            arguments: ["config", "validate", "--config", fixture.configPath], environment: [:]
        )

        XCTAssertEqual(result.exitCode, GmailGatewayExitCode.success.rawValue)
    }

    func testSynthesizedClientValidationRejectsInvalidOrUnavailableVaultBeforeValidFile() async throws {
        for source in ["malformed", "unavailable"] {
            let fixture = try PersistentConfigFixture(accessMode: .read)
            defer { fixture.remove() }
            try writeSynthesizedClient(try testClient().legacyJSON(), fixture: fixture)
            let store = TestSecureCredentialStore()
            if source == "malformed" {
                await store.put(Data("not-json".utf8), account: "gmail-profile:gmail-personal:read")
            } else {
                await store.failNextRead()
            }

            let result = await persistentCLI(mode: .reader, accessMode: .read, store: store).runPersistent(
                arguments: ["config", "validate", "--config", fixture.configPath], environment: [:]
            )

            XCTAssertEqual(result.exitCode, GmailGatewayExitCode.configurationError.rawValue, source)
            let vaultReads = await store.dataReadCount()
            XCTAssertGreaterThan(vaultReads, 0, source)
        }
    }

    func testSynthesizedClientValidationUsesFileOnlyWhenVaultIsAbsent() async throws {
        let cases = [("valid-file", try testClient().legacyJSON(), GmailGatewayExitCode.success.rawValue),
                     ("invalid-file", "not-client-json", GmailGatewayExitCode.configurationError.rawValue)]
        for (name, clientJSON, expectedExitCode) in cases {
            let fixture = try PersistentConfigFixture(accessMode: .read)
            defer { fixture.remove() }
            try writeSynthesizedClient(clientJSON, fixture: fixture)
            let store = TestSecureCredentialStore()

            let result = await persistentCLI(mode: .reader, accessMode: .read, store: store).runPersistent(
                arguments: ["config", "validate", "--config", fixture.configPath], environment: [:]
            )

            XCTAssertEqual(result.exitCode, expectedExitCode, name)
        }
    }

    func testMixedAccessModeKeychainOnlyConfigValidatesFromReaderAndSender() async throws {
        for (mode, selectedAccessMode) in [
            (GmailGatewayCLIMode.reader, AccessMode.read),
            (.directSender, .readSend)
        ] {
            let fixture = try PersistentConfigFixture(
                accessMode: .read,
                additionalCredentials: [("gmail-send", .readSend)]
            )
            defer { fixture.remove() }
            let store = TestSecureCredentialStore()
            let vault = GmailCredentialVault(store: store)
            try await vault.replaceProfile(validProfile(accessMode: .read))
            try await vault.replaceProfile(validProfile(credentialId: "gmail-send", accessMode: .readSend))

            let result = await persistentCLI(mode: mode, accessMode: selectedAccessMode, store: store).runPersistent(
                arguments: ["config", "validate", "--config", fixture.configPath], environment: [:]
            )

            XCTAssertEqual(result.exitCode, GmailGatewayExitCode.success.rawValue, "\(mode)")
        }
    }

    func testPersistentValidationUsesOneImmutableLoadedConfigSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("config.toml")
        let clientURL = root.appendingPathComponent("client.json")
        try Data(try testClient().legacyJSON().utf8).write(to: clientURL)
        try Data(explicitConfig(clientPath: clientURL.path).utf8).write(to: configURL)
        let replacement = synthesizedConfig(credentialId: "gmail-replaced")
        let store = TestSecureCredentialStore()
        let cli = GmailGatewayCLI(
            mode: .reader,
            authPolicy: .persistent(requiredAccessMode: .read),
            secureCredentialStore: store,
            configurationLoaded: { _ in
                try? Data(replacement.utf8).write(to: configURL)
            }
        )

        let result = await cli.runPersistent(
            arguments: ["config", "validate", "--config", configURL.path], environment: [:]
        )

        XCTAssertEqual(result.exitCode, GmailGatewayExitCode.success.rawValue)
        let output = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(output["credentialIds"] as? [String], ["gmail-personal"])
        let vaultReads = await store.dataReadCount()
        XCTAssertEqual(vaultReads, 0)
    }
}

private let persistentModes: [(GmailGatewayCLIMode, AccessMode)] = [
    (.reader, .read), (.draftGateway, .readSend), (.directSender, .readSend)
]

private struct MalformedClientSourceCase {
    let name: String
    let environment: [String: String]
    let prepare: (PersistentConfigFixture) throws -> Void
}

private func persistentCLI(mode: GmailGatewayCLIMode, accessMode: AccessMode, store: TestSecureCredentialStore) -> GmailGatewayCLI {
    GmailGatewayCLI(mode: mode, authPolicy: .persistent(requiredAccessMode: accessMode), secureCredentialStore: store)
}

private func validProfile(
    credentialId: String = "gmail-personal",
    accessMode: AccessMode
) -> GmailCredentialProfileEnvelope {
    GmailCredentialProfileEnvelope(
        schemaVersion: 1,
        provider: .gmail,
        credentialId: credentialId,
        accessMode: accessMode,
        expectedScopes: gmailScopes(accessMode: accessMode).sorted(),
        client: testClient(),
        token: nil
    )
}

private func writeSynthesizedClient(_ contents: String, fixture: PersistentConfigFixture) throws {
    try Data(contents.utf8).write(
        to: URL(fileURLWithPath: fixture.root).appendingPathComponent("google-client.json")
    )
}

private func explicitConfig(clientPath: String) -> String {
    """
    [storage]
    cache_dir = "cache"
    attachment_dir = "attachments"
    allowed_send_attachment_roots = ["send"]

    [[credentials]]
    id = "gmail-personal"
    provider = "gmail"
    access_mode = "read"
    oauth_client_secret_path = "\(clientPath)"

    [[accounts]]
    id = "personal"
    provider = "gmail"
    email_address = "person@example.com"
    credential_id = "gmail-personal"
    default_label_ids = ["INBOX"]
    """
}

private func synthesizedConfig(credentialId: String) -> String {
    """
    [storage]
    cache_dir = "cache"
    attachment_dir = "attachments"
    allowed_send_attachment_roots = ["send"]

    [[credentials]]
    id = "\(credentialId)"
    provider = "gmail"
    access_mode = "read"

    [[accounts]]
    id = "personal"
    provider = "gmail"
    email_address = "person@example.com"
    credential_id = "\(credentialId)"
    default_label_ids = ["INBOX"]
    """
}

private struct PersistentConfigFixture {
    let root: String
    let configPath: String

    init(
        accessMode: AccessMode,
        explicitClient: Bool = false,
        additionalCredentials: [(String, AccessMode)] = []
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        root = directory.path
        configPath = directory.appendingPathComponent("config.toml").path
        let explicitLine = explicitClient ? "oauth_client_secret_path = \"explicit-client.json\"\n" : ""
        let credentials = [("gmail-personal", accessMode)] + additionalCredentials
        let credentialRecords = credentials.map { credentialId, credentialAccessMode in
            """
            [[credentials]]
            id = "\(credentialId)"
            provider = "gmail"
            access_mode = "\(credentialAccessMode.rawValue)"
            \(credentialId == "gmail-personal" ? explicitLine : "")
            """
        }.joined(separator: "\n")
        let accountRecords = credentials.enumerated().map { index, credential in
            """
            [[accounts]]
            id = "personal-\(index)"
            provider = "gmail"
            email_address = "person\(index)@example.com"
            credential_id = "\(credential.0)"
            default_label_ids = ["INBOX"]
            """
        }.joined(separator: "\n")
        let source = """
        [storage]
        cache_dir = "cache"
        attachment_dir = "attachments"
        allowed_send_attachment_roots = ["send"]

        \(credentialRecords)
        \(accountRecords)
        """
        try Data(source.utf8).write(to: URL(fileURLWithPath: configPath))
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }
}
