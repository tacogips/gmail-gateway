@testable import GmailGatewayCore
import XCTest

final class PersistentAuthIsolationTests: XCTestCase {
    func testOnlyReaderSenderAndDraftAdvertisePersistentAuthSetup() {
        let targetModes: [GmailGatewayCLIMode] = [.reader, .directSender, .draftGateway]
        for mode in targetModes {
            let result = GmailGatewayCLI(mode: mode, authPolicy: persistentPolicy(for: mode)).run(arguments: ["--help"], environment: [:])
            XCTAssertTrue(result.stdout.contains("auth <setup|login|revoke|status>"))
        }
    }

    func testExcludedModesKeepLegacyAuthSyntax() {
        let excludedModes: [GmailGatewayCLIMode] = [.mailboxThreads, .messageBox]
        for mode in excludedModes {
            let result = GmailGatewayCLI(mode: mode).run(arguments: ["--help"], environment: [:])
            XCTAssertFalse(result.stdout.contains("auth <setup|"))
            XCTAssertTrue(result.stdout.contains("auth <login|revoke|status>"))
        }
    }

    func testExcludedLegacyFixturesAllowFingerprintFreeReadModifyAndFullTokens() throws {
        for accessMode in [AccessMode.readModify, .full] {
            try assertExcludedLegacyProviderAccepts(accessMode: accessMode)
        }
    }

    func testExcludedModesKeepLegacyAtomicTokenWritesAndParentPermissions() throws {
        for (mode, accessMode) in [
            (GmailGatewayCLIMode.mailboxThreads, AccessMode.readModify),
            (.messageBox, .full)
        ] {
            try assertExcludedLegacyTokenPersistence(mode: mode, accessMode: accessMode)
        }
    }

    private func assertExcludedLegacyProviderAccepts(accessMode: AccessMode) throws {
        let token = GmailOAuthTokenStore(
            accessMode: accessMode,
            accessToken: "legacy-access-token",
            refreshToken: "legacy-refresh-token",
            tokenType: "Bearer",
            scope: gmailScopes(accessMode: accessMode).joined(separator: " "),
            expiresAt: nil,
            emailAddress: "person@example.com",
            clientFingerprint: nil
        )
        let tokenJSON = try XCTUnwrap(String(data: JSONEncoder().encode(token), encoding: .utf8))
        let credential = CredentialConfig(
            id: "legacy-\(accessMode.rawValue)", provider: .gmail, accessMode: accessMode,
            oauthClientSecretPath: "/unused-client", oauthClientSecretJSON: nil,
            tokenStorePath: "/unused-token", tokenStoreJSON: tokenJSON
        )
        let use: GmailAccessTokenUse = accessMode == .readModify ? .mailboxModify : .directSend
        XCTAssertEqual(
            try validGmailAccessToken(credential: credential, use: use),
            "legacy-access-token"
        )
    }

    private func assertExcludedLegacyTokenPersistence(
        mode: GmailGatewayCLIMode,
        accessMode: AccessMode
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let parent = root.appendingPathComponent("existing-parent", isDirectory: true)
        let tokenPath = parent.appendingPathComponent("token.json").path
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let tokens = ["first", "second"].map { value in
            GmailOAuthTokenStore(
                accessMode: accessMode,
                accessToken: "\(mode.executableName)-\(value)-access",
                refreshToken: "\(mode.executableName)-\(value)-refresh",
                tokenType: "Bearer",
                scope: gmailScopes(accessMode: accessMode).joined(separator: " "),
                expiresAt: nil,
                emailAddress: "person@example.com",
                clientFingerprint: nil
            )
        }
        let failures = LegacyWriteFailureRecorder()
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            do {
                try writeGmailOAuthTokenStore(
                    tokens[index % tokens.count],
                    to: tokenPath,
                    errorMessage: "legacy write failed",
                    exitCode: .authenticationBootstrapError
                )
            } catch {
                failures.record(error)
            }
        }

        XCTAssertTrue(failures.isEmpty, "\(mode) legacy writes failed: \(failures.count)")
        let persisted = try JSONDecoder().decode(
            GmailOAuthTokenStore.self,
            from: Data(contentsOf: URL(fileURLWithPath: tokenPath))
        )
        XCTAssertTrue(tokens.contains { $0.accessToken == persisted.accessToken })
        let permissions = try FileManager.default.attributesOfItem(atPath: parent.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions, 0o755, "\(mode) must preserve existing parent permissions")
        let leaves = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        XCTAssertFalse(leaves.contains { $0.contains("transaction") || $0.contains("quarantine") })
    }
}

private final class LegacyWriteFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedErrors: [Error] = []

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordedErrors.isEmpty
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedErrors.count
    }

    func record(_ error: Error) {
        lock.lock()
        recordedErrors.append(error)
        lock.unlock()
    }
}
