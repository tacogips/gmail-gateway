import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct PersistentTokenFileIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    init(metadata: stat) {
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
    }
}

/// A lifecycle operation must either observe an absent destination or commit to
/// the exact file it read. Keeping absence distinct from an optional identity
/// prevents a late writer from being silently overwritten.
enum PersistentTokenFileExpectedState: Equatable, Sendable {
    case absent
    case identity(PersistentTokenFileIdentity)
}

enum PersistentTokenFileMutationPhase: Equatable, Sendable {
    case beforeQuarantine
    case afterQuarantine
    /// Test-only fault-injection boundary after a complete journal candidate is
    /// durable but before it can replace the current recovery record.
    case beforeJournalInstall
    case beforePublish
    case beforeRestore
    case beforeRevokeDelete
}

struct PersistentTokenFileRead: Sendable {
    let data: Data
    let identity: PersistentTokenFileIdentity
}

private final class PersistentTokenParentDirectory {
    let descriptor: Int32
    let leaf: String

    init(descriptor: Int32, leaf: String) {
        self.descriptor = descriptor
        self.leaf = leaf
    }

    deinit {
        _ = close(descriptor)
    }
}

private enum PersistentTokenFileCurrentState: Equatable {
    case absent
    case identity(PersistentTokenFileIdentity)
    case unsafe
}

private enum PersistentTokenTransactionPhase: String, Codable {
    case prepared
    case quarantined
    case published
}

private enum PersistentTokenTransactionOperation: String, Codable {
    case replacement
    case revocation
}

private struct PersistentTokenTransactionJournal: Codable {
    let quarantineLeaf: String
    let expectedIdentity: PersistentTokenFileIdentity
    let operation: PersistentTokenTransactionOperation
    /// The replacement candidate is durable before the journal is installed.
    /// Recording its identity prevents recovery from accepting an unrelated
    /// canonical file after an interrupted replacement.
    let candidateIdentity: PersistentTokenFileIdentity?
    let phase: PersistentTokenTransactionPhase
}

/// Validates token paths by walking every component through directory
/// descriptors. No path component is followed after it has been checked.
func validatePersistentTokenFilePath(
    _ path: String,
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode
) throws {
    let normalized = normalizedPersistentTokenPath(path, credential: credential, exitCode: exitCode)
    let components = normalized.split(separator: "/").map(String.init)
    guard components.last != nil else {
        throw persistentTokenPathError("token path must name a file", path: path, credential: credential, exitCode: exitCode)
    }
    var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard descriptor >= 0 else {
        throw persistentTokenPathError("cannot inspect token path", path: path, credential: credential, exitCode: exitCode)
    }
    defer { _ = close(descriptor) }
    for component in components.dropLast() {
        let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if next < 0, errno == ENOENT {
            // A missing parent is an allowed login destination. The secure writer
            // creates it descriptor-by-descriptor before exposing token bytes.
            return
        }
        guard next >= 0 else {
            throw persistentTokenPathError("token path must not contain symbolic links", path: path, credential: credential, exitCode: exitCode)
        }
        _ = close(descriptor)
        descriptor = next
    }
}

func preparePersistentTokenFileParent(
    _ path: String,
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode
) throws {
    _ = try openPersistentTokenParent(
        path,
        credential: credential,
        exitCode: exitCode,
        createMissing: true,
        requirePrivateParent: true
    )
}

func readPersistentTokenFileData(
    _ path: String,
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode,
    requireOwnedSingleLink: Bool = false,
    makePrivate: Bool = false
) throws -> PersistentTokenFileRead? {
    try validatePersistentTokenFilePath(path, credential: credential, exitCode: exitCode)
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
    guard FileManager.default.fileExists(atPath: directory) else {
        return nil
    }
    let parent = try openPersistentTokenParent(
        path,
        credential: credential,
        exitCode: exitCode,
        createMissing: false,
        requirePrivateParent: false
    )
    let descriptor = openat(parent.descriptor, parent.leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    if descriptor < 0 {
        if errno == ENOENT { return nil }
        throw persistentTokenPathError("selected token source is unreadable", path: path, credential: credential, exitCode: exitCode)
    }
    defer { _ = close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          !requireOwnedSingleLink || (metadata.st_uid == geteuid() && metadata.st_nlink == 1) else {
        throw persistentTokenPathError("selected token source is unreadable", path: path, credential: credential, exitCode: exitCode)
    }
    if makePrivate {
        guard metadata.st_uid == geteuid(), metadata.st_nlink == 1,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw persistentTokenPathError("token file must be private (0600)", path: path, credential: credential, exitCode: exitCode)
        }
    }
    do {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw POSIXError(.EIO) }
            data.append(contentsOf: buffer.prefix(Int(count)))
        }
        return PersistentTokenFileRead(data: data, identity: PersistentTokenFileIdentity(metadata: metadata))
    } catch {
        throw persistentTokenPathError("selected token source is unreadable", path: path, credential: credential, exitCode: exitCode)
    }
}

