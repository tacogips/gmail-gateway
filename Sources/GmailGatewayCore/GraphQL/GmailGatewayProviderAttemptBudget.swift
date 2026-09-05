import Foundation

/// A request-scoped guard for actual Gmail HTTP attempts. It deliberately lives
/// below resolver planning so retries and attachment downloads consume the same
/// limit as ordinary provider calls.
final class GmailGatewayProviderAttemptBudget: @unchecked Sendable {
    private let maximumRequests: Int
    private let lock = NSLock()
    private var consumedRequests = 0

    init(maximumRequests: Int = GmailGatewayProviderBudget.maximumRequests) {
        self.maximumRequests = maximumRequests
    }

    func consumeAttempt() throws {
        lock.lock()
        defer { lock.unlock() }
        guard consumedRequests < maximumRequests else {
            throw GmailGatewayError(
                "RESOURCE_LIMIT: gmail provider request budget exceeds \(maximumRequests)",
                code: .resourceLimit,
                exitCode: .graphqlExecutionError
            )
        }
        consumedRequests += 1
    }

    var consumedAttemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return consumedRequests
    }
}

enum GmailGatewayProviderAttemptBudgetContext {
    @TaskLocal static var current: GmailGatewayProviderAttemptBudget?

    static func consumeAttempt() throws {
        try current?.consumeAttempt()
    }
}
