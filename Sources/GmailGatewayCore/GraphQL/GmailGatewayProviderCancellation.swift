import Foundation

/// Owns cancellation for all provider work started by one GraphQL execution.
/// Provider services are synchronous, so the executor installs this context at
/// the async boundary and each URLSession task cooperates with it.
final class GmailGatewayProviderCancellation: @unchecked Sendable {
    private struct ActiveTask {
        let task: URLSessionDataTask
        let cancelsWhenExecutionIsCancelled: Bool
    }

    private let lock = NSLock()
    private var isCancelled = false
    private var activeTasks: [UUID: ActiveTask] = [:]

    func start(
        _ task: URLSessionDataTask,
        cancelsWhenExecutionIsCancelled: Bool
    ) throws -> UUID {
        lock.lock()
        defer { lock.unlock() }
        try throwIfCancelledLocked()
        let identifier = UUID()
        activeTasks[identifier] = .init(
            task: task,
            cancelsWhenExecutionIsCancelled: cancelsWhenExecutionIsCancelled
        )
        task.resume()
        return identifier
    }

    func finish(_ identifier: UUID) {
        lock.lock()
        activeTasks.removeValue(forKey: identifier)
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let tasks = activeTasks.values
            .filter(\.cancelsWhenExecutionIsCancelled)
            .map(\.task)
        lock.unlock()
        for task in tasks {
            task.cancel()
        }
    }

    func throwIfCancelled() throws {
        lock.lock()
        defer { lock.unlock() }
        try throwIfCancelledLocked()
    }

    func cancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    private func throwIfCancelledLocked() throws {
        guard !isCancelled else {
            throw GmailGatewayError(
                "GraphQL execution was cancelled",
                code: .cancelled,
                exitCode: .graphqlExecutionError
            )
        }
    }
}

enum GmailGatewayProviderCancellationContext {
    @TaskLocal static var current: GmailGatewayProviderCancellation?

    static func throwIfCancelled() throws {
        try current?.throwIfCancelled()
    }

    static func start(
        _ task: URLSessionDataTask,
        cancelsWhenExecutionIsCancelled: Bool
    ) throws -> UUID? {
        try current?.start(
            task,
            cancelsWhenExecutionIsCancelled: cancelsWhenExecutionIsCancelled
        )
    }

    static func finish(_ identifier: UUID?) {
        guard let identifier else { return }
        current?.finish(identifier)
    }

    static var cancelled: Bool {
        current?.cancelled() ?? false
    }
}
