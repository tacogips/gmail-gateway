import Foundation
@testable import GmailGatewayCore
import XCTest

final class DefaultTokenMigrationTests: XCTestCase {
    func testXDGDefaultsAndAbsoluteOverrides() throws {
        let baseline = GmailGatewayConfigLoader.resolveDefaultCredentialDirectory(environment: [:])
        XCTAssertTrue(baseline.hasSuffix("/.local/state/gmail-gateway/credentials"))
        let config = GmailGatewayConfigLoader.resolveDefaultConfigPath(environment: [:])
        XCTAssertTrue(config.hasSuffix("/.config/gmail-gateway/config.toml"))
        for invalid in ["", "relative", "~/state", "  "] {
            XCTAssertEqual(GmailGatewayConfigLoader.resolveDefaultCredentialDirectory(environment: ["XDG_STATE_HOME": invalid]), baseline)
            XCTAssertEqual(GmailGatewayConfigLoader.resolveDefaultConfigPath(environment: ["XDG_CONFIG_HOME": invalid]), config)
        }
        XCTAssertEqual(GmailGatewayConfigLoader.resolveDefaultCredentialDirectory(environment: ["XDG_STATE_HOME": "/xdg-state"]),
                       "/xdg-state/gmail-gateway/credentials")
        XCTAssertEqual(GmailGatewayConfigLoader.resolveDefaultConfigPath(environment: ["XDG_CONFIG_HOME": "/xdg-config"]),
                       "/xdg-config/gmail-gateway/config.toml")
    }

    func testMigrationPreservesTokenAndPrivatePermissions() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.writeLegacy()
        try migrateGmailDefaultTokenStore(fixture.credential)
        XCTAssertEqual(try Data(contentsOf: fixture.state), fixture.token)
        XCTAssertEqual(try Data(contentsOf: fixture.legacy), fixture.token)
        XCTAssertEqual(try permissions(fixture.state), 0o600)
        XCTAssertEqual(try permissions(fixture.state.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try permissions(fixture.marker), 0o600)
        try migrateGmailDefaultTokenStore(fixture.credential)
        XCTAssertEqual(try Data(contentsOf: fixture.state), fixture.token)
    }