/// Serializes migration across processes without following a substituted lock file.
func withGmailTokenMigrationLock<T>(credential: CredentialConfig, operation: () throws -> T) throws -> T {
    let path = credential.tokenStorePath + ".migration.lock"
    let parent = try openPersistentTokenParent(
        path, credential: credential, exitCode: .authenticationBootstrapError,
        createMissing: true, requirePrivateParent: true
    )
    let descriptor = openat(parent.descriptor, parent.leaf, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw POSIXError(.EACCES) }
    defer { _ = close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_uid == geteuid(), metadata.st_nlink == 1,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          fchmod(descriptor, S_IRUSR | S_IWUSR) == 0, flock(descriptor, LOCK_EX) == 0 else {
        throw POSIXError(.EACCES)
    }
    defer { _ = flock(descriptor, LOCK_UN) }
    return try operation()
}

/// Completes or cleans the durable, descriptor-relative transaction left by an
/// interrupted token replacement or revocation. Callers hold the credential
/// lifecycle lock, so recovery cannot race another gateway lifecycle command.
func recoverPersistentTokenFileTransaction(
    at path: String,
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode
) throws {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
    guard FileManager.default.fileExists(atPath: directory) else { return }
    let parent = try openPersistentTokenParent(
        path,
        credential: credential,
        exitCode: exitCode,
        createMissing: false,
        requirePrivateParent: true
    )
    try recoverPersistentTokenFileTransaction(parent, path: path, credential: credential, exitCode: exitCode)
}

func persistentTokenFileHasInterruptedTransaction(
    at path: String,
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode
) throws -> Bool {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
    guard FileManager.default.fileExists(atPath: directory) else { return false }
    let parent = try openPersistentTokenParent(
        path,
        credential: credential,
        exitCode: exitCode,
        createMissing: false,
        requirePrivateParent: false
    )
    return try persistentTokenFileCurrentState(parent, leaf: persistentTokenTemporaryLeaf(parent.leaf)) != .absent ||
        persistentTokenFileCurrentState(parent, leaf: persistentTokenTransactionJournalLeaf(parent.leaf)) != .absent
}

func writeSecureGmailOAuthTokenData(
    _ data: Data,
    to path: String,
    credential: CredentialConfig,
    errorMessage: String,
    exitCode: GmailGatewayExitCode,
    replacing expectedState: PersistentTokenFileExpectedState? = nil,
    mutationHook: ((PersistentTokenFileMutationPhase) throws -> Void)? = nil
) throws {
    let parent = try openPersistentTokenParent(
        path,
        credential: credential,
        exitCode: exitCode,
        createMissing: true,
        requirePrivateParent: true
    )
    try recoverPersistentTokenFileTransaction(
        parent,
        path: path,
        credential: credential,
        exitCode: exitCode
    )
    let commitState: PersistentTokenFileExpectedState
    if let expectedState {
        commitState = expectedState
    } else {
        switch try persistentTokenFileCurrentState(parent, leaf: parent.leaf) {
        case .absent:
            commitState = .absent
        case let .identity(identity):
            commitState = .identity(identity)
        case .unsafe:
            throw persistentTokenPathError("selected token source changed during lifecycle operation", path: path, credential: credential, exitCode: exitCode)
        }
    }
    let temporaryLeaf = persistentTokenTemporaryLeaf(parent.leaf)
    let descriptor = openat(parent.descriptor, temporaryLeaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
        throw persistentTokenPathError(errorMessage, path: path, credential: credential, exitCode: exitCode)
    }
    var removeTemporary = true
    var transactionStarted = false
    var preserveTransactionEvidence = false
    defer {
        _ = close(descriptor)
        if removeTemporary, !preserveTransactionEvidence {
            try? removePersistentTokenLeaf(parent, leaf: temporaryLeaf, path: path, credential: credential, exitCode: exitCode)
        }
    }
    guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
        throw persistentTokenPathError(errorMessage, path: path, credential: credential, exitCode: exitCode)
    }
    do {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { throw POSIXError(.EIO) }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
        switch commitState {
        case .absent:
            try mutationHook?(.beforePublish)
            try renamePersistentTokenFile(
                parent,
                from: temporaryLeaf,
                to: parent.leaf,
                flags: RENAME_EXCL,
                path: path,
                credential: credential,
                exitCode: exitCode
            )
            removeTemporary = false
        case let .identity(identity):
            guard try persistentTokenFileCurrentState(parent, leaf: parent.leaf) == .identity(identity) else {
                throw persistentTokenPathError("selected token source changed during lifecycle operation", path: path, credential: credential, exitCode: exitCode)
            }
            let quarantineLeaf = ".\(parent.leaf).\(UUID().uuidString).quarantine"
            guard case let .identity(candidateIdentity) = try persistentTokenFileCurrentState(parent, leaf: temporaryLeaf) else {
                throw persistentTokenPathError("cannot inspect token replacement", path: path, credential: credential, exitCode: exitCode)
            }
            try writePersistentTokenTransactionJournal(
                parent,
                quarantineLeaf: quarantineLeaf,
                expectedIdentity: identity,
                operation: .replacement,
                candidateIdentity: candidateIdentity,
                path: path,
                credential: credential,
                exitCode: exitCode,
                mutationHook: mutationHook
            )
            transactionStarted = true
            try mutationHook?(.beforeQuarantine)
            guard try persistentTokenFileCurrentState(parent, leaf: parent.leaf) == .identity(identity) else {
                try removePersistentTokenTransactionJournal(parent, path: path, credential: credential, exitCode: exitCode)
                transactionStarted = false
                throw persistentTokenPathError("selected token source changed during lifecycle operation", path: path, credential: credential, exitCode: exitCode)
            }
            try renamePersistentTokenFile(
                parent,
                from: parent.leaf,
                to: quarantineLeaf,
                flags: RENAME_EXCL,
                path: path,
                credential: credential,
                exitCode: exitCode
            )
            try mutationHook?(.afterQuarantine)
            guard try persistentTokenFileCurrentState(parent, leaf: quarantineLeaf) == .identity(identity) else {
                try mutationHook?(.beforeRestore)
                throw persistentTokenPathError("selected token source changed during lifecycle operation", path: path, credential: credential, exitCode: exitCode)
            }
            try updatePersistentTokenTransactionJournal(
                parent,
                journal: PersistentTokenTransactionJournal(
                    quarantineLeaf: quarantineLeaf,
                    expectedIdentity: identity,
                    operation: .replacement,
                    candidateIdentity: candidateIdentity,
                    phase: .quarantined
                ),
                path: path,
                credential: credential,
                exitCode: exitCode,
                mutationHook: mutationHook
            )
            try mutationHook?(.beforePublish)
            try renamePersistentTokenFile(
                parent,
                from: temporaryLeaf,
                to: parent.leaf,
                flags: RENAME_EXCL,
                path: path,
                credential: credential,
                exitCode: exitCode
            )
            removeTemporary = false
            try updatePersistentTokenTransactionJournal(
                parent,
                journal: PersistentTokenTransactionJournal(
                    quarantineLeaf: quarantineLeaf,
                    expectedIdentity: identity,
                    operation: .replacement,
                    candidateIdentity: candidateIdentity,
                    phase: .published
                ),
                path: path,
                credential: credential,
                exitCode: exitCode,
                mutationHook: mutationHook
            )
            guard try persistentTokenFileCurrentState(parent, leaf: quarantineLeaf) == .identity(identity) else {
                throw persistentTokenPathError("selected token source changed during lifecycle operation", path: path, credential: credential, exitCode: exitCode)
            }
            try removePersistentTokenLeaf(parent, leaf: quarantineLeaf, path: path, credential: credential, exitCode: exitCode)
            try removePersistentTokenTransactionJournal(parent, path: path, credential: credential, exitCode: exitCode)
            transactionStarted = false
        }
    } catch let error as GmailGatewayError {
        if transactionStarted {
            do {
                try recoverPersistentTokenFileTransaction(parent, path: path, credential: credential, exitCode: exitCode)
            } catch {
                preserveTransactionEvidence = true
            }
        }
        throw error
    } catch {
        if transactionStarted {
            do {
                try recoverPersistentTokenFileTransaction(parent, path: path, credential: credential, exitCode: exitCode)
            } catch {
                preserveTransactionEvidence = true
            }
        }
        throw persistentTokenPathError(errorMessage, path: path, credential: credential, exitCode: exitCode)
    }
}

