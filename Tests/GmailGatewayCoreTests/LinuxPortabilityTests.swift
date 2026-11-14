import Foundation
import GmailGatewayPlatform
@testable import GmailGatewayCore
import XCTest

#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class LinuxPortabilityTests: XCTestCase {
    func testExclusiveRenamePreservesBothFilesOnCollision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try Data("candidate".utf8).write(to: source)
        try Data("existing".utf8).write(to: destination)
        let directory = open(root.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(directory, 0)
        guard directory >= 0 else { return }
        defer { close(directory) }

        let collisionResult = gmail_gateway_rename_exclusive(directory, "source", directory, "destination")
        let collisionErrno = errno
        XCTAssertEqual(collisionResult, -1)
        XCTAssertEqual(collisionErrno, EEXIST)
        XCTAssertEqual(try Data(contentsOf: source), Data("candidate".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing".utf8))

        try FileManager.default.removeItem(at: destination)
        XCTAssertEqual(gmail_gateway_rename_exclusive(directory, "source", directory, "destination"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("candidate".utf8))
    }

    func testHashAndNilProjectFingerprintMatchFixedPortableVectors() throws {
        XCTAssertEqual(archiveSHA256(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let client = GmailOAuthClientRecord(kind: "installed", clientId: "fixture", clientSecret: nil,
            projectId: nil, authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenEndpoint: "https://oauth2.googleapis.com/token", redirectURIs: ["http://127.0.0.1/callback"])
        XCTAssertEqual(try gmailOAuthClientFingerprint(client),
            "610b0e1e96755164800462991f5d189dc3afa4d1a572a625b062ef2168adced5")
    }
}
