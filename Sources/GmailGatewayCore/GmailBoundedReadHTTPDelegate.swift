import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Corelibs routes streaming callbacks through the session delegate, even when
/// URLSessionTask.delegate is set. Forward to the receiver owned by that task.
final class GmailBoundedReadHTTPDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let receiver = dataTask.delegate as? GmailBoundedRead else {
            completionHandler(.cancel)
            return
        }
        receiver.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let receiver = dataTask.delegate as? GmailBoundedRead else {
            dataTask.cancel()
            return
        }
        receiver.urlSession(session, dataTask: dataTask, didReceive: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        (task.delegate as? GmailBoundedRead)?.urlSession(session, task: task, didCompleteWithError: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