func removePersistentTokenFile(
    at path: String,
    expectedState: PersistentTokenFileExpectedState,
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode,
    mutationHook: ((PersistentTokenFileMutationPhase) throws -> Void)? = nil
) throws {
    let parent = try openPersistentTokenParent(
        path,
        credential: credential,
        exitCode: exitCode,
        createMissing: false,
        requirePrivateParent: true
    )
    try recoverPersistentTokenFileTransaction(
        parent,
        path: path,
        credential: credential,
        exitCode: exitCode
    )
    let quarantineLeaf = ".\(parent.leaf).\(UUID().uuidString).quarantine"
    var transactionStarted = false
    do {
        guard case let .identity(identity) = expectedState else {
            throw persistentTokenPathError("selected token source changed during lifecycle operation", path: path, credential: credential, exitCode: exitCode)
        }
        guard try persistentTokenFileCurrentState(parent, leaf: parent.leaf) == .identity(identity) else {
            throw persistentTokenPathError("selected token source changed during lifecycle operation", path: path, credential: credential, exitCode: exitCode)
        }
        try writePersistentTokenTransactionJournal(
            parent,
            quarantineLeaf: quarantineLeaf,
            expectedIdentity: identity,
            operation: .revocation,
            candidateIdentity: nil,
            path: path,
            credential: credential,
            exitCode: exitCode,
            mutationHook: mutationHook
        )
        transactionStarted = true
        try mutationHook?(.beforeQuarantine)
        guard try persistentTokenFileCurrentState(parent, leaf: parent.leaf) == .identity(identity) else {
            try removePersistentTokenTransactionJournal(parent, path: path, credential: credential, exitCode: exitCode)
            transactionStarted = false
            throw persistentTokenPathError("selected token source changed during lifecycle operation", path: path, credential: credential, exitCode: exitCode)
        }
        try renamePersistentTokenFile(parent, from: parent.leaf, to: quarantineLeaf, flags: RENAME_EXCL, path: path, credential: credential, exitCode: exitCode)
        try mutationHook?(.afterQuarantine)
        guard try persistentTokenFileCurrentState(parent, leaf: quarantineLeaf) == expectedState.currentState else {
            try mutationHook?(.beforeRestore)
            throw persistentTokenPathError("selected token source changed during lifecycle operation", path: path, credential: credential, exitCode: exitCode)
        }
        try updatePersistentTokenTransactionJournal(
            parent,
            journal: PersistentTokenTransactionJournal(
                quarantineLeaf: quarantineLeaf,
                expectedIdentity: identity,
                operation: .revocation,
                candidateIdentity: nil,
                phase: .quarantined
            ),
            path: path,
            credential: credential,
            exitCode: exitCode,
            mutationHook: mutationHook
        )
        try mutationHook?(.beforeRevokeDelete)
        guard try persistentTokenFileCurrentState(parent, leaf: quarantineLeaf) == .identity(identity) else {
            throw persistentTokenPathError("selected token source changed during lifecycle operation", path: path, credential: credential, exitCode: exitCode)
        }
        try removePersistentTokenLeaf(parent, leaf: quarantineLeaf, path: path, credential: credential, exitCode: exitCode)
        try removePersistentTokenTransactionJournal(parent, path: path, credential: credential, exitCode: exitCode)
        transactionStarted = false
        guard try persistentTokenFileCurrentState(parent, leaf: parent.leaf) == .absent else {
            throw persistentTokenPathError("selected token source changed during lifecycle operation", path: path, credential: credential, exitCode: exitCode)
        }
    } catch let error as GmailGatewayError {
        if transactionStarted { try? recoverPersistentTokenFileTransaction(parent, path: path, credential: credential, exitCode: exitCode) }
        throw error
    } catch {
        if transactionStarted { try? recoverPersistentTokenFileTransaction(parent, path: path, credential: credential, exitCode: exitCode) }
        throw persistentTokenPathError("cannot remove selected token source", path: path, credential: credential, exitCode: exitCode)
    }
}

