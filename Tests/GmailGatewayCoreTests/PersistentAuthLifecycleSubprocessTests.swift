import Foundation
@_spi(Testing) @testable import GmailGatewayCore
import XCTest

#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class PersistentAuthLifecycleSubprocessTests: XCTestCase {
    func testProductionLifecycleLockBlocksSeparateProcessContender() throws {
        guard ProcessInfo.processInfo.environment["GMAIL_GATEWAY_LOCK_FIXTURE_CHILD"] == nil else { return }
        let credentialID = "lock-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let lockDirectory = lockTestDirectory()
        try FileManager.default.createDirectory(
            at: lockDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: lockDirectory) }
        let holder = try lockFixture(mode: "holder", credentialID: credentialID, lockDirectoryPath: lockDirectory.path)
        defer {
            holder.process.terminate()
            try? FileManager.default.removeItem(at: holder.root)
        }
        XCTAssertEqual(holder.signal.wait(timeout: .now() + .seconds(5)), .success)

        let contender = try lockFixture(mode: "contender", credentialID: credentialID, lockDirectoryPath: lockDirectory.path)
        defer { try? FileManager.default.removeItem(at: contender.root) }
        let contention = try XCTUnwrap(contender.contentionSignal)
        XCTAssertEqual(contention.wait(timeout: .now() + .seconds(5)), .success)
        XCTAssertFalse(contender.signal.isSignaled())

        let previousSIGPIPE = signal(SIGPIPE, SIG_IGN)
        defer { _ = signal(SIGPIPE, previousSIGPIPE) }
        try holder.input.fileHandleForWriting.write(contentsOf: Data([1]))
        holder.input.fileHandleForWriting.closeFile()
        holder.process.waitUntilExit()
        XCTAssertEqual(holder.process.terminationStatus, 0)
        XCTAssertEqual(contender.signal.wait(timeout: .now() + .seconds(5)), .success)
        contender.process.waitUntilExit()
        XCTAssertEqual(contender.process.terminationStatus, 0)
    }

    func testLifecycleLockRejectsSymlinkedNamespaceAndHardensPrivateDirectory() throws {
        let root = lockTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let realDirectory = root.appendingPathComponent("real", isDirectory: true)
        let symlinkDirectory = root.appendingPathComponent("link", isDirectory: true)
        let permissiveDirectory = root.appendingPathComponent("permissive", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: symlinkDirectory, withDestinationURL: realDirectory)
        try FileManager.default.createDirectory(at: permissiveDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

        XCTAssertThrowsError(try withGmailPersistentCredentialLifecycleLockForTesting(
            credentialID: "safe-lock-id",
            accessMode: .read,
            lockDirectoryPath: symlinkDirectory.path,
            operation: {}
        ))
        try withGmailPersistentCredentialLifecycleLockForTesting(
            credentialID: "safe-lock-id",
            accessMode: .read,
            lockDirectoryPath: permissiveDirectory.path,
            operation: {}
        )
        var metadata = stat()
        XCTAssertEqual(stat(permissiveDirectory.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o077, 0)
    }

    private func lockFixture(mode: String, credentialID: String, lockDirectoryPath: String) throws -> LockFixtureProcess {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let signalPath = root.appendingPathComponent("entered").path
        let contentionPath = root.appendingPathComponent("contended").path
        let process = Process()
        let input = Pipe()
        process.executableURL = Bundle(for: PersistentAuthLifecycleSubprocessTests.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("gmail-gateway-swift-smoke-tests")
        var environment = ProcessInfo.processInfo.environment
        environment["GMAIL_GATEWAY_LOCK_FIXTURE_CREDENTIAL"] = credentialID
        environment["GMAIL_GATEWAY_LOCK_FIXTURE_MODE"] = mode
        environment["GMAIL_GATEWAY_LOCK_FIXTURE_CHILD"] = "1"
        environment["GMAIL_GATEWAY_LOCK_FIXTURE_SIGNAL_PATH"] = signalPath
        environment["GMAIL_GATEWAY_LOCK_FIXTURE_ATTEMPT_PATH"] = contentionPath
        environment["GMAIL_GATEWAY_LOCK_FIXTURE_DIRECTORY"] = lockDirectoryPath
        process.environment = environment
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let signal = try FixtureFileSignal(path: signalPath)
        let contentionSignal = mode == "contender" ? try FixtureFileSignal(path: contentionPath) : nil
        try process.run()
        return LockFixtureProcess(process: process, input: input, root: root, signal: signal, contentionSignal: contentionSignal)
    }
}

private func lockTestDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(".build/lifecycle-lock-tests/\(UUID().uuidString)", isDirectory: true)
}

private struct LockFixtureProcess {
    let process: Process
    let input: Pipe
    let root: URL
    let signal: FixtureFileSignal
    let contentionSignal: FixtureFileSignal?
}

private final class FixtureFileSignal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let path: String
    private var didSignal = false
    private let descriptor: Int32
    private let source: DispatchSourceFileSystemObject

    init(path: String) throws {
        self.path = path
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        descriptor = open(directory, O_EVTONLY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: .global(qos: .userInitiated)
        )
        source.setEventHandler { [weak self] in
            guard FileManager.default.fileExists(atPath: path) else { return }
            self?.signal()
        }
        source.resume()
        if FileManager.default.fileExists(atPath: path) {
            signal()
        }
    }

    deinit {
        source.cancel()
        close(descriptor)
    }

    private func signal() {
        lock.lock()
        defer { lock.unlock() }
        guard !didSignal else { return }
        didSignal = true
        semaphore.signal()
    }

    func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        if FileManager.default.fileExists(atPath: path) {
            signal()
        }
        return semaphore.wait(timeout: timeout)
    }

    func isSignaled() -> Bool {
        if FileManager.default.fileExists(atPath: path) {
            signal()
        }
        return lock.withLock { didSignal }
    }
}
