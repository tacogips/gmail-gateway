import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@_spi(Testing)
public enum GmailCredentialLifecycleLockEvent: Equatable, Sendable {
    case contended
}

private final class PersistentCredentialLifecycleLock: @unchecked Sendable {
    private let descriptor: Int32
    private let path: String

    init(
        credential: CredentialConfig,
        lockDirectoryPath: String? = nil
    ) throws {
        guard lifecycleLockLeafIsSafe(credential.id) else {
            throw lifecycleLockError(credential: credential, path: lockDirectoryPath ?? "auth-locks")
        }
        let directoryPath = lockDirectoryPath ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/gmail-gateway/auth-locks", isDirectory: true).path
        let directory = try lockDirectoryPath.map { try openExistingPrivateDirectory(at: $0, credential: credential) }
            ?? openOrCreatePrivateLifecycleLockDirectory(credential: credential)
        defer { _ = close(directory) }

        let leaf = "\(credential.id)-\(credential.accessMode.rawValue).lock"
        path = "\(directoryPath)/\(leaf)"
        descriptor = openat(directory, leaf, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw lifecycleLockError(credential: credential, path: path)
        }
        guard lifecycleLockFileIsPrivate(descriptor) else {
            close(descriptor)
            throw lifecycleLockError(credential: credential, path: path)
        }
    }

    func acquire(
        credential: CredentialConfig,
        lifecycleLockEvent: @escaping @Sendable (GmailCredentialLifecycleLockEvent) -> Void
    ) async throws {
        var reportedContention = false
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let lockError = errno
            guard lockError == EWOULDBLOCK || lockError == EAGAIN else {
                throw lifecycleLockError(credential: credential, path: path)
            }
            if !reportedContention {
                // This event follows a kernel-confirmed contention result and is
                // used only by deterministic production-boundary test fixtures.
                lifecycleLockEvent(.contended)
                reportedContention = true
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func acquireBlocking(
        credential: CredentialConfig,
        lifecycleLockEvent: @escaping @Sendable (GmailCredentialLifecycleLockEvent) -> Void
    ) throws {
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let lockError = errno
            guard lockError == EWOULDBLOCK || lockError == EAGAIN else {
                throw lifecycleLockError(credential: credential, path: path)
            }
            lifecycleLockEvent(.contended)
            guard flock(descriptor, LOCK_EX) == 0 else {
                throw lifecycleLockError(credential: credential, path: path)
            }
        }
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
}

func withPersistentCredentialLifecycleLock<T>(
    credential: CredentialConfig,
    lifecycleLockEvent: @escaping @Sendable (GmailCredentialLifecycleLockEvent) -> Void = { _ in },
    operation: () async throws -> T
) async throws -> T {
    let lock = try PersistentCredentialLifecycleLock(credential: credential)
    try await lock.acquire(credential: credential, lifecycleLockEvent: lifecycleLockEvent)
    defer { _ = lock }
    return try await operation()
}

/// Test-only SPI for external fixtures that prove separate processes use this
/// production lifecycle-lock implementation. A private injected directory
/// keeps the fixture out of the developer's real lifecycle-lock namespace.
@_spi(Testing)
public func withGmailPersistentCredentialLifecycleLockForTesting<T>(
    credentialID: String,
    accessMode: AccessMode,
    lockDirectoryPath: String? = nil,
    lifecycleLockEvent: @escaping @Sendable (GmailCredentialLifecycleLockEvent) -> Void = { _ in },
    operation: () throws -> T
) throws -> T {
    let credential = CredentialConfig(
        id: credentialID,
        provider: .gmail,
        accessMode: accessMode,
        oauthClientSecretPath: "/not-used-client",
        oauthClientSecretJSON: nil,
        tokenStorePath: "/not-used-token",
        tokenStoreJSON: nil
    )
    let lock = try PersistentCredentialLifecycleLock(
        credential: credential,
        lockDirectoryPath: lockDirectoryPath
    )
    try lock.acquireBlocking(credential: credential, lifecycleLockEvent: lifecycleLockEvent)
    defer { _ = lock }
    return try operation()
}

private func lifecycleLockLeafIsSafe(_ credentialID: String) -> Bool {
    !credentialID.isEmpty && credentialID != "." && credentialID != ".." &&
        !credentialID.contains("/") && !credentialID.contains("\0")
}

private func openOrCreatePrivateLifecycleLockDirectory(credential: CredentialConfig) throws -> Int32 {
    let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    var descriptor = try openExistingDirectoryWithoutFollowingSymlinks(at: homePath, credential: credential)
    var ownsDescriptor = true
    defer {
        if ownsDescriptor {
            _ = close(descriptor)
        }
    }
    for component in [".local", "state", "gmail-gateway", "auth-locks"] {
        if mkdirat(descriptor, component, S_IRWXU) != 0, errno != EEXIST {
            throw lifecycleLockError(credential: credential, path: homePath)
        }
        let child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else {
            throw lifecycleLockError(credential: credential, path: homePath)
        }
        _ = close(descriptor)
        descriptor = child
    }
    guard privateDirectoryIsOwnedByCurrentUser(descriptor) else {
        throw lifecycleLockError(credential: credential, path: homePath)
    }
    ownsDescriptor = false
    return descriptor
}

private func openExistingPrivateDirectory(at path: String, credential: CredentialConfig) throws -> Int32 {
    let descriptor = try openExistingDirectoryWithoutFollowingSymlinks(at: path, credential: credential)
    guard privateDirectoryIsOwnedByCurrentUser(descriptor) else {
        _ = close(descriptor)
        throw lifecycleLockError(credential: credential, path: path)
    }
    return descriptor
}

private func openExistingDirectoryWithoutFollowingSymlinks(at path: String, credential: CredentialConfig) throws -> Int32 {
    guard path.hasPrefix("/") else {
        throw lifecycleLockError(credential: credential, path: path)
    }
    var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw lifecycleLockError(credential: credential, path: path)
    }
    for component in path.split(separator: "/") {
        let child = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else {
            _ = close(descriptor)
            throw lifecycleLockError(credential: credential, path: path)
        }
        _ = close(descriptor)
        descriptor = child
    }
    return descriptor
}

private func privateDirectoryIsOwnedByCurrentUser(_ descriptor: Int32) -> Bool {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFDIR,
          metadata.st_uid == geteuid() else {
        return false
    }
    guard fchmod(descriptor, S_IRWXU) == 0, fstat(descriptor, &metadata) == 0 else {
        return false
    }
    return (metadata.st_mode & S_IFMT) == S_IFDIR && metadata.st_uid == geteuid() && (metadata.st_mode & 0o077) == 0
}

private func lifecycleLockFileIsPrivate(_ descriptor: Int32) -> Bool {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_uid == geteuid() else {
        return false
    }
    guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0, fstat(descriptor, &metadata) == 0 else {
        return false
    }
    return (metadata.st_mode & S_IFMT) == S_IFREG && metadata.st_uid == geteuid() && (metadata.st_mode & 0o077) == 0
}

private func lifecycleLockError(credential: CredentialConfig, path: String) -> GmailGatewayError {
    GmailGatewayError(
        "cannot lock persistent credential lifecycle",
        code: .authRequired,
        exitCode: .authenticationBootstrapError,
        details: ["credentialId": credential.id, "tokenStorePath": path]
    )
}
