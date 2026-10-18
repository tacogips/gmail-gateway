import Foundation

/// Request-scoped deadline. It never cancels or replays an already dispatched write.
public enum GmailWriteExecutionContext {
  @TaskLocal private static var deadline: Date?
  @TaskLocal static var currentDate: @Sendable () -> Date = { Date() }

  public static func withDeadline<Result>(_ value: Date?, operation: () throws -> Result) rethrows -> Result {
    try $deadline.withValue(effectiveDeadline(value), operation: operation)
  }

  public static func withDeadline<Result>(_ value: Date?, operation: () async throws -> Result) async rethrows -> Result {
    try await $deadline.withValue(effectiveDeadline(value), operation: operation)
  }

  private static func effectiveDeadline(_ value: Date?) -> Date? {
    guard let value else { return deadline }
    return deadline.map { min($0, value) } ?? value
  }

  static func check() throws {
    guard let deadline, deadline <= currentDate() else { return }
    throw GmailGatewayError("Write execution deadline expired before another attempt",
      code: .cancelled, exitCode: .graphqlExecutionError)
  }
}
