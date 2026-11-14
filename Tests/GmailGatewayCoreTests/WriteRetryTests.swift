import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import GmailGatewayCore

final class WriteRetryTests: XCTestCase {
  override func setUp() {
    super.setUp()
    WriteRetryURLProtocol.responses = []
    WriteRetryURLProtocol.count = 0
    URLProtocol.registerClass(WriteRetryURLProtocol.self)
  }

  override func tearDown() {
    URLProtocol.unregisterClass(WriteRetryURLProtocol.self)
    super.tearDown()
  }

  private func execute(
    policy: GmailWriteRetryPolicy = .default,
    sleep: (TimeInterval) throws -> Void = { _ in }
  ) throws -> Int {
    var request = URLRequest(url: try XCTUnwrap(URL(string: "https://retry.invalid/write")))
    request.httpMethod = "POST"
    request.httpBody = Data("fixed mutation body".utf8)
    return try performGmailHTTPRequest(request, context: "test", effect: .gmailMutation, retryPolicy: policy, sleep: sleep).response.statusCode
  }

  func testTOMLAndSuppliedEnvironmentReachSDKConfiguration() throws {
    let paths = temporaryConfigPaths()
    defer { try? FileManager.default.removeItem(atPath: paths.root) }
    let directory = URL(fileURLWithPath: paths.root)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let configPath = paths.root + "/config.toml"
    let original = """
    [storage]
    cache_dir = "cache"
    attachment_dir = "attachments"
    allowed_send_attachment_roots = []
    [[credentials]]
    id = "test"
    provider = "gmail"
    access_mode = "read_send"
    oauth_client_secret_path = "client.json"
    token_store_path = "token.json"
    [[accounts]]
    id = "personal"
    provider = "gmail"
    email_address = "fixture@example.invalid"
    credential_id = "test"
    default_label_ids = ["INBOX"]
    """
    let source = original + "\n[write_retry]\ninitial_wait_seconds = 9\nmax_retries = 1\n"
    try source.write(toFile: configPath, atomically: true, encoding: .utf8)
    let config = try GmailGatewayConfigLoader.loadConfig(configPath: configPath, environment: [:])
    XCTAssertEqual(config.writeRetry, try GmailWriteRetryPolicy(initialWaitSeconds: 9, maxRetries: 1))
    let overridden = try GmailGatewayConfigLoader.loadConfig(configPath: configPath,
      environment: ["GMAIL_GATEWAY_WRITE_RETRY_MAX_RETRIES": "0"])
    XCTAssertEqual(overridden.writeRetry.maxRetries, 0)
    XCTAssertEqual(overridden.writeRetry.initialWaitSeconds, 9)
  }

