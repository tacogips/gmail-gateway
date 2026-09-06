import Foundation
@testable import GmailGatewayCore
import XCTest

final class PersistentAuthSourceMatrixTests: XCTestCase {
    func testCoherentSourcePairsResolveAndHydrateWithoutTransport() async throws {
        let cases = PersistentAuthSourcePair.allCombinations
        TestGmailRequestCaptureProtocol.reset()
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }

        for sourceCase in cases {
            let fixture = try await PersistentAuthSourceFixture.make(sourceCase: sourceCase)
            defer { fixture.remove() }

            let resolvedClient = try await fixture.resolver.resolveClient(for: fixture.credential)
            let resolvedToken = try await fixture.resolver.resolveToken(for: fixture.credential)
            XCTAssertEqual(resolvedClient?.kind.rawValue, sourceCase.expectedClientKind.rawValue, sourceCase.name)
            XCTAssertEqual(resolvedToken?.source.kind.rawValue, sourceCase.token.resolvedKind.rawValue, sourceCase.name)

            let hydrated = try await fixture.coordinator.hydratedConfig()
            XCTAssertNotNil(hydrated.credentials.first?.oauthClientSecretJSON, sourceCase.name)
            XCTAssertNotNil(hydrated.credentials.first?.tokenStoreJSON, sourceCase.name)
        }

        XCTAssertTrue(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty)
    }

    func testSelectedMismatchedTokenSourcesRejectBeforeTransportAndDoNotFallBackToVault() async throws {
        let cases = PersistentAuthSourcePair.allCombinations
        TestGmailRequestCaptureProtocol.reset()
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }

        for sourceCase in cases {
            let fixture = try await PersistentAuthSourceFixture.make(
                sourceCase: sourceCase,
                selectedTokenFingerprint: "mismatched-client",
                seedLowerPriorityVaultToken: sourceCase.token.hasLowerPriorityVaultFallback
            )
            defer { fixture.remove() }

            do {
                _ = try await fixture.coordinator.hydratedConfig()
                XCTFail("Expected selected \(sourceCase.name) token to reject")
            } catch let error as GmailGatewayError {
                XCTAssertEqual(error.code.rawValue, GmailGatewayErrorCode.authRequired.rawValue, sourceCase.name)
            }
        }

        XCTAssertTrue(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty)
    }

    func testExplicitInvalidClientSourceRejectsBeforeVaultFallbackOrTransport() async throws {
        let fixture = try await PersistentAuthSourceFixture.make(
            sourceCase: .init(name: "invalid environment client JSON", client: .environmentJSON, token: .vault),
            selectedClientJSON: "not-json"
        )
        defer { fixture.remove() }
        TestGmailRequestCaptureProtocol.reset()
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }

        do {
            _ = try await fixture.coordinator.hydratedConfig()
            XCTFail("Expected invalid explicit client to reject")
        } catch let error as GmailGatewayError {
            XCTAssertEqual(error.code.rawValue, GmailGatewayErrorCode.configInvalid.rawValue)
        }
        XCTAssertTrue(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty)
    }

    func testLegacyMetadataReLoginUpgradesSameWritableFileDestination() async throws {
        TestGmailRequestCaptureProtocol.reset()
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }
        for missingMetadata in ["scope", "fingerprint"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let tokenPath = root.appendingPathComponent("legacy-\(missingMetadata).json").path
            let client = testClient()
            let legacyToken = GmailOAuthTokenStore(
                accessMode: .read,
                accessToken: "legacy-access-token",
                refreshToken: "legacy-refresh-token",
                tokenType: "Bearer",
                scope: missingMetadata == "scope" ? nil : gmailScopes(accessMode: .read).joined(separator: " "),
                expiresAt: nil,
                emailAddress: nil,
                clientFingerprint: missingMetadata == "fingerprint" ? nil : try gmailOAuthClientFingerprint(client)
            )
            let originalData = try JSONEncoder().encode(legacyToken)
            try originalData.write(to: URL(fileURLWithPath: tokenPath))
            let config = try persistentConfiguredTokenPathConfig(tokenPath: tokenPath)
            let upgradedLoginToken = GmailOAuthTokenStore(
                accessMode: .read,
                accessToken: "upgraded-access-token",
                refreshToken: "upgraded-refresh-token",
                tokenType: "Bearer",
                scope: gmailScopes(accessMode: .read).joined(separator: " "),
                expiresAt: nil,
                emailAddress: nil,
                clientFingerprint: nil
            )
            let coordinator = GmailAuthCoordinator(
                config: config,
                environment: [:],
                policy: .persistent(requiredAccessMode: .read),
                store: TestSecureCredentialStore(),
                loginResult: { _, _ in
                    GmailOAuthLoginResult(tokenStore: upgradedLoginToken, redirectURI: "http://127.0.0.1:1/oauth2callback")
                }
            )
            TestGmailRequestCaptureProtocol.reset()

            let status = try await coordinator.status(credentialId: "gmail-personal")
            XCTAssertEqual(status["tokenState"] as? String, AuthState.unknown.rawValue, missingMetadata)
            do {
                _ = try await coordinator.hydratedConfig()
                XCTFail("Expected missing \(missingMetadata) metadata to require re-login")
            } catch let error as GmailGatewayError {
                XCTAssertEqual(error.code.rawValue, GmailGatewayErrorCode.authRequired.rawValue, missingMetadata)
                XCTAssertEqual(error.exitCode, .graphqlExecutionError, missingMetadata)
            }
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: tokenPath)), originalData, missingMetadata)
            XCTAssertTrue(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty, missingMetadata)

            let login = try await coordinator.login(
                credentialId: "gmail-personal",
                options: GmailOAuthLoginOptions(openBrowser: false)
            )
            let upgraded = try JSONDecoder().decode(
                GmailOAuthTokenStore.self,
                from: Data(contentsOf: URL(fileURLWithPath: tokenPath))
            )
            XCTAssertEqual(login["persistenceBackend"] as? String, "FILE", missingMetadata)
            XCTAssertEqual(upgraded.scope, gmailScopes(accessMode: .read).joined(separator: " "), missingMetadata)
            XCTAssertEqual(upgraded.clientFingerprint, try gmailOAuthClientFingerprint(client), missingMetadata)
            _ = try await coordinator.hydratedConfig()
            XCTAssertTrue(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty, missingMetadata)
        }
    }
}

