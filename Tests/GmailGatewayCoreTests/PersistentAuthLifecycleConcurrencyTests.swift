import Foundation
@_spi(Testing) @testable import GmailGatewayCore
import XCTest

final class PersistentAuthLifecycleConcurrencyTests: XCTestCase {
    func testIndependentCoordinatorsSerializeRefreshBeforeRevoke() async throws {
        let fixture = try LifecycleFileFixture(expired: true)
        defer { fixture.remove() }
        let gate = LifecyclePhaseGate(waitingFor: .refreshResolved)
        let lockContentions = LifecycleLockContentionGate()
        let refresher = GmailAuthCoordinator(
            config: fixture.config,
            environment: fixture.environment,
            policy: .persistent(requiredAccessMode: .read),
            store: TestSecureCredentialStore(),
            refreshToken: { _, _ in try coherentToken(client: fixture.client) },
            lifecyclePhase: { phase in await gate.observe(phase) },
            lifecycleLockEvent: { event in lockContentions.observe(event) }
        )
        let revoker = GmailAuthCoordinator(
            config: fixture.config,
            environment: fixture.environment,
            policy: .persistent(requiredAccessMode: .read),
            store: TestSecureCredentialStore(),
            lifecycleLockEvent: { event in lockContentions.observe(event) }
        )

        let refresh = Task.detached { try await refresher.hydratedConfig() }
        await gate.waitForEntry()
        let revoke: Task<Void, Error> = Task.detached {
            _ = try await revoker.revoke(credentialId: "gmail-personal", confirmedCredentialId: "gmail-personal")
        }
        await lockContentions.waitForCount(1)
        await gate.release()
        _ = try await refresh.value
        _ = try await revoke.value

        XCTAssertNil(try readPersistentTokenFileData(fixture.path, credential: fixture.credential, exitCode: .authenticationBootstrapError))
    }

    func testIndependentCoordinatorsSerializeRevokeBeforeRefresh() async throws {
        let fixture = try LifecycleFileFixture(expired: true)
        defer { fixture.remove() }
        let gate = LifecyclePhaseGate(waitingFor: .revokeReadyToCommit)
        let refreshes = RefreshCounter()
        let lockContentions = LifecycleLockContentionGate()
        let revoker = GmailAuthCoordinator(
            config: fixture.config,
            environment: fixture.environment,
            policy: .persistent(requiredAccessMode: .read),
            store: TestSecureCredentialStore(),
            lifecyclePhase: { phase in await gate.observe(phase) },
            lifecycleLockEvent: { event in lockContentions.observe(event) }
        )
        let refresher = GmailAuthCoordinator(
            config: fixture.config,
            environment: fixture.environment,
            policy: .persistent(requiredAccessMode: .read),
            store: TestSecureCredentialStore(),
            refreshToken: { _, _ in
                refreshes.increment()
                return try coherentToken(client: fixture.client)
            },
            lifecycleLockEvent: { event in lockContentions.observe(event) }
        )

        let revoke: Task<Void, Error> = Task.detached {
            _ = try await revoker.revoke(credentialId: "gmail-personal", confirmedCredentialId: "gmail-personal")
        }
        await gate.waitForEntry()
        let refresh = Task.detached { try await refresher.hydratedConfig() }
        await lockContentions.waitForCount(1)
        await gate.release()
        _ = try await revoke.value
        _ = try await refresh.value

        XCTAssertEqual(refreshes.count, 0)
        XCTAssertNil(try readPersistentTokenFileData(fixture.path, credential: fixture.credential, exitCode: .authenticationBootstrapError))
    }

