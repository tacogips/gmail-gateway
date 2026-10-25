import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A single bounded read. No disk cache, cookies, redirects, or mutation retries.
final class GmailBoundedRead: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    @TaskLocal static var transportSession: URLSession?

    private let maximumBytes: Int
    private let lock = NSLock()
    private let completed = DispatchSemaphore(value: 0)
    private var bytes = Data()
    private var response: HTTPURLResponse?
    private var failure: Error?

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    static func get(_ components: URLComponents, token: String, maximumBytes: Int) throws -> Data {
        try GmailGatewayProviderCancellationContext.throwIfCancelled()
        guard let url = components.url, url.scheme == "https", url.host == "gmail.googleapis.com",
              url.user == nil, url.password == nil, url.port == nil, maximumBytes > 0 else {
            throw GmailGatewayError("Invalid bounded Gmail request", code: .invalidArgument, exitCode: .graphqlExecutionError)
        }
        try GmailGatewayProviderAttemptBudgetContext.consumeAttempt()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let receiver = GmailBoundedRead(maximumBytes: maximumBytes)
        let session = transportSession ?? GmailBoundedReadHTTPSession.processLifetime
        let task = session.dataTask(with: request)
        task.delegate = receiver
        let identifier = try GmailGatewayProviderCancellationContext.start(task, cancelsWhenExecutionIsCancelled: true)
        defer { GmailGatewayProviderCancellationContext.finish(identifier) }
        if identifier == nil { task.resume() }
        guard receiver.completed.wait(timeout: .now() + 30) == .success else {
            task.cancel()
            throw boundedReadError(.timeout)
        }
        try GmailGatewayProviderCancellationContext.throwIfCancelled()
        return try receiver.result()
    }

    private func result() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        guard let response else {
            throw boundedReadError(.missingResponse)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw GmailGatewayError("Gmail bounded read failed", code: .providerApiError, exitCode: .providerApiError,
                                    details: ["httpStatus": String(response.statusCode)])
        }
        return bytes
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        self.response = response as? HTTPURLResponse
        let oversized = response.expectedContentLength > Int64(maximumBytes)
        if oversized { failure = Self.limitError() }
        lock.unlock()
        completionHandler(oversized ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let oversized = data.count > maximumBytes - bytes.count
        if oversized { failure = Self.limitError() } else if failure == nil { bytes.append(data) }
        lock.unlock()
        if oversized { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if failure == nil, let error {
            failure = boundedReadError(boundedReadFailureReason(error))
        }
        lock.unlock()
        completed.signal()
    }

    private static func limitError() -> GmailGatewayError {
        GmailGatewayError("Gmail response exceeds byte limit", code: .resourceLimit, exitCode: .providerApiError)
    }
}

// Closed transport categories omit URLs, hostnames, localized descriptions and provider bodies.
enum BoundedReadReason: String {
    case timeout, missingResponse, cancelled, dns, connect, connectionLost, tls, offline, transport
}

func boundedReadFailureReason(_ error: Error) -> BoundedReadReason {
    let error = error as NSError
    guard error.domain == NSURLErrorDomain else { return .transport }
    switch error.code {
    case NSURLErrorTimedOut: return .timeout
    case NSURLErrorCancelled: return .cancelled
    case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .dns
    case NSURLErrorCannotConnectToHost: return .connect
    case NSURLErrorNetworkConnectionLost: return .connectionLost
    case NSURLErrorNotConnectedToInternet: return .offline
    case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
         NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
         NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
         NSURLErrorClientCertificateRequired: return .tls
    default: return .transport
    }
}

private func boundedReadError(_ reason: BoundedReadReason) -> GmailGatewayError {
    GmailGatewayError("Bounded Gmail read failed [gmailReadReason=\(reason.rawValue)]",
                      code: .providerApiError, exitCode: .providerApiError)
}