private struct PersistentAuthSourcePair {
    let name: String
    let client: PersistentAuthSourceLocation
    let token: PersistentAuthSourceLocation

    static let allCombinations = PersistentAuthSourceLocation.clientLocations.flatMap { client in
        PersistentAuthSourceLocation.tokenLocations.map { token in
            PersistentAuthSourcePair(
                name: "\(client.label) client with \(token.label) token",
                client: client,
                token: token
            )
        }
    }

    var expectedClientKind: GmailCredentialSourceKind {
        client == .synthesizedFile && token == .vault ? .secureVault : client.resolvedKind
    }
}

private enum PersistentAuthSourceLocation: Equatable {
    case environmentJSON
    case environmentPath
    case configuredPath
    case relocatedPath
    case vault
    case synthesizedFile

    static let clientLocations: [PersistentAuthSourceLocation] = [
        .environmentJSON, .environmentPath, .configuredPath, .vault, .synthesizedFile
    ]

    static let tokenLocations: [PersistentAuthSourceLocation] = [
        .environmentJSON, .environmentPath, .configuredPath, .relocatedPath, .vault, .synthesizedFile
    ]

    var label: String {
        switch self {
        case .environmentJSON: "environment JSON"
        case .environmentPath: "environment path"
        case .configuredPath: "configured path"
        case .relocatedPath: "relocated path"
        case .vault: "vault"
        case .synthesizedFile: "synthesized path"
        }
    }

    var hasLowerPriorityVaultFallback: Bool {
        switch self {
        case .environmentJSON, .environmentPath, .configuredPath, .relocatedPath:
            true
        case .vault, .synthesizedFile:
            false
        }
    }

    var sourceKind: GmailCredentialSourceKind {
        switch self {
        case .environmentJSON, .synthesizedFile, .vault:
            .synthesizedDefault
        case .environmentPath:
            .environmentPath
        case .configuredPath:
            .configuredPath
        case .relocatedPath:
            .relocatedPath
        }
    }

    var resolvedKind: GmailCredentialSourceKind {
        switch self {
        case .environmentJSON:
            .environmentJSON
        case .environmentPath:
            .environmentPath
        case .configuredPath:
            .configuredPath
        case .relocatedPath:
            .relocatedPath
        case .vault:
            .secureVault
        case .synthesizedFile:
            .synthesizedDefault
        }
    }