    func testIndependentCoordinatorsSerializeReplaceSetupAfterLogin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = testClient()
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: nil))
        let gate = LifecyclePhaseGate(waitingFor: .loginDestinationResolved)
        let lockContentions = LifecycleLockContentionGate()
        let replacementClient = GmailOAuthClientRecord(
            kind: "installed", clientId: "replacement.apps.googleusercontent.com", clientSecret: "replacement-secret",
            projectId: "replacement-project", authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenEndpoint: "https://oauth2.googleapis.com/token", redirectURIs: ["http://127.0.0.1:8080/oauth2callback"]
        )
        let clientPath = root.appendingPathComponent("replacement-client.json")
        try replacementClient.legacyJSON().data(using: .utf8)?.write(to: clientPath)
        let config = persistentConfig(tokenPath: root.appendingPathComponent("token.json").path, fallback: true)
        let loginCoordinator = GmailAuthCoordinator(
            config: config,
            environment: [:],
            policy: .persistent(requiredAccessMode: .read),
            store: store,
            loginResult: { _, _ in GmailOAuthLoginResult(tokenStore: try coherentToken(client: client), redirectURI: "http://127.0.0.1:1/oauth2callback") },
            lifecyclePhase: { phase in await gate.observe(phase) },
            lifecycleLockEvent: { event in lockContentions.observe(event) }
        )
        let setupCoordinator = GmailAuthCoordinator(
            config: config,
            environment: [:],
            policy: .persistent(requiredAccessMode: .read),
            store: store,
            lifecycleLockEvent: { event in lockContentions.observe(event) }
        )

        let login: Task<Void, Error> = Task.detached {
            _ = try await loginCoordinator.login(credentialId: "gmail-personal", options: GmailOAuthLoginOptions(openBrowser: false))
        }
        await gate.waitForEntry()
        let setup: Task<Void, Error> = Task.detached {
            _ = try await setupCoordinator.setup(
                credentialId: "gmail-personal",
                options: GmailOAuthSetupOptions(clientSecretPath: clientPath.path, replace: true, confirmedCredentialId: "gmail-personal")
            )
        }
        await lockContentions.waitForCount(1)
        await gate.release()
        _ = try await login.value
        _ = try await setup.value

        let final = try await vault.profile(credentialId: "gmail-personal", accessMode: .read)
        XCTAssertEqual(final?.client.clientId, replacementClient.clientId)
        XCTAssertNil(final?.token)
    }

    func testRefreshRejectsSymlinkSubstitutionAfterResolution() async throws {
        let fixture = try LifecycleFileFixture(expired: true)
        defer { fixture.remove() }
        let target = fixture.root.appendingPathComponent("refresh-target.json")
        let targetToken = try fixture.targetToken(accessToken: "refresh-target")
        try writeGmailOAuthTokenStore(targetToken, to: target.path, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
        let gate = LifecyclePhaseGate(waitingFor: .refreshResolved)
        let coordinator = GmailAuthCoordinator(
            config: fixture.config,
            environment: fixture.environment,
            policy: .persistent(requiredAccessMode: .read),
            store: TestSecureCredentialStore(),
            refreshToken: { _, _ in try coherentToken(client: fixture.client) },
            lifecyclePhase: { phase in await gate.observe(phase) }
        )

        let refresh = Task { try await coordinator.hydratedConfig() }
        await gate.waitForEntry()
        try fixture.replaceTokenWithSymlink(to: target)
        await gate.release()
        await XCTAssertThrowsErrorAsync { _ = try await refresh.value }
        XCTAssertEqual(try fixture.readToken(at: target).accessToken, targetToken.accessToken)
    }

    func testRevokeRejectsSymlinkSubstitutionAfterResolution() async throws {
        let fixture = try LifecycleFileFixture(expired: false)
        defer { fixture.remove() }
        let target = fixture.root.appendingPathComponent("revoke-target.json")
        let targetToken = try fixture.targetToken(accessToken: "revoke-target")
        try writeGmailOAuthTokenStore(targetToken, to: target.path, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
        let gate = LifecyclePhaseGate(waitingFor: .revokeReadyToCommit)
        let coordinator = GmailAuthCoordinator(
            config: fixture.config,
            environment: fixture.environment,
            policy: .persistent(requiredAccessMode: .read),
            store: TestSecureCredentialStore(),
            lifecyclePhase: { phase in await gate.observe(phase) }
        )

        let revoke: Task<Void, Error> = Task { _ = try await coordinator.revoke(credentialId: "gmail-personal", confirmedCredentialId: "gmail-personal") }
        await gate.waitForEntry()
        try fixture.replaceTokenWithSymlink(to: target)
        await gate.release()
        await XCTAssertThrowsErrorAsync { _ = try await revoke.value }
        XCTAssertEqual(try fixture.readToken(at: target).accessToken, targetToken.accessToken)
    }
}

private struct LifecycleFileFixture: @unchecked Sendable {
    let root: URL
    let path: String
    let client: GmailOAuthClientRecord
    let config: GmailGatewayConfig

    init(expired: Bool) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        path = root.appendingPathComponent("token.json").path
        client = testClient()
        config = try persistentConfiguredTokenPathConfig(tokenPath: path)
        var token = try coherentToken(client: client)
        if expired {
            token = GmailOAuthTokenStore(
                accessMode: token.accessMode,
                accessToken: token.accessToken,
                refreshToken: token.refreshToken,
                tokenType: token.tokenType,
                scope: token.scope,
                expiresAt: "2000-01-01T00:00:00Z",
                emailAddress: token.emailAddress,
                clientFingerprint: token.clientFingerprint,
                schemaVersion: token.schemaVersion,
                provider: token.provider,
                credentialId: token.credentialId
            )
        }
        try writeGmailOAuthTokenStore(token, to: path, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
    }

    var credential: CredentialConfig { config.credentials[0] }

    var environment: [String: String] {
        [
            GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
                credentialId: credential.id,
                valueKey: "oauth_client_secret_json"
            ): credential.oauthClientSecretJSON ?? ""
        ]
    }

    func targetToken(accessToken: String) throws -> GmailOAuthTokenStore {
        GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: accessToken,
            refreshToken: "target-refresh",
            tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "),
            expiresAt: nil,
            emailAddress: nil,
            clientFingerprint: try gmailOAuthClientFingerprint(client)
        )
    }

    func replaceTokenWithSymlink(to target: URL) throws {
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createSymbolicLink(at: URL(fileURLWithPath: path), withDestinationURL: target)
    }

    func readToken(at url: URL) throws -> GmailOAuthTokenStore {
        try JSONDecoder().decode(GmailOAuthTokenStore.self, from: Data(contentsOf: url))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor LifecyclePhaseGate {
    private let phase: GmailPersistentAuthLifecyclePhase
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(waitingFor phase: GmailPersistentAuthLifecyclePhase) {
        self.phase = phase
    }

    func observe(_ observed: GmailPersistentAuthLifecyclePhase) async {
        guard samePhase(observed, phase) else { return }
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitForEntry() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    private func samePhase(_ lhs: GmailPersistentAuthLifecyclePhase, _ rhs: GmailPersistentAuthLifecyclePhase) -> Bool {
        switch (lhs, rhs) {
        case (.revokeReadyToCommit, .revokeReadyToCommit),
             (.loginDestinationResolved, .loginDestinationResolved),
             (.refreshResolved, .refreshResolved):
            true
        default: false
        }
    }
}

private final class LifecycleLockContentionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func observe(_ event: GmailCredentialLifecycleLockEvent) {
        guard event == .contended else { return }
        lock.withLock { count += 1 }
    }

    func waitForCount(_ expectedCount: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while lock.withLock({ count < expectedCount }) {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for kernel-confirmed lifecycle-lock contention", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class RefreshCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