private func openPersistentTokenParent(
    _ path: String,
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode,
    createMissing: Bool,
    requirePrivateParent: Bool
) throws -> PersistentTokenParentDirectory {
    let normalized = normalizedPersistentTokenPath(path, credential: credential, exitCode: exitCode)
    let components = normalized.split(separator: "/").map(String.init)
    guard let leaf = components.last, !leaf.isEmpty else {
        throw persistentTokenPathError("token path must name a file", path: path, credential: credential, exitCode: exitCode)
    }
    var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard descriptor >= 0 else {
        throw persistentTokenPathError("cannot inspect token path", path: path, credential: credential, exitCode: exitCode)
    }
    for component in components.dropLast() {
        var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if next < 0, errno == ENOENT, createMissing {
            guard mkdirat(descriptor, component, S_IRWXU) == 0 || errno == EEXIST else {
                _ = close(descriptor)
                throw persistentTokenPathError("cannot create token directory", path: path, credential: credential, exitCode: exitCode)
            }
            next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard next >= 0 else {
            _ = close(descriptor)
            throw persistentTokenPathError("token path must not contain symbolic links", path: path, credential: credential, exitCode: exitCode)
        }
        var metadata = stat()
        guard fstat(next, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR else {
            _ = close(next)
            _ = close(descriptor)
            throw persistentTokenPathError("cannot inspect token path", path: path, credential: credential, exitCode: exitCode)
        }
        _ = close(descriptor)
        descriptor = next
    }
    if requirePrivateParent {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_uid == geteuid(),
              fchmod(descriptor, S_IRWXU) == 0,
              fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & 0o077) == 0 else {
            _ = close(descriptor)
            throw persistentTokenPathError("token directory must be private (0700)", path: path, credential: credential, exitCode: exitCode)
        }
    }
    return PersistentTokenParentDirectory(descriptor: descriptor, leaf: leaf)
}

private func normalizedPersistentTokenPath(
    _ path: String,
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode
) -> String {
    let raw = URL(fileURLWithPath: path).standardizedFileURL.path
    let normalized = raw.hasPrefix("/var/") ? "/private\(raw)" : raw
    guard normalized.hasPrefix("/") else {
        return ""
    }
    return normalized
}

private extension PersistentTokenFileExpectedState {
    var currentState: PersistentTokenFileCurrentState {
        switch self {
        case .absent: .absent
        case let .identity(identity): .identity(identity)
        }
    }
}

private func persistentTokenFileCurrentState(
    _ parent: PersistentTokenParentDirectory,
    leaf: String
) throws -> PersistentTokenFileCurrentState {
    var metadata = stat()
    if fstatat(parent.descriptor, leaf, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
        if errno == ENOENT { return .absent }
        throw POSIXError(.EIO)
    }
    guard (metadata.st_mode & S_IFMT) == S_IFREG else { return .unsafe }
    return .identity(PersistentTokenFileIdentity(metadata: metadata))
}

private func renamePersistentTokenFile(
    _ parent: PersistentTokenParentDirectory,
    from source: String,
    to destination: String,
    flags: Int32,
    path: String,
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode
) throws {
    guard renameatx_np(parent.descriptor, source, parent.descriptor, destination, UInt32(flags)) == 0 else {
        throw persistentTokenPathError("selected token source changed during lifecycle operation", path: path, credential: credential, exitCode: exitCode)
    }
    guard fsync(parent.descriptor) == 0 else {
        throw persistentTokenPathError("cannot synchronize token transaction", path: path, credential: credential, exitCode: exitCode)
    }
}

private func persistentTokenTemporaryLeaf(_ leaf: String) -> String {
    ".\(leaf).transaction.tmp"
}

private func persistentTokenTransactionJournalLeaf(_ leaf: String) -> String {
    ".\(leaf).transaction"
}

private func persistentTokenTransactionJournalTemporaryPrefix(_ leaf: String) -> String {
    ".\(leaf).transaction.journal-"
}

private func persistentTokenTransactionJournalTemporaryLeaf(_ leaf: String) -> String {
    "\(persistentTokenTransactionJournalTemporaryPrefix(leaf))\(UUID().uuidString).tmp"
}

private func recoverPersistentTokenFileTransaction(
    _ parent: PersistentTokenParentDirectory,
    path: String,
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode
) throws {
    let temporaryLeaf = persistentTokenTemporaryLeaf(parent.leaf)
    try removePersistentTokenTransactionJournalTemporaries(
        parent,
        path: path,
        credential: credential,
        exitCode: exitCode
    )
    guard let journal = try persistentTokenTransactionJournal(parent, path: path, credential: credential, exitCode: exitCode) else {
        switch try persistentTokenFileCurrentState(parent, leaf: temporaryLeaf) {
        case .absent:
            break
        case .identity:
            try removePersistentTokenLeaf(parent, leaf: temporaryLeaf, path: path, credential: credential, exitCode: exitCode)
        case .unsafe:
            throw persistentTokenPathError("token transaction contains an unsafe temporary file", path: path, credential: credential, exitCode: exitCode)
        }
        return
    }
    let canonical = try persistentTokenFileCurrentState(parent, leaf: parent.leaf)
    let quarantined = try persistentTokenFileCurrentState(parent, leaf: journal.quarantineLeaf)
    let temporary = try persistentTokenFileCurrentState(parent, leaf: temporaryLeaf)
    switch journal.operation {
    case .replacement:
        guard let candidateIdentity = journal.candidateIdentity else {
            throw persistentTokenPathError("token transaction state is ambiguous", path: path, credential: credential, exitCode: exitCode)
        }
        switch (canonical, quarantined, temporary) {
        case (let .identity(canonicalIdentity), .absent, let .identity(temporaryIdentity))
            where canonicalIdentity == journal.expectedIdentity && temporaryIdentity == candidateIdentity && journal.phase == .prepared:
            try removePersistentTokenLeaf(parent, leaf: temporaryLeaf, path: path, credential: credential, exitCode: exitCode)
        case (.absent, let .identity(quarantineIdentity), let .identity(temporaryIdentity))
            where quarantineIdentity == journal.expectedIdentity && temporaryIdentity == candidateIdentity && journal.phase != .published:
            try renamePersistentTokenFile(parent, from: journal.quarantineLeaf, to: parent.leaf, flags: RENAME_EXCL, path: path, credential: credential, exitCode: exitCode)
            try removePersistentTokenLeaf(parent, leaf: temporaryLeaf, path: path, credential: credential, exitCode: exitCode)
        case (let .identity(canonicalIdentity), let .identity(quarantineIdentity), let .identity(temporaryIdentity))
            where canonicalIdentity != candidateIdentity && quarantineIdentity == journal.expectedIdentity && temporaryIdentity == candidateIdentity && journal.phase != .published:
            // A concurrent writer installed a distinct canonical file after
            // quarantine. Its file wins; discard only our verified stale
            // replacement and the verified prior generation.
            try removePersistentTokenLeaf(parent, leaf: temporaryLeaf, path: path, credential: credential, exitCode: exitCode)
            try removePersistentTokenLeaf(parent, leaf: journal.quarantineLeaf, path: path, credential: credential, exitCode: exitCode)
        case (let .identity(canonicalIdentity), let .identity(quarantineIdentity), .absent)
            where canonicalIdentity == candidateIdentity && quarantineIdentity == journal.expectedIdentity && journal.phase != .prepared:
            try removePersistentTokenLeaf(parent, leaf: journal.quarantineLeaf, path: path, credential: credential, exitCode: exitCode)
        case (let .identity(canonicalIdentity), .absent, .absent)
            where canonicalIdentity == candidateIdentity && journal.phase != .prepared:
            break
        default:
            throw persistentTokenPathError("token transaction state is ambiguous", path: path, credential: credential, exitCode: exitCode)
        }
    case .revocation:
        guard journal.candidateIdentity == nil else {
            throw persistentTokenPathError("token transaction state is ambiguous", path: path, credential: credential, exitCode: exitCode)
        }
        switch (canonical, quarantined, temporary) {
        case (let .identity(canonicalIdentity), .absent, .absent)
            where canonicalIdentity == journal.expectedIdentity && journal.phase == .prepared:
            break
        case (.absent, let .identity(quarantineIdentity), .absent)
            where quarantineIdentity == journal.expectedIdentity && journal.phase == .quarantined:
            try renamePersistentTokenFile(parent, from: journal.quarantineLeaf, to: parent.leaf, flags: RENAME_EXCL, path: path, credential: credential, exitCode: exitCode)
        case (.absent, .absent, .absent):
            // Only a journal explicitly recording revocation may represent a
            // completed delete or an irrevocably lost quarantine entry. A
            // replacement never takes this path because it has a candidate.
            break
        default:
            throw persistentTokenPathError("token transaction state is ambiguous", path: path, credential: credential, exitCode: exitCode)
        }
    }
    try removePersistentTokenTransactionJournal(parent, path: path, credential: credential, exitCode: exitCode)
}

private func writePersistentTokenTransactionJournal(
    _ parent: PersistentTokenParentDirectory,
    quarantineLeaf: String,
    expectedIdentity: PersistentTokenFileIdentity,
    operation: PersistentTokenTransactionOperation,
    candidateIdentity: PersistentTokenFileIdentity?,
    path: String,
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode,
    mutationHook: ((PersistentTokenFileMutationPhase) throws -> Void)?
) throws {
    try installPersistentTokenTransactionJournal(
        parent,
        journal: PersistentTokenTransactionJournal(
            quarantineLeaf: quarantineLeaf,
            expectedIdentity: expectedIdentity,
            operation: operation,
            candidateIdentity: candidateIdentity,
            phase: .prepared
        ),
        replacingExisting: false,
        path: path,
        credential: credential,
        exitCode: exitCode,
        mutationHook: mutationHook,
        errorMessage: "cannot begin token transaction"
    )
}

private func updatePersistentTokenTransactionJournal(
    _ parent: PersistentTokenParentDirectory,
    journal: PersistentTokenTransactionJournal,
    path: String,
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode,
    mutationHook: ((PersistentTokenFileMutationPhase) throws -> Void)?
) throws {
    try installPersistentTokenTransactionJournal(
        parent,
        journal: journal,
        replacingExisting: true,
        path: path,
        credential: credential,
        exitCode: exitCode,
        mutationHook: mutationHook,
        errorMessage: "cannot synchronize token transaction"
    )
}

private func installPersistentTokenTransactionJournal(
    _ parent: PersistentTokenParentDirectory,
    journal: PersistentTokenTransactionJournal,
    replacingExisting: Bool,
    path: String,
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode,
    mutationHook: ((PersistentTokenFileMutationPhase) throws -> Void)?,
    errorMessage: String
) throws {
    let journalLeaf = persistentTokenTransactionJournalLeaf(parent.leaf)
    let temporaryLeaf = persistentTokenTransactionJournalTemporaryLeaf(parent.leaf)
    let descriptor = openat(parent.descriptor, temporaryLeaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
        throw persistentTokenPathError(errorMessage, path: path, credential: credential, exitCode: exitCode)
    }
    var installed = false
    defer {
        _ = close(descriptor)
        if !installed {
            try? removePersistentTokenLeaf(parent, leaf: temporaryLeaf, path: path, credential: credential, exitCode: exitCode)
        }
    }
    do {
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw POSIXError(.EIO) }
        try writePersistentTokenTransactionJournalData(journal, to: descriptor)
        guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
        try mutationHook?(.beforeJournalInstall)
        if replacingExisting {
            guard renameat(parent.descriptor, temporaryLeaf, parent.descriptor, journalLeaf) == 0 else { throw POSIXError(.EIO) }
        } else {
            guard renameatx_np(parent.descriptor, temporaryLeaf, parent.descriptor, journalLeaf, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(.EIO)
            }
        }
        installed = true
        guard fsync(parent.descriptor) == 0 else { throw POSIXError(.EIO) }
    } catch {
        throw persistentTokenPathError(errorMessage, path: path, credential: credential, exitCode: exitCode)
    }
}