    var usesClientFile: Bool {
        switch self {
        case .environmentPath, .configuredPath, .synthesizedFile:
            true
        case .environmentJSON, .relocatedPath, .vault:
            false
        }
    }

    var usesTokenFile: Bool {
        switch self {
        case .environmentPath, .configuredPath, .relocatedPath, .synthesizedFile:
            true
        case .environmentJSON, .vault:
            false
        }
    }
}

private struct PersistentAuthSourceFixture {
    let root: URL
    let credential: CredentialConfig
    let resolver: GmailAuthResolver
    let coordinator: GmailAuthCoordinator

    static func make(
        sourceCase: PersistentAuthSourcePair,
        selectedTokenFingerprint: String? = nil,
        seedLowerPriorityVaultToken: Bool = false,
        selectedClientJSON: String? = nil
    ) async throws -> PersistentAuthSourceFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let client = testClient()
        let clientFingerprint = try gmailOAuthClientFingerprint(client)
        let inlineClientJSON = try selectedClientJSON ?? client.legacyJSON()
        let token = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "matrix-access-token",
            refreshToken: "matrix-refresh-token",
            tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "),
            expiresAt: nil,
            emailAddress: nil,
            clientFingerprint: selectedTokenFingerprint ?? clientFingerprint,
            schemaVersion: 1,
            provider: .gmail,
            credentialId: "gmail-personal"
        )
        let clientPath = root.appendingPathComponent("client.json")
        let tokenPath = root.appendingPathComponent("token.json")
        if sourceCase.client.usesClientFile {
            try client.legacyJSON().write(to: clientPath, atomically: true, encoding: .utf8)
        }
        if sourceCase.token.usesTokenFile {
            try JSONEncoder().encode(token).write(to: tokenPath)
        }
        let credential = CredentialConfig(
            id: "gmail-personal",
            provider: .gmail,
            accessMode: .read,
            oauthClientSecretPath: clientPath.path,
            oauthClientSecretJSON: sourceCase.client == .environmentJSON ? inlineClientJSON : nil,
            tokenStorePath: tokenPath.path,
            tokenStoreJSON: sourceCase.token == .environmentJSON ? try stringJSON(token) : nil,
            oauthClientSecretSource: sourceCase.client.sourceKind,
            tokenStoreSource: sourceCase.token.sourceKind
        )
        let config = GmailGatewayConfig(
            configPath: root.appendingPathComponent("config.toml").path,
            storage: StorageConfig(cacheDir: root.path, attachmentDir: root.path, allowedSendAttachmentRoots: []),
            credentials: [credential],
            accounts: [AccountConfig(
                id: "personal",
                provider: .gmail,
                emailAddress: "personal@example.invalid",
                credentialId: credential.id,
                defaultLabelIds: [],
                isFallback: true
            )]
        )
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        if sourceCase.client == .vault || sourceCase.token == .vault || seedLowerPriorityVaultToken {
            let vaultToken = sourceCase.token == .vault || seedLowerPriorityVaultToken ? try coherentToken(client: client) : nil
            if sourceCase.token == .vault, selectedTokenFingerprint != nil {
                let invalidVaultToken = GmailOAuthTokenStore(
                    accessMode: token.accessMode,
                    accessToken: token.accessToken,
                    refreshToken: token.refreshToken,
                    tokenType: token.tokenType,
                    scope: token.scope,
                    expiresAt: token.expiresAt,
                    emailAddress: token.emailAddress,
                    clientFingerprint: selectedTokenFingerprint,
                    schemaVersion: token.schemaVersion,
                    provider: token.provider,
                    credentialId: token.credentialId
                )
                await store.put(
                    try JSONEncoder().encode(testProfile(client: client, token: invalidVaultToken)),
                    account: "gmail-profile:gmail-personal:read"
                )
            } else {
                try await vault.replaceProfile(testProfile(client: client, token: vaultToken))
            }
        }
        let policy = GmailAuthPolicy.persistent(requiredAccessMode: .read)
        return PersistentAuthSourceFixture(
            root: root,
            credential: credential,
            resolver: GmailAuthResolver(config: config, environment: [:], policy: policy, vault: vault),
            coordinator: GmailAuthCoordinator(config: config, environment: [:], policy: policy, store: store)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func stringJSON(_ token: GmailOAuthTokenStore) throws -> String {
    try XCTUnwrap(String(data: JSONEncoder().encode(token), encoding: .utf8))
}
