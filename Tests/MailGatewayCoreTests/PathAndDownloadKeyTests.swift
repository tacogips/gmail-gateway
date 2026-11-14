import Foundation
@testable import MailGatewayCore
import Testing

@Test func isWithinRootAcceptsRootAndDescendants() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mail-gateway-root-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    #expect(isWithinRoot(rootPath: root.path, candidatePath: root.path))
    #expect(isWithinRoot(rootPath: root.path, candidatePath: root.appendingPathComponent("child/file.txt").path))
}

@Test func isWithinRootRejectsTraversalAndSiblingPrefix() throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mail-gateway-roots-\(UUID().uuidString)", isDirectory: true)
    let root = base.appendingPathComponent("allowed", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: base)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    #expect(!isWithinRoot(rootPath: root.path, candidatePath: root.appendingPathComponent("../outside.txt").path))
    #expect(!isWithinRoot(rootPath: root.path, candidatePath: base.appendingPathComponent("allowed-sibling").path))
}

@Test func isWithinRootRejectsSymlinkEscape() throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mail-gateway-symlink-\(UUID().uuidString)", isDirectory: true)
    let root = base.appendingPathComponent("allowed", isDirectory: true)
    let outside = base.appendingPathComponent("outside", isDirectory: true)
    let link = root.appendingPathComponent("link", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: base)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    #expect(!isWithinRoot(rootPath: root.path, candidatePath: link.appendingPathComponent("escaped.txt").path))
}

@Test func messageFileDownloadKeyRoundTripsAndSanitizesFilename() throws {
    let key = MessageFileDownloadKey(
        accountId: "personal",
        messageId: "message-id",
        kind: .bodyText,
        filename: "../body name.txt",
        attachmentId: nil,
        mimeType: "text/plain"
    )

    let decoded = try decodeMessageFileDownloadKey(encodeMessageFileDownloadKey(key))

    #expect(decoded.accountId == "personal")
    #expect(decoded.messageId == "message-id")
    #expect(decoded.kind == .bodyText)
    #expect(decoded.filename == "body_name.txt")
    #expect(decoded.mimeType == "text/plain")
}
