import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Retry budget for a single rejected write, never a whole GraphQL operation.
public struct GmailWriteRetryPolicy: Sendable, Equatable {
  public let initialWaitSeconds: Int
  public let maxRetries: Int
  public static let `default` = Self(validatedWait: 2, retries: 3)
  public static let disabled = Self(validatedWait: 2, retries: 0)

  public init(initialWaitSeconds: Int = 2, maxRetries: Int = 3) throws {
    guard (1...60).contains(initialWaitSeconds), (0...5).contains(maxRetries) else {
      throw GmailGatewayError("write_retry requires initial_wait_seconds in 1...60 and max_retries in 0...5",
        code: .configInvalid, exitCode: .configurationError)
    }
    self.init(validatedWait: initialWaitSeconds, retries: maxRetries)
  }

  private init(validatedWait: Int, retries: Int) {
    initialWaitSeconds = validatedWait
    maxRetries = retries
  }

  func delay(retryIndex: Int) -> TimeInterval {
    min(Double(initialWaitSeconds) * pow(2, Double(min(max(retryIndex, 0), 5))), 60)
  }

  static func load(record: [String: Any] = [:], environment: [String: String]) throws -> Self {
    let allowed: Set<String> = ["initial_wait_seconds", "max_retries"]
    guard Set(record.keys).isSubset(of: allowed) else {
      throw invalidSetting()
    }
    func value(_ key: String, _ suffix: String, _ fallback: Int) throws -> Int {
      if let text = environment["GMAIL_GATEWAY_WRITE_RETRY_" + suffix] {
        guard !text.isEmpty, text.utf8.count <= 2, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let result = Int(text) else { throw invalidSetting() }
        return result
      }
      guard let raw = record[key] else { return fallback }
      guard type(of: raw) == Int.self, let result = raw as? Int else { throw invalidSetting() }
      return result
    }
    return try Self(initialWaitSeconds: value("initial_wait_seconds", "INITIAL_WAIT_SECONDS", 2),
      maxRetries: value("max_retries", "MAX_RETRIES", 3))
  }

  private static func invalidSetting() -> GmailGatewayError {
    GmailGatewayError("Invalid write_retry configuration", code: .configInvalid, exitCode: .configurationError)
  }
}

func gmailWriteRetrySleep(_ seconds: TimeInterval) throws {
  let deadline = ProcessInfo.processInfo.systemUptime + seconds
  repeat {
    try GmailWriteExecutionContext.check()
    try GmailGatewayProviderCancellationContext.throwIfCancelled()
    let remaining = deadline - ProcessInfo.processInfo.systemUptime
    if remaining <= 0 { return }
    Thread.sleep(forTimeInterval: min(remaining, 0.05))
  } while true
}

/// Only documented quota reasons, never arbitrary provider text, authorize replay.
func gmailWriteWasRateLimited(status: Int, data: Data) -> Bool {
  if status == 429 { return true }
  guard status == 403, data.count <= 65_536,
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let error = object["error"] as? [String: Any],
        let errors = error["errors"] as? [[String: Any]], !errors.isEmpty, errors.count <= 16 else { return false }
  return errors.allSatisfy { entry in
    guard let reason = entry["reason"] as? String else { return false }
    return reason == "rateLimitExceeded" || reason == "userRateLimitExceeded"
  }
}

func gmailWriteFailedBeforeConnection(_ error: Error) -> Bool {
  let value = error as NSError
  guard value.domain == NSURLErrorDomain else { return false }
  return [URLError.cannotFindHost.rawValue, URLError.dnsLookupFailed.rawValue,
          URLError.cannotConnectToHost.rawValue, URLError.notConnectedToInternet.rawValue].contains(value.code)
}

struct GmailWriteNotDispatched: Error {
  let error: GmailGatewayError
}

/// Do not follow a mutation redirect: a later connection failure would no longer
/// prove the original write was never sent. Reads retain their existing session.
final class GmailWriteRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

/// Honor the provider minimum without exceeding the bounded wait policy. A valid
/// minimum above60seconds stops retries instead of sending too early.
func gmailWriteRetryDelay(
  policy: GmailWriteRetryPolicy, retryIndex: Int,
  response: HTTPURLResponse, now: Date = Date()
) -> TimeInterval? {
  let baseline = policy.delay(retryIndex: retryIndex)
  guard let header = response.value(forHTTPHeaderField: "Retry-After") else { return baseline }
  let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
  if !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) {
    guard value.utf8.count <= 20, let seconds = UInt64(value), seconds <= 60 else { return nil }
    return max(baseline, Double(seconds))
  }
  guard value.utf8.count <= 128 else { return baseline }
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
  formatter.isLenient = false
  guard let date = formatter.date(from: value) else { return baseline }
  let seconds = ceil(date.timeIntervalSince(now))
  guard seconds <= 60 else { return nil }
  return max(baseline, seconds)
}