private func persistentTokenTransactionJournal(
    _ parent: PersistentTokenParentDirectory,
    path: String,
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode
) throws -> PersistentTokenTransactionJournal? {
    let journalLeaf = persistentTokenTransactionJournalLeaf(parent.leaf)
    let descriptor = openat(parent.descriptor, journalLeaf, O_RDONLY | O_NOFOLLOW)
    if descriptor < 0 {
        if errno == ENOENT { return nil }
        throw persistentTokenPathError("cannot recover token transaction", path: path, credential: credential, exitCode: exitCode)
    }
    defer { _ = close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_size > 0,
          metadata.st_size < 1024 else {
        throw persistentTokenPathError("token transaction journal is invalid", path: path, credential: credential, exitCode: exitCode)
    }
    var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size))
    let count = read(descriptor, &bytes, bytes.count)
    guard count == bytes.count,
          let journal = try? JSONDecoder().decode(PersistentTokenTransactionJournal.self, from: Data(bytes)),
          journal.quarantineLeaf.hasPrefix(".\(parent.leaf)."),
          journal.quarantineLeaf.hasSuffix(".quarantine"),
          !journal.quarantineLeaf.contains("/") else {
        throw persistentTokenPathError("token transaction journal is invalid", path: path, credential: credential, exitCode: exitCode)
    }
    return journal
}

