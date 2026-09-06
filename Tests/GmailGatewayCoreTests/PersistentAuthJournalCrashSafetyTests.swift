import Foundation
@testable import GmailGatewayCore
import XCTest

final class PersistentAuthJournalCrashSafetyTests: XCTestCase {
    func testAtomicJournalGenerationFaultsLeaveOnlyRecoverableState() throws {
        let original = try JSONEncoder().encode(try coherentToken(client: testClient()))
        let replacement = try JSONEncoder().encode(GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "replacement-access",
            refreshToken: "replacement-refresh",
            tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "),
            expiresAt: nil,
            emailAddress: nil,
            clientFingerprint: try gmailOAuthClientFingerprint(testClient())
        ))

        for failedInstall in 1 ... 3 {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let path = root.appendingPathComponent("token.json").path
            let credential = try persistentConfiguredTokenPathConfig(tokenPath: path).credentials[0]
            try writeSecureGmailOAuthTokenData(original, to: path, credential: credential, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
            let expected = try XCTUnwrap(try readPersistentTokenFileData(path, credential: credential, exitCode: .authenticationBootstrapError)).identity
            var installs = 0
            let journalPath = root.appendingPathComponent(".token.json.transaction")

            XCTAssertThrowsError(try writeSecureGmailOAuthTokenData(
                replacement,
                to: path,
                credential: credential,
                errorMessage: "write failed",
                exitCode: .authenticationBootstrapError,
                replacing: .identity(expected),
                mutationHook: { phase in
                    guard phase == .beforeJournalInstall else { return }
                    installs += 1
                    // This hook runs after the candidate is fully encoded and
                    // synchronized, but before it can replace the final name.
                    // Observe the crash boundary itself rather than the later
                    // recovery cleanup that the thrown error triggers.
                    let visiblePhase = try transactionJournalPhase(at: journalPath)
                    switch installs {
                    case 1:
                        XCTAssertNil(visiblePhase, "the first candidate must not expose a final journal")
                    case 2:
                        XCTAssertEqual(visiblePhase, "prepared", "phase replacement must retain the prior complete journal")
                    case 3:
                        XCTAssertEqual(visiblePhase, "quarantined", "phase replacement must retain the prior complete journal")
                    default:
                        XCTFail("unexpected transaction-journal installation")
                    }
                    if installs == failedInstall { throw POSIXError(.EIO) }
                }
            ))
            XCTAssertEqual(installs, failedInstall)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), failedInstall == 3 ? replacement : original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".token.json.transaction").path))
            XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: root.path)).allSatisfy { !$0.contains(".transaction") })
        }
    }

    func testRecoveryRejectsMissingReplacementArtifactsButCompletesRecordedRevocation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("token.json").path
        let credential = try persistentConfiguredTokenPathConfig(tokenPath: path).credentials[0]
        let original = try JSONEncoder().encode(try coherentToken(client: testClient()))
        let replacement = try JSONEncoder().encode(try coherentToken(client: testClient()))

        try writeSecureGmailOAuthTokenData(original, to: path, credential: credential, errorMessage: "write failed", exitCode: .authenticationBootstrapError)
        let replacementIdentity = try XCTUnwrap(try readPersistentTokenFileData(path, credential: credential, exitCode: .authenticationBootstrapError)).identity
        XCTAssertThrowsError(try writeSecureGmailOAuthTokenData(
            replacement,
            to: path,
            credential: credential,
            errorMessage: "write failed",
            exitCode: .authenticationBootstrapError,
            replacing: .identity(replacementIdentity),
            mutationHook: { phase in
                guard phase == .afterQuarantine else { return }
                try removeQuarantineArtifact(at: root)
                throw POSIXError(.EIO)
            }
        ))
        let leavesAfterReplacementFault = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(leavesAfterReplacementFault.contains(".token.json.transaction"))
        XCTAssertTrue(leavesAfterReplacementFault.contains(".token.json.transaction.tmp"))
        XCTAssertThrowsError(try recoverPersistentTokenFileTransaction(
            at: path,
            credential: credential,
            exitCode: .authenticationBootstrapError
        ))

        try? FileManager.default.removeItem(at: root.appendingPathComponent(".token.json.transaction.tmp"))
        try? FileManager.default.removeItem(at: root.appendingPathComponent(".token.json.transaction"))
        try JSONEncoder().encode(try coherentToken(client: testClient())).write(to: URL(fileURLWithPath: path))
        let revokeIdentity = try XCTUnwrap(try readPersistentTokenFileData(path, credential: credential, exitCode: .authenticationBootstrapError)).identity
        XCTAssertThrowsError(try removePersistentTokenFile(
            at: path,
            expectedState: .identity(revokeIdentity),
            credential: credential,
            exitCode: .authenticationBootstrapError,
            mutationHook: { phase in
                guard phase == .afterQuarantine else { return }
                try removeQuarantineArtifact(at: root)
                throw POSIXError(.EIO)
            }
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".token.json.transaction").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}

private func transactionJournalPhase(at path: URL) throws -> String? {
    guard FileManager.default.fileExists(atPath: path.path) else { return nil }
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: path))
    let journal = try XCTUnwrap(object as? [String: Any])
    return try XCTUnwrap(journal["phase"] as? String)
}

private func removeQuarantineArtifact(at root: URL) throws {
    let leaf = try XCTUnwrap(
        FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.hasSuffix(".quarantine") }
    )
    try FileManager.default.removeItem(at: root.appendingPathComponent(leaf))
}
