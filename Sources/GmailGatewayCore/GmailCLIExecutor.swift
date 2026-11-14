import Dispatch

/// Synchronous CLI callers may themselves occupy Swift's cooperative workers.
/// Keep their awaited GraphQL work on dispatch-backed executor jobs instead.
@available(macOS 15.0, *)
final class GmailCLIExecutor: TaskExecutor {
    static let shared = GmailCLIExecutor()
    private let queue = DispatchQueue(label: "gmail-gateway.cli.executor", qos: .userInitiated, attributes: .concurrent)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async {
            job.runSynchronously(on: executor)
        }
    }
}