  func testMutationRedirectDelegateDeclinesReplay() throws {
    let url = try XCTUnwrap(URL(string: "https://retry.invalid/write"))
    let task = URLSession.shared.dataTask(with: url)
    let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: [:]))
    let done = expectation(description: "redirect decision")
    GmailWriteRedirectBlocker().urlSession(URLSession.shared, task: task,
      willPerformHTTPRedirection: response, newRequest: URLRequest(url: url)) { redirected in
        XCTAssertNil(redirected)
        done.fulfill()
      }
    wait(for: [done], timeout: 1)
    task.cancel()
  }

  func testRetryAfterMinimumAndBoundedStop() throws {
    for (header, delay) in [("30", 30.0), ("unknown-private-value", 2.0)] {
      WriteRetryURLProtocol.responses = [.limited(header), .status(200)]
      WriteRetryURLProtocol.count = 0
      var delays: [Double] = []
      XCTAssertEqual(try execute(sleep: { delays.append($0) }), 200)
      XCTAssertEqual(delays, [delay])
      XCTAssertEqual(WriteRetryURLProtocol.count, 2)
    }
    WriteRetryURLProtocol.responses = [.limited("61"), .status(200)]
    WriteRetryURLProtocol.count = 0
    XCTAssertThrowsError(try execute(sleep: { _ in XCTFail("provider minimum exceeds cap") }))
    XCTAssertEqual(WriteRetryURLProtocol.count, 1)
    let now = Date(timeIntervalSince1970: 0)
    let url = try XCTUnwrap(URL(string: "https://retry.invalid/write"))
    let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil,
      headerFields: ["Retry-After": "Thu, 01 Jan 1970 00:00:30 GMT"]))
    XCTAssertEqual(gmailWriteRetryDelay(policy: .default, retryIndex: 0, response: response, now: now), 30)
  }

  func testExpiredDeadlinePreventsInitialAttemptAndFurtherRetries() throws {
    WriteRetryURLProtocol.responses = [.status(200)]
    XCTAssertThrowsError(try GmailWriteExecutionContext.withDeadline(Date.distantPast) { try execute() }) { error in
      XCTAssertEqual((error as? GmailGatewayError)?.code, .cancelled)
    }
    XCTAssertEqual(WriteRetryURLProtocol.count, 0)
    WriteRetryURLProtocol.responses = [.status(429), .status(200)]
    let clock = WriteRetryClock()
    XCTAssertThrowsError(try GmailWriteExecutionContext.$currentDate.withValue({ clock.read() }, operation: {
      try GmailWriteExecutionContext.withDeadline(Date(timeIntervalSince1970: 1)) {
        try execute(sleep: { _ in clock.advance() })
      }
    }))
    XCTAssertEqual(WriteRetryURLProtocol.count, 1)
    XCTAssertThrowsError(try GmailWriteExecutionContext.withDeadline(Date.distantPast) {
      try GmailWriteExecutionContext.withDeadline(Date.distantFuture) { try execute() }
    })
    XCTAssertEqual(WriteRetryURLProtocol.count, 1)
  }

  func testDefaultAndBoundedPolicy() throws {
    XCTAssertEqual(GmailWriteRetryPolicy.default.initialWaitSeconds, 2)
    XCTAssertEqual(GmailWriteRetryPolicy.default.maxRetries, 3)
    let policy = try GmailWriteRetryPolicy(initialWaitSeconds: 20, maxRetries: 5)
    XCTAssertEqual((0..<5).map { policy.delay(retryIndex: $0) }, [20, 40, 60, 60, 60])
    for wait in [-1, 0, 61, Int.max] { XCTAssertThrowsError(try GmailWriteRetryPolicy(initialWaitSeconds: wait)) }
    for count in [-1, 6, Int.max] { XCTAssertThrowsError(try GmailWriteRetryPolicy(maxRetries: count)) }
  }

  func testSuppliedEnvironmentOverridesTOMLWithoutAmbientValues() throws {
    let policy = try GmailWriteRetryPolicy.load(record: ["initial_wait_seconds": 7, "max_retries": 1],
      environment: ["GMAIL_GATEWAY_WRITE_RETRY_INITIAL_WAIT_SECONDS": "3", "GMAIL_GATEWAY_WRITE_RETRY_MAX_RETRIES": "0"])
    XCTAssertEqual(policy, try GmailWriteRetryPolicy(initialWaitSeconds: 3, maxRetries: 0))
    XCTAssertEqual(try GmailWriteRetryPolicy.load(environment: [:]), .default)
    for value in ["-1", " 2", "2.5", "true", "999999999999", "secret"] {
      XCTAssertThrowsError(try GmailWriteRetryPolicy.load(environment: ["GMAIL_GATEWAY_WRITE_RETRY_MAX_RETRIES": value]))
    }
    XCTAssertThrowsError(try GmailWriteRetryPolicy.load(record: ["max_retries": true], environment: [:]))
    XCTAssertThrowsError(try GmailWriteRetryPolicy.load(record: ["typo": 1], environment: [:]))
  }

  func testRejectedWriteRetriesExactlyConfiguredBudgetAndBackoff() throws {
    WriteRetryURLProtocol.responses = [.status(429), .status(429), .status(429), .status(200)]
    var delays: [Double] = []
    XCTAssertEqual(try execute(sleep: { delays.append($0) }), 200)
    XCTAssertEqual(delays, [2, 4, 8])
    XCTAssertEqual(WriteRetryURLProtocol.count, 4)
    WriteRetryURLProtocol.count = 0
    WriteRetryURLProtocol.responses = Array(repeating: .status(429), count: 5)
    delays = []
    XCTAssertThrowsError(try execute(sleep: { delays.append($0) }))
    XCTAssertEqual(delays, [2, 4, 8])
    XCTAssertEqual(WriteRetryURLProtocol.count, 4)
  }

  func testZeroDisablesRetriesAndPermanentFailuresDoNotSleep() throws {
    for status in [400, 401, 403, 404, 409, 412, 429] {
      WriteRetryURLProtocol.responses = [.status(status), .status(200)]
      WriteRetryURLProtocol.count = 0
      var delays: [Double] = []
      XCTAssertThrowsError(try execute(policy: .disabled, sleep: { delays.append($0) }))
      XCTAssertEqual(WriteRetryURLProtocol.count, 1)
      XCTAssertTrue(delays.isEmpty)
    }
    for status in [400, 401, 403, 404, 409, 412] {
      WriteRetryURLProtocol.responses = [.status(status), .status(200)]
      WriteRetryURLProtocol.count = 0
      XCTAssertThrowsError(try execute(sleep: { _ in XCTFail("permanent error slept") }))
      XCTAssertEqual(WriteRetryURLProtocol.count, 1)
    }
  }

  func testKnownQuota403RetriesButPermissionAndDailyQuotaDoNot() throws {
    for reason in ["rateLimitExceeded", "userRateLimitExceeded", "forbidden", "dailyLimitExceeded", "arbitrary-secret"] {
      WriteRetryURLProtocol.responses = [.quota(reason), .status(200)]
      WriteRetryURLProtocol.count = 0
      if ["rateLimitExceeded", "userRateLimitExceeded"].contains(reason) {
        XCTAssertEqual(try execute(), 200)
        XCTAssertEqual(WriteRetryURLProtocol.count, 2)
      } else {
        XCTAssertThrowsError(try execute())
        XCTAssertEqual(WriteRetryURLProtocol.count, 1)
      }
    }
    XCTAssertFalse(gmailWriteWasRateLimited(status: 403, data: Data(repeating: 32, count: 65_537)))
    XCTAssertFalse(gmailWriteWasRateLimited(status: 403, data: Data(#"{"error":{"errors":[{"reason":"rateLimitExceeded"},{"reason":"forbidden"}]}}"#.utf8)))
  }

  func testAmbiguousWriteNeverReplays() throws {
    for response in [WriteRetryURLProtocol.Response.status(500), .status(503), .failure(.timedOut), .failure(.networkConnectionLost)] {
      WriteRetryURLProtocol.responses = [response, .status(200)]
      WriteRetryURLProtocol.count = 0
      XCTAssertThrowsError(try execute(sleep: { _ in XCTFail("ambiguous write slept") })) { error in
        XCTAssertEqual((error as? GmailGatewayError)?.code, .mutationOutcomeUnknown)
      }
      XCTAssertEqual(WriteRetryURLProtocol.count, 1)
    }
  }

  func testPreconnectionFailureCanRetryAndCancellationStopsBackoff() throws {
    for code in [URLError.cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .notConnectedToInternet] {
      WriteRetryURLProtocol.responses = [.failure(code), .status(200)]
      WriteRetryURLProtocol.count = 0
      XCTAssertEqual(try execute(), 200)
      XCTAssertEqual(WriteRetryURLProtocol.count, 2)
    }
    WriteRetryURLProtocol.responses = [.status(429), .status(200)]
    WriteRetryURLProtocol.count = 0
    XCTAssertThrowsError(try execute(sleep: { _ in throw CancellationError() })) { error in
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(WriteRetryURLProtocol.count, 1)
  }

  func testConfirmedSuccessDoesNotReplayEvenWithoutResponseBody() throws {
    WriteRetryURLProtocol.responses = [.status(204), .status(200)]
    XCTAssertEqual(try execute(), 204)
    XCTAssertEqual(WriteRetryURLProtocol.count, 1)
  }
}

private final class WriteRetryURLProtocol: URLProtocol {
  enum Response { case status(Int), quota(String), limited(String), failure(URLError.Code) }
  nonisolated(unsafe) static var responses: [Response] = []
  nonisolated(unsafe) static var count = 0
  override static func canInit(with request: URLRequest) -> Bool { request.url?.host == "retry.invalid" }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.count += 1
    let next = Self.responses.isEmpty ? .status(500) : Self.responses.removeFirst()
    let status: Int
    var data = Data()
    var headers: [String: String] = [:]
    switch next {
    case .failure(let code): client?.urlProtocol(self, didFailWithError: URLError(code)); return
    case .status(let value): status = value
    case .limited(let minimum): status = 429; headers["Retry-After"] = minimum
    case .quota(let reason):
      status = 403
      data = (try? JSONSerialization.data(withJSONObject: ["error": ["errors": [["reason": reason]], "message": "private-provider-text"]])) ?? Data()
    }
    guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

private final class WriteRetryClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 0)
  func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
  func advance() { lock.lock(); defer { lock.unlock() }; value = value.addingTimeInterval(2) }
}
