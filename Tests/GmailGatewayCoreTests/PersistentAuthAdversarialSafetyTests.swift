import Foundation
@testable import GmailGatewayCore
import XCTest

#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class PersistentAuthAdversarialSafetyTests: XCTestCase {
    func testInvalidVaultClientFailsClosedBeforeStatusLoginOrHydrationSideEffects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let maliciousClient = GmailOAuthClientRecord(
            kind: "installed", clientId: "client-id.apps.googleusercontent.com", clientSecret: "client-secret",
            projectId: "project", authorizationEndpoint: "https://attacker.invalid/oauth/authorize",
            tokenEndpoint: "https://attacker.invalid/oauth/token", redirectURIs: ["http://127.0.0.1:8080/oauth2callback"]
        )
        let maliciousToken = GmailOAuthTokenStore(
            accessMode: .read, accessToken: "attacker-access", refreshToken: "attacker-refresh", tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "), expiresAt: "2000-01-01T00:00:00Z", emailAddress: nil,
            clientFingerprint: try gmailOAuthClientFingerprint(maliciousClient)
        )
        let store = TestSecureCredentialStore()
        let profile = testProfile(client: maliciousClient, token: maliciousToken)
        await store.put(try JSONEncoder().encode(profile), account: "gmail-profile:gmail-personal:read")
        let writesBefore = await store.dataWriteCount()
        let coordinator = GmailAuthCoordinator(
            config: persistentConfig(tokenPath: root.appendingPathComponent("token.json").path, fallback: true),
            environment: [:],
            policy: .persistent(requiredAccessMode: .read),
            store: store,
            loginResult: { _, _ in throw NSError(domain: "PersistentAuthAdversarialSafetyTests", code: 2) },
            refreshToken: { _, _ in throw NSError(domain: "PersistentAuthAdversarialSafetyTests", code: 3) }
        )

        let status = try await coordinator.status(credentialId: "gmail-personal")
        XCTAssertEqual(status["clientState"] as? String, AuthState.invalid.rawValue)
        XCTAssertEqual(status["tokenState"] as? String, AuthState.invalid.rawValue)

        do {
            _ = try await coordinator.login(credentialId: "gmail-personal", options: GmailOAuthLoginOptions(openBrowser: false))
            XCTFail("Expected login to reject the invalid vault client")
        } catch let error as GmailGatewayError {
            XCTAssertEqual(error.code, .authRequired)
        }
        do {
            _ = try await coordinator.hydratedConfig()
            XCTFail("Expected hydration to reject the invalid vault client")
        } catch let error as GmailGatewayError {
            XCTAssertEqual(error.code, .authRequired)
        }
        let writesAfter = await store.dataWriteCount()
        XCTAssertEqual(writesAfter, writesBefore)
    }

    func testVaultRejectsStaleTokenCommitAfterReplacement() async throws {
        let client = testClient()
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: try coherentToken(client: client)))
        let staleProfile = try await vault.profile(credentialId: "gmail-personal", accessMode: .read)
        let stale = try XCTUnwrap(staleProfile)
        let replacement = GmailOAuthClientRecord(
            kind: "installed", clientId: "replacement.apps.googleusercontent.com", clientSecret: "replacement-secret",
            projectId: "replacement-project", authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenEndpoint: "https://oauth2.googleapis.com/token", redirectURIs: ["http://127.0.0.1:8080/oauth2callback"]
        )
        try await vault.replaceProfile(testProfile(client: replacement, token: nil))

        await XCTAssertThrowsErrorAsync {
            try await vault.replaceToken(try coherentToken(client: client), in: stale)
        }
        let current = try await vault.profile(credentialId: "gmail-personal", accessMode: .read)
        XCTAssertEqual(current?.client.clientId, replacement.clientId)
        XCTAssertNil(current?.token)
    }

    func testCoordinatorSerializesReplaceSetupAfterLogin() async throws {
        let client = testClient()
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: nil))
        let gate = CoordinatorLifecycleGate(waitingFor: .loginDestinationResolved)
        let lockAttempts = CoordinatorLockAttemptGate()
        let replacementClient = GmailOAuthClientRecord(
            kind: "installed", clientId: "replacement.apps.googleusercontent.com", clientSecret: "replacement-secret",
            projectId: "replacement-project", authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenEndpoint: "https://oauth2.googleapis.com/token", redirectURIs: ["http://127.0.0.1:8080/oauth2callback"]
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clientPath = directory.appendingPathComponent("replacement-client.json")
        try replacementClient.legacyJSON().data(using: .utf8)?.write(to: clientPath)
        let coordinator = GmailAuthCoordinator(
            config: persistentConfig(tokenPath: directory.appendingPathComponent("token.json").path, fallback: true),
            environment: [:],
            policy: .persistent(requiredAccessMode: .read),
            store: store,
            loginResult: { _, _ in GmailOAuthLoginResult(tokenStore: try coherentToken(client: client), redirectURI: "http://127.0.0.1:1/oauth2callback") },
            lifecyclePhase: { phase in await gate.observe(phase) },
            lifecycleLockAttempt: { await lockAttempts.observe() }
        )

        let login: Task<Void, Error> = Task { _ = try await coordinator.login(credentialId: "gmail-personal", options: GmailOAuthLoginOptions(openBrowser: false)) }
        await lockAttempts.waitForCount(1)
        await gate.waitForEntry()
        let setup: Task<Void, Error> = Task {
            _ = try await coordinator.setup(
                credentialId: "gmail-personal",
                options: GmailOAuthSetupOptions(clientSecretPath: clientPath.path, replace: true, confirmedCredentialId: "gmail-personal")
            )
        }
        await lockAttempts.waitForCount(2)
        await gate.release()
        _ = try await login.value
        _ = try await setup.value

        let final = try await vault.profile(credentialId: "gmail-personal", accessMode: .read)
        XCTAssertEqual(final?.client.clientId, replacementClient.clientId)
        XCTAssertNil(final?.token)
    }

    func testSecureTokenWriterUsesPrivateModeWithPermissiveUmask() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("token.json").path
        let previous = umask(0)
        defer { _ = umask(previous) }
        try writeGmailOAuthTokenStore(
            try coherentToken(client: testClient()),
            to: path,
            errorMessage: "write failed",
            exitCode: .authenticationBootstrapError
        )
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    func testSymlinkedTokenPathRejectsLoginAndRevokeWithoutTouchingTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.json")
        let link = root.appendingPathComponent("token.json")
        try JSONEncoder().encode(try coherentToken(client: testClient())).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let config = try persistentConfiguredTokenPathConfig(tokenPath: link.path)
        let coordinator = GmailAuthCoordinator(config: config, environment: [:], policy: .persistent(requiredAccessMode: .read), store: TestSecureCredentialStore())
        let before = try Data(contentsOf: target)

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.login(credentialId: "gmail-personal", options: GmailOAuthLoginOptions(openBrowser: false))
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.revoke(credentialId: "gmail-personal", confirmedCredentialId: "gmail-personal")
        }
        XCTAssertEqual(try Data(contentsOf: target), before)
        XCTAssertTrue(try FileManager.default.destinationOfSymbolicLink(atPath: link.path).hasSuffix("target.json"))
    }

    func testFileIdentityRejectsReplacementBeforeRefreshCommitOrRevoke() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("token.json").path
        let credential = try persistentConfiguredTokenPathConfig(tokenPath: path).credentials[0]
        let original = try coherentToken(client: testClient())
        let replacement = GmailOAuthTokenStore(
            accessMode: .read, accessToken: "replacement-access", refreshToken: "replacement-refresh", tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "), expiresAt: nil, emailAddress: nil,
            clientFingerprint: try gmailOAuthClientFingerprint(testClient())
        )
        try writeGmailOAuthTokenStore(original, to: path, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
        let snapshot = try XCTUnwrap(try readPersistentTokenFileData(path, credential: credential, exitCode: .authenticationBootstrapError))
        try writeGmailOAuthTokenStore(replacement, to: path, errorMessage: "write failed", exitCode: .authenticationBootstrapError)

        XCTAssertThrowsError(try writeGmailOAuthTokenStore(
            original, to: path, errorMessage: "write failed", exitCode: .authenticationBootstrapError, replacing: .identity(snapshot.identity)
        ))
        XCTAssertThrowsError(try removePersistentTokenFile(
            at: path, expectedState: .identity(snapshot.identity), credential: credential, exitCode: .authenticationBootstrapError
        ))
        let retained = try JSONDecoder().decode(GmailOAuthTokenStore.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(retained.accessToken, replacement.accessToken)
    }

    func testConditionalMutationsRejectLeafChangesBetweenPreparationAndCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("token.json").path
        let credential = try persistentConfiguredTokenPathConfig(tokenPath: path).credentials[0]
        let original = try coherentToken(client: testClient())
        let replacement = GmailOAuthTokenStore(
            accessMode: .read, accessToken: "replacement-access", refreshToken: "replacement-refresh", tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "), expiresAt: nil, emailAddress: nil,
            clientFingerprint: try gmailOAuthClientFingerprint(testClient())
        )
        let originalData = try JSONEncoder().encode(original)
        let replacementData = try JSONEncoder().encode(replacement)

        XCTAssertThrowsError(try writeSecureGmailOAuthTokenData(
            originalData,
            to: path,
            credential: credential,
            errorMessage: "write failed",
            exitCode: .authenticationBootstrapError,
            replacing: .absent,
            mutationHook: { phase in
                guard phase == .beforePublish else { return }
                try replacementData.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        ))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), replacementData)

        try writeGmailOAuthTokenStore(original, to: path, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
        let snapshot = try XCTUnwrap(try readPersistentTokenFileData(path, credential: credential, exitCode: .authenticationBootstrapError))
        XCTAssertThrowsError(try writeSecureGmailOAuthTokenData(
            originalData,
            to: path,
            credential: credential,
            errorMessage: "write failed",
            exitCode: .authenticationBootstrapError,
            replacing: .identity(snapshot.identity),
            mutationHook: { phase in
                guard phase == .beforeQuarantine else { return }
                try replacementData.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        ))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), replacementData)

        try writeGmailOAuthTokenStore(original, to: path, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
        let revokeSnapshot = try XCTUnwrap(try readPersistentTokenFileData(path, credential: credential, exitCode: .authenticationBootstrapError))
        XCTAssertThrowsError(try removePersistentTokenFile(
            at: path,
            expectedState: .identity(revokeSnapshot.identity),
            credential: credential,
            exitCode: .authenticationBootstrapError,
            mutationHook: { phase in
                guard phase == .beforeQuarantine else { return }
                try replacementData.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        ))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), replacementData)
    }

    func testQuarantineProtocolPreservesRacedCanonicalState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("token.json").path
        let credential = try persistentConfiguredTokenPathConfig(tokenPath: path).credentials[0]
        let original = try coherentToken(client: testClient())
        let displaced = GmailOAuthTokenStore(
            accessMode: .read, accessToken: "displaced-access", refreshToken: "displaced-refresh", tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "), expiresAt: nil, emailAddress: nil,
            clientFingerprint: try gmailOAuthClientFingerprint(testClient()), schemaVersion: 1,
            provider: .gmail, credentialId: "gmail-personal"
        )
        let concurrent = GmailOAuthTokenStore(
            accessMode: .read, accessToken: "concurrent-access", refreshToken: "concurrent-refresh", tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "), expiresAt: nil, emailAddress: nil,
            clientFingerprint: try gmailOAuthClientFingerprint(testClient()), schemaVersion: 1,
            provider: .gmail, credentialId: "gmail-personal"
        )
        let originalData = try JSONEncoder().encode(original)
        let displacedData = try JSONEncoder().encode(displaced)
        let concurrentData = try JSONEncoder().encode(concurrent)

        try writeGmailOAuthTokenStore(original, to: path, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
        let publishSnapshot = try XCTUnwrap(try readPersistentTokenFileData(path, credential: credential, exitCode: .authenticationBootstrapError))
        XCTAssertThrowsError(try writeSecureGmailOAuthTokenData(
            originalData,
            to: path,
            credential: credential,
            errorMessage: "write failed",
            exitCode: .authenticationBootstrapError,
            replacing: .identity(publishSnapshot.identity),
            mutationHook: { phase in
                guard phase == .afterQuarantine else { return }
                try concurrentData.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        ))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), concurrentData)
        XCTAssertNoTransactionArtifacts(in: root)

        try writeGmailOAuthTokenStore(original, to: path, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
        let restoreSnapshot = try XCTUnwrap(try readPersistentTokenFileData(path, credential: credential, exitCode: .authenticationBootstrapError))
        XCTAssertThrowsError(try writeSecureGmailOAuthTokenData(
            originalData,
            to: path,
            credential: credential,
            errorMessage: "write failed",
            exitCode: .authenticationBootstrapError,
            replacing: .identity(restoreSnapshot.identity),
            mutationHook: { phase in
                switch phase {
                case .beforeQuarantine:
                    try displacedData.write(to: URL(fileURLWithPath: path), options: .atomic)
                case .beforeRestore:
                    try concurrentData.write(to: URL(fileURLWithPath: path), options: .atomic)
                default:
                    break
                }
            }
        ))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), displacedData)
        XCTAssertNoTransactionArtifacts(in: root)

        try writeGmailOAuthTokenStore(original, to: path, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
        let revokeSnapshot = try XCTUnwrap(try readPersistentTokenFileData(path, credential: credential, exitCode: .authenticationBootstrapError))
        XCTAssertThrowsError(try removePersistentTokenFile(
            at: path,
            expectedState: .identity(revokeSnapshot.identity),
            credential: credential,
            exitCode: .authenticationBootstrapError,
            mutationHook: { phase in
                guard phase == .beforeRevokeDelete else { return }
                try concurrentData.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        ))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), concurrentData)
    }

    func testInterruptedQuarantineRecoveryRestoresCanonicalTokenAndRemovesSecrets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("token.json").path
        let credential = try persistentConfiguredTokenPathConfig(tokenPath: path).credentials[0]
        let original = try JSONEncoder().encode(try coherentToken(client: testClient()))
        try writeSecureGmailOAuthTokenData(original, to: path, credential: credential, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
        let expected = try XCTUnwrap(try readPersistentTokenFileData(path, credential: credential, exitCode: .authenticationBootstrapError)).identity

        let quarantine = ".token.json.interrupted.quarantine"
        try FileManager.default.moveItem(atPath: path, toPath: root.appendingPathComponent(quarantine).path)
        let temporaryURL = root.appendingPathComponent(".token.json.transaction.tmp")
        try original.write(to: temporaryURL)
        let candidate = try XCTUnwrap(try readPersistentTokenFileData(temporaryURL.path, credential: credential, exitCode: .authenticationBootstrapError)).identity
        try transactionJournalData(
            quarantineLeaf: quarantine,
            expectedIdentity: expected,
            candidateIdentity: candidate,
            phase: "quarantined"
        ).write(to: root.appendingPathComponent(".token.json.transaction"))

        try recoverPersistentTokenFileTransaction(at: path, credential: credential, exitCode: .authenticationBootstrapError)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
        XCTAssertNoTransactionArtifacts(in: root)
    }

    func testInlineTokenPrecedencePreservesInterruptedLowerPriorityFileTransaction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("token.json").path
        let quarantineURL = root.appendingPathComponent(".token.json.interrupted.quarantine")
        let journalURL = root.appendingPathComponent(".token.json.transaction")
        let client = testClient()
        let displaced = try JSONEncoder().encode(try coherentToken(client: client))
        let canonicalToken = GmailOAuthTokenStore(
            accessMode: .read, accessToken: "canonical-access", refreshToken: "canonical-refresh", tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "), expiresAt: nil, emailAddress: nil,
            clientFingerprint: try gmailOAuthClientFingerprint(client)
        )
        let canonical = try JSONEncoder().encode(canonicalToken)
        let inlineToken = try coherentToken(client: client)
        let inlineJSON = try XCTUnwrap(String(data: JSONEncoder().encode(inlineToken), encoding: .utf8))
        let credential = CredentialConfig(
            id: "gmail-personal",
            provider: .gmail,
            accessMode: .read,
            oauthClientSecretPath: root.appendingPathComponent("client.json").path,
            oauthClientSecretJSON: try client.legacyJSON(),
            tokenStorePath: path,
            tokenStoreJSON: inlineJSON,
            oauthClientSecretSource: .environmentJSON,
            tokenStoreSource: .configuredPath
        )
        let config = GmailGatewayConfig(
            configPath: root.appendingPathComponent("config.toml").path,
            storage: StorageConfig(cacheDir: root.path, attachmentDir: root.path, allowedSendAttachmentRoots: []),
            credentials: [credential],
            accounts: [AccountConfig(
                id: "personal", provider: .gmail, emailAddress: "person@example.invalid",
                credentialId: credential.id, defaultLabelIds: [], isFallback: true
            )]
        )
        try writeSecureGmailOAuthTokenData(displaced, to: path, credential: credential, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
        let expected = try XCTUnwrap(try readPersistentTokenFileData(path, credential: credential, exitCode: .authenticationBootstrapError)).identity
        try FileManager.default.moveItem(atPath: path, toPath: quarantineURL.path)
        try writeSecureGmailOAuthTokenData(canonical, to: path, credential: credential, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
        let candidate = try XCTUnwrap(try readPersistentTokenFileData(path, credential: credential, exitCode: .authenticationBootstrapError)).identity
        try transactionJournalData(
            quarantineLeaf: quarantineURL.lastPathComponent,
            expectedIdentity: expected,
            candidateIdentity: candidate,
            phase: "published"
        ).write(to: journalURL)
        let beforeCanonical = try Data(contentsOf: URL(fileURLWithPath: path))
        let beforeQuarantine = try Data(contentsOf: quarantineURL)
        let beforeJournal = try Data(contentsOf: journalURL)

        let store = TestSecureCredentialStore()
        let coordinator = GmailAuthCoordinator(
            config: config,
            environment: [:],
            policy: .persistent(requiredAccessMode: .read),
            store: store,
            loginResult: { _, _ in throw NSError(domain: "PersistentAuthAdversarialSafetyTests", code: 1) }
        )
        let writesBefore = await store.dataWriteCount()

        do {
            _ = try await coordinator.login(credentialId: credential.id, options: GmailOAuthLoginOptions(openBrowser: false))
            XCTFail("Expected inline token login to be rejected")
        } catch let error as GmailGatewayError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertEqual(error.exitCode, .invalidCliUsage)
        }
        do {
            _ = try await coordinator.revoke(credentialId: credential.id, confirmedCredentialId: credential.id)
            XCTFail("Expected inline token revoke to be rejected")
        } catch let error as GmailGatewayError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertEqual(error.exitCode, .invalidCliUsage)
        }
        let hydrated = try await coordinator.hydratedConfig()
        let hydratedToken = try XCTUnwrap(hydrated.credentials.first?.tokenStoreJSON)
        let decodedHydratedToken = try JSONDecoder().decode(GmailOAuthTokenStore.self, from: Data(hydratedToken.utf8))
        XCTAssertEqual(decodedHydratedToken.accessToken, inlineToken.accessToken)
        XCTAssertEqual(decodedHydratedToken.refreshToken, inlineToken.refreshToken)
        XCTAssertEqual(decodedHydratedToken.clientFingerprint, inlineToken.clientFingerprint)

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), beforeCanonical)
        XCTAssertEqual(try Data(contentsOf: quarantineURL), beforeQuarantine)
        XCTAssertEqual(try Data(contentsOf: journalURL), beforeJournal)
        let writesAfter = await store.dataWriteCount()
        XCTAssertEqual(writesAfter, writesBefore)
    }

    func testAtomicJournalInstallPreservesRecoverableStateAcrossFaults() throws {
        let original = try JSONEncoder().encode(try coherentToken(client: testClient()))
        let replacement = try JSONEncoder().encode(GmailOAuthTokenStore(
            accessMode: .read, accessToken: "replacement-access", refreshToken: "replacement-refresh", tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "), expiresAt: nil, emailAddress: nil,
            clientFingerprint: try gmailOAuthClientFingerprint(testClient())
        ))

        for failedInstall in 1 ... 3 {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let path = root.appendingPathComponent("token.json").path
            let credential = try persistentConfiguredTokenPathConfig(tokenPath: path).credentials[0]
            try writeSecureGmailOAuthTokenData(original, to: path, credential: credential, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
            let expected = try XCTUnwrap(try readPersistentTokenFileData(path, credential: credential, exitCode: .authenticationBootstrapError)).identity
            var installCount = 0

            XCTAssertThrowsError(try writeSecureGmailOAuthTokenData(
                replacement,
                to: path,
                credential: credential,
                errorMessage: "write failed",
                exitCode: .authenticationBootstrapError,
                replacing: .identity(expected),
                mutationHook: { phase in
                    guard phase == .beforeJournalInstall else { return }
                    installCount += 1
                    guard installCount == failedInstall else { return }
                    throw POSIXError(.EIO)
                }
            ))
            XCTAssertEqual(installCount, failedInstall)
            XCTAssertEqual(
                try Data(contentsOf: URL(fileURLWithPath: path)),
                failedInstall == 3 ? replacement : original
            )
            XCTAssertNoTransactionArtifacts(in: root)
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("token.json").path
        let credential = try persistentConfiguredTokenPathConfig(tokenPath: path).credentials[0]
        try writeSecureGmailOAuthTokenData(original, to: path, credential: credential, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
        try Data("journal-metadata".utf8).write(to: root.appendingPathComponent(".token.json.transaction.journal-crash.tmp"))
        try recoverPersistentTokenFileTransaction(at: path, credential: credential, exitCode: .authenticationBootstrapError)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
        XCTAssertNoTransactionArtifacts(in: root)
    }

    func testTransactionRecoveryRejectsSubstitutedQuarantineAndCleansVerifiedPublishedState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("token.json").path
        let credential = try persistentConfiguredTokenPathConfig(tokenPath: path).credentials[0]
        let original = try JSONEncoder().encode(try coherentToken(client: testClient()))
        let replacement = try JSONEncoder().encode(GmailOAuthTokenStore(
            accessMode: .read, accessToken: "replacement-access", refreshToken: "replacement-refresh", tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "), expiresAt: nil, emailAddress: nil,
            clientFingerprint: try gmailOAuthClientFingerprint(testClient())
        ))
        let quarantine = ".token.json.interrupted.quarantine"
        let quarantineURL = root.appendingPathComponent(quarantine)
        let journalURL = root.appendingPathComponent(".token.json.transaction")

        try writeSecureGmailOAuthTokenData(original, to: path, credential: credential, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
        let expected = try XCTUnwrap(try readPersistentTokenFileData(path, credential: credential, exitCode: .authenticationBootstrapError)).identity

        // Crash before rename: recovery removes the prepared replacement and journal.
        let temporaryURL = root.appendingPathComponent(".token.json.transaction.tmp")
        try original.write(to: temporaryURL)
        let preparedCandidate = try XCTUnwrap(try readPersistentTokenFileData(temporaryURL.path, credential: credential, exitCode: .authenticationBootstrapError)).identity
        try transactionJournalData(
            quarantineLeaf: quarantine,
            expectedIdentity: expected,
            candidateIdentity: preparedCandidate,
            phase: "prepared"
        ).write(to: journalURL)
        try recoverPersistentTokenFileTransaction(at: path, credential: credential, exitCode: .authenticationBootstrapError)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
        XCTAssertNoTransactionArtifacts(in: root)

        // A substituted quarantine inode is unknown state and must never be
        // published or deleted by recovery.
        try FileManager.default.moveItem(atPath: path, toPath: quarantineURL.path)
        try transactionJournalData(
            quarantineLeaf: quarantine,
            expectedIdentity: expected,
            candidateIdentity: expected,
            phase: "quarantined"
        ).write(to: journalURL)
        try replacement.write(to: quarantineURL, options: .atomic)
        XCTAssertThrowsError(try recoverPersistentTokenFileTransaction(at: path, credential: credential, exitCode: .authenticationBootstrapError))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try Data(contentsOf: quarantineURL), replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))

        // A crash after publication leaves a verified old quarantine inode that
        // recovery may safely remove, preserving the published canonical token.
        try FileManager.default.removeItem(at: quarantineURL)
        try FileManager.default.removeItem(at: journalURL)
        try writeSecureGmailOAuthTokenData(original, to: path, credential: credential, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
        let publishedExpected = try XCTUnwrap(try readPersistentTokenFileData(path, credential: credential, exitCode: .authenticationBootstrapError)).identity
        try FileManager.default.moveItem(atPath: path, toPath: quarantineURL.path)
        try replacement.write(to: URL(fileURLWithPath: path), options: .atomic)
        let publishedCandidate = try XCTUnwrap(try readPersistentTokenFileData(path, credential: credential, exitCode: .authenticationBootstrapError)).identity
        try transactionJournalData(
            quarantineLeaf: quarantine,
            expectedIdentity: publishedExpected,
            candidateIdentity: publishedCandidate,
            phase: "published"
        ).write(to: journalURL)
        try recoverPersistentTokenFileTransaction(at: path, credential: credential, exitCode: .authenticationBootstrapError)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), replacement)
        XCTAssertNoTransactionArtifacts(in: root)
    }

    func testCoordinatorRejectsLateFileCreationAfterAbsentLoginDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("token.json").path
        let client = testClient()
        let gate = CoordinatorLifecycleGate(waitingFor: .loginDestinationResolved)
        let coordinator = GmailAuthCoordinator(
            config: try persistentConfiguredTokenPathConfig(tokenPath: path),
            environment: [:], policy: .persistent(requiredAccessMode: .read), store: TestSecureCredentialStore(),
            loginResult: { _, _ in GmailOAuthLoginResult(tokenStore: try coherentToken(client: client), redirectURI: "http://127.0.0.1:1/oauth2callback") },
            lifecyclePhase: { phase in await gate.observe(phase) }
        )

        let login: Task<Void, Error> = Task { _ = try await coordinator.login(credentialId: "gmail-personal", options: GmailOAuthLoginOptions(openBrowser: false)) }
        await gate.waitForEntry()
        let lateToken = GmailOAuthTokenStore(
            accessMode: .read, accessToken: "late-access", refreshToken: "late-refresh", tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "), expiresAt: nil, emailAddress: nil,
            clientFingerprint: try gmailOAuthClientFingerprint(client)
        )
        try writeGmailOAuthTokenStore(lateToken, to: path, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
        await gate.release()
        await XCTAssertThrowsErrorAsync { _ = try await login.value }
        let retained = try JSONDecoder().decode(GmailOAuthTokenStore.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(retained.accessToken, lateToken.accessToken)
    }

    func testCoordinatorSerializesRefreshBeforeConfirmedRevoke() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("token.json").path
        let client = testClient()
        let expired = GmailOAuthTokenStore(
            accessMode: .read, accessToken: "expired-access", refreshToken: "refresh-token", tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "), expiresAt: "2000-01-01T00:00:00Z", emailAddress: nil,
            clientFingerprint: try gmailOAuthClientFingerprint(client), schemaVersion: 1,
            provider: .gmail, credentialId: "gmail-personal"
        )
        try writeGmailOAuthTokenStore(expired, to: path, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
        let gate = CoordinatorLifecycleGate(waitingFor: .refreshResolved)
        let lockAttempts = CoordinatorLockAttemptGate()
        let coordinator = GmailAuthCoordinator(
            config: try persistentConfiguredTokenPathConfig(tokenPath: path),
            environment: [:], policy: .persistent(requiredAccessMode: .read), store: TestSecureCredentialStore(),
            refreshToken: { _, _ in try coherentToken(client: client) },
            lifecyclePhase: { phase in await gate.observe(phase) },
            lifecycleLockAttempt: { await lockAttempts.observe() }
        )

        let refresh: Task<Void, Error> = Task { _ = try await coordinator.hydratedConfig() }
        await lockAttempts.waitForCount(1)
        await gate.waitForEntry()
        let revoke: Task<Void, Error> = Task { _ = try await coordinator.revoke(credentialId: "gmail-personal", confirmedCredentialId: "gmail-personal") }
        await lockAttempts.waitForCount(2)
        await gate.release()
        _ = try await refresh.value
        _ = try await revoke.value
        XCTAssertNil(try readPersistentTokenFileData(path, credential: try persistentConfiguredTokenPathConfig(tokenPath: path).credentials[0], exitCode: .authenticationBootstrapError))
    }

    func testCoordinatorRejectsLeafSubstitutionAfterDestinationResolution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tokenURL = root.appendingPathComponent("token.json")
        let targetURL = root.appendingPathComponent("replacement.json")
        let client = testClient()
        try writeGmailOAuthTokenStore(try coherentToken(client: client), to: tokenURL.path, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
        let targetToken = GmailOAuthTokenStore(
            accessMode: .read, accessToken: "target-access", refreshToken: "target-refresh", tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "), expiresAt: nil, emailAddress: nil,
            clientFingerprint: try gmailOAuthClientFingerprint(client)
        )
        try writeGmailOAuthTokenStore(targetToken, to: targetURL.path, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
        let gate = CoordinatorLifecycleGate(waitingFor: .loginDestinationResolved)
        let coordinator = GmailAuthCoordinator(
            config: try persistentConfiguredTokenPathConfig(tokenPath: tokenURL.path),
            environment: [:], policy: .persistent(requiredAccessMode: .read), store: TestSecureCredentialStore(),
            loginResult: { _, _ in GmailOAuthLoginResult(tokenStore: try coherentToken(client: client), redirectURI: "http://127.0.0.1:1/oauth2callback") },
            lifecyclePhase: { phase in await gate.observe(phase) }
        )

        let login: Task<Void, Error> = Task { _ = try await coordinator.login(credentialId: "gmail-personal", options: GmailOAuthLoginOptions(openBrowser: false)) }
        await gate.waitForEntry()
        try FileManager.default.removeItem(at: tokenURL)
        try FileManager.default.createSymbolicLink(at: tokenURL, withDestinationURL: targetURL)
        await gate.release()
        await XCTAssertThrowsErrorAsync { _ = try await login.value }
        let retained = try JSONDecoder().decode(GmailOAuthTokenStore.self, from: Data(contentsOf: targetURL))
        XCTAssertEqual(retained.accessToken, targetToken.accessToken)
        XCTAssertTrue((try? FileManager.default.destinationOfSymbolicLink(atPath: tokenURL.path))?.hasSuffix("replacement.json") == true)
    }

    func testParentSymlinkRejectsResolutionAndLifecycleMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        let linkedDirectory = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let target = targetDirectory.appendingPathComponent("token.json")
        try JSONEncoder().encode(try coherentToken(client: testClient())).write(to: target)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: targetDirectory)
        let config = try persistentConfiguredTokenPathConfig(tokenPath: linkedDirectory.appendingPathComponent("token.json").path)
        let coordinator = GmailAuthCoordinator(config: config, environment: [:], policy: .persistent(requiredAccessMode: .read), store: TestSecureCredentialStore())
        let before = try Data(contentsOf: target)

        await XCTAssertThrowsErrorAsync { _ = try await coordinator.hydratedConfig() }
        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.revoke(credentialId: "gmail-personal", confirmedCredentialId: "gmail-personal")
        }
        XCTAssertEqual(try Data(contentsOf: target), before)
    }
}

