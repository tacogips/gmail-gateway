import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A process-lifetime transport avoids Linux `_MultiHandle.deinit` crashes.
/// Each request owns its delegate, byte limit, credentials and cancellation.
enum GmailBoundedReadHTTPSession {
    static let processLifetime = make()

    static func make(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }
}