    func testExistingStateWinsAndRevokeNeverResurrectsLegacy() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.writeLegacy()
        try FileManager.default.createDirectory(at: fixture.state.deletingLastPathComponent(), withIntermediateDirectories: true)
        let newer = Data("newer-state".utf8)
        try newer.write(to: fixture.state)
        try migrateGmailDefaultTokenStore(fixture.credential)
        XCTAssertEqual(try Data(contentsOf: fixture.state), newer)
        let service = GmailGatewayService(config: fixture.config)
        _ = try service.revokeAuth(credentialId: fixture.credential.id)
        try migrateGmailDefaultTokenStore(fixture.credential)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.legacy.path))
    }

    func testNoCredentialsCreatesNoState() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try migrateGmailDefaultTokenStore(fixture.credential)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.deletingLastPathComponent().path))
    }

    func testInterruptedAfterPublishRecoversAndRevokeIsDurable() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.writeLegacy()
        XCTAssertThrowsError(try migrateGmailDefaultTokenStore(fixture.credential, beforeMarker: { throw POSIXError(.EIO) }))
        XCTAssertEqual(try Data(contentsOf: fixture.state), fixture.token)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path))
        try migrateGmailDefaultTokenStore(fixture.credential)
        _ = try GmailGatewayService(config: fixture.config).revokeAuth(credentialId: fixture.credential.id)
        try migrateGmailDefaultTokenStore(fixture.credential)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.marker.path))
    }

    func testLoaderAssignsMigrationOnlyToHistoricalFallback() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let environment = ["XDG_CONFIG_HOME": fixture.root.appendingPathComponent("config-home").path,
                           "XDG_STATE_HOME": fixture.root.appendingPathComponent("state-home").path]
        let loaded = try GmailGatewayConfigLoader.loadConfig(environment: environment)
        XCTAssertEqual(loaded.credentials[0].legacyDefaultTokenStorePath,
                       fixture.root.appendingPathComponent("config-home/gmail-gateway/tokens/gmail-personal.json").path)
        XCTAssertEqual(loaded.credentials[0].tokenStorePath,
                       fixture.root.appendingPathComponent("state-home/gmail-gateway/credentials/gmail-personal.json").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("state-home").path))
    }

    func testPersistentResolverUsesMigratedFile() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.writeLegacy()
        let resolver = GmailAuthResolver(config: fixture.config, environment: [:], policy: .persistent(requiredAccessMode: .read),
                                         vault: GmailCredentialVault(store: TestSecureCredentialStore()))
        let resolved = try await resolver.resolveToken(for: fixture.credential)
        XCTAssertEqual(resolved?.source.value.accessToken, "test-token")
        XCTAssertEqual(resolved?.source.kind, .synthesizedDefault)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.marker.path))
    }

    func testVaultProfileNeverTriggersLegacyMigration() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.writeLegacy()
        let vault = GmailCredentialVault(store: TestSecureCredentialStore())
        for token in [nil, try coherentToken(client: testClient())] {
            try await vault.replaceProfile(testProfile(client: testClient(), token: token))
            let resolver = GmailAuthResolver(config: fixture.config, environment: [:], policy: .persistent(requiredAccessMode: .read), vault: vault)
            let resolved = try await resolver.resolveToken(for: fixture.credential)
            XCTAssertEqual(resolved?.source.kind, token == nil ? nil : .secureVault)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path))
        }
    }

    func testOverridesNeverMigrate() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.writeLegacy()
        for source in [GmailCredentialSourceKind.configuredPath, .environmentPath, .relocatedPath, .secureVault] {
            try migrateGmailDefaultTokenStore(fixture.makeCredential(source: source))
        }
        try migrateGmailDefaultTokenStore(fixture.makeCredential(json: try XCTUnwrap(String(bytes: fixture.token, encoding: .utf8))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path))
    }

    func testInvalidLegacyTokenFailsWithoutPublishing() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.writeLegacy(Data("invalid-json".utf8))
        XCTAssertThrowsError(try migrateGmailDefaultTokenStore(fixture.credential))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path))
    }

    func testLegacySymlinkAndHardlinkAreRejected() throws {
        for hardlink in [false, true] {
            let fixture = try Fixture()
            defer { fixture.clean() }
            let target = fixture.root.appendingPathComponent("outside.json")
            try fixture.token.write(to: target)
            try FileManager.default.createDirectory(at: fixture.legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
            if hardlink {
                try FileManager.default.linkItem(at: target, to: fixture.legacy)
            } else {
                try FileManager.default.createSymbolicLink(at: fixture.legacy, withDestinationURL: target)
            }
            XCTAssertThrowsError(try migrateGmailDefaultTokenStore(fixture.credential))
            XCTAssertEqual(try Data(contentsOf: target), fixture.token)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.path))
        }
    }

    func testStateParentSymlinkIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.writeLegacy()
        let target = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.state.deletingLastPathComponent(), withDestinationURL: target)
        XCTAssertThrowsError(try migrateGmailDefaultTokenStore(fixture.credential))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}

private struct Fixture {
    let root: URL
    let token = Data("{\"accessMode\":\"read\",\"accessToken\":\"test-token\"}".utf8)
    var legacy: URL { root.appendingPathComponent("config/tokens/gmail-personal.json") }
    var state: URL { root.appendingPathComponent("credentials/gmail-personal.json") }
    var marker: URL { URL(fileURLWithPath: state.path + ".migration-complete") }
    var credential: CredentialConfig { makeCredential() }
    var config: GmailGatewayConfig {
        GmailGatewayConfig(configPath: root.appendingPathComponent("config/config.toml").path,
                           storage: StorageConfig(cacheDir: root.path, attachmentDir: root.path, allowedSendAttachmentRoots: []),
                           credentials: [credential], accounts: [])
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeCredential(source: GmailCredentialSourceKind = .synthesizedDefault, json: String? = nil) -> CredentialConfig {
        CredentialConfig(id: "gmail-personal", provider: .gmail, accessMode: .read,
                         oauthClientSecretPath: root.appendingPathComponent("client.json").path, oauthClientSecretJSON: nil,
                         tokenStorePath: state.path, tokenStoreJSON: json, tokenStoreSource: source,
                         legacyDefaultTokenStorePath: legacy.path)
    }

    func writeLegacy(_ data: Data? = nil) throws {
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data ?? token).write(to: legacy)
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}