private func removePersistentTokenTransactionJournalTemporaries(
    _ parent: PersistentTokenParentDirectory,
    path: String,
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode
) throws {
    let duplicate = dup(parent.descriptor)
    guard duplicate >= 0, let directory = fdopendir(duplicate) else {
        if duplicate >= 0 { _ = close(duplicate) }
        throw persistentTokenPathError("cannot recover token transaction", path: path, credential: credential, exitCode: exitCode)
    }
    defer { _ = closedir(directory) }
    let prefix = persistentTokenTransactionJournalTemporaryPrefix(parent.leaf)
    while let entry = readdir(directory) {
        let name = entry.pointee.d_name
        let leaf = withUnsafePointer(to: name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: name)) {
                String(cString: $0)
            }
        }
        guard leaf.hasPrefix(prefix), leaf.hasSuffix(".tmp") else { continue }
        switch try persistentTokenFileCurrentState(parent, leaf: leaf) {
        case .absent:
            continue
        case .identity:
            try removePersistentTokenLeaf(parent, leaf: leaf, path: path, credential: credential, exitCode: exitCode)
        case .unsafe:
            throw persistentTokenPathError("token transaction contains an unsafe journal temporary file", path: path, credential: credential, exitCode: exitCode)
        }
    }
}

private func writePersistentTokenTransactionJournalData(
    _ journal: PersistentTokenTransactionJournal,
    to descriptor: Int32
) throws {
    let data = try JSONEncoder().encode(journal)
    var offset = 0
    try data.withUnsafeBytes { bytes in
        while offset < bytes.count {
            let written = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            guard written > 0 else { throw POSIXError(.EIO) }
            offset += written
        }
    }
}

private func removePersistentTokenTransactionJournal(
    _ parent: PersistentTokenParentDirectory,
    path: String,
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode
) throws {
    try removePersistentTokenLeaf(parent, leaf: persistentTokenTransactionJournalLeaf(parent.leaf), path: path, credential: credential, exitCode: exitCode)
}

private func removePersistentTokenLeaf(
    _ parent: PersistentTokenParentDirectory,
    leaf: String,
    path: String,
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode
) throws {
    guard unlinkat(parent.descriptor, leaf, 0) == 0, fsync(parent.descriptor) == 0 else {
        throw persistentTokenPathError("cannot synchronize token transaction", path: path, credential: credential, exitCode: exitCode)
    }
}

private func persistentTokenPathError(
    _ message: String,
    path: String,
    credential: CredentialConfig,
    exitCode: GmailGatewayExitCode
) -> GmailGatewayError {
    GmailGatewayError(
        message,
        code: .authRequired,
        exitCode: exitCode,
        details: ["credentialId": credential.id, "tokenStorePath": path]
    )
}