private func XCTAssertNoTransactionArtifacts(in directory: URL, file: StaticString = #filePath, line: UInt = #line) {
    let artifacts = (try? FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
        $0.contains(".transaction") || $0.hasSuffix(".quarantine")
    }) ?? []
    XCTAssertTrue(artifacts.isEmpty, "unexpected transaction artifacts: \(artifacts)", file: file, line: line)
}

private func transactionJournalData(
    quarantineLeaf: String,
    expectedIdentity: PersistentTokenFileIdentity,
    candidateIdentity: PersistentTokenFileIdentity,
    phase: String
) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "quarantineLeaf": quarantineLeaf,
        "expectedIdentity": ["device": expectedIdentity.device, "inode": expectedIdentity.inode],
        "operation": "replacement",
        "candidateIdentity": ["device": candidateIdentity.device, "inode": candidateIdentity.inode],
        "phase": phase
    ])
}

private actor CoordinatorLifecycleGate {
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
        case (.setupReadyToCommit, .setupReadyToCommit),
             (.revokeReadyToCommit, .revokeReadyToCommit),
             (.loginDestinationResolved, .loginDestinationResolved),
             (.refreshResolved, .refreshResolved):
            true
        default:
            false
        }
    }
}

private actor CoordinatorLockAttemptGate {
    private var attempts = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func observe() {
        attempts += 1
        let ready = waiters.filter { $0.0 <= attempts }
        waiters.removeAll { $0.0 <= attempts }
        ready.forEach { $0.1.resume() }
    }

    func waitForCount(_ count: Int) async {
        guard attempts < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}
