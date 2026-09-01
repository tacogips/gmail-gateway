import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class TestGmailRequestCaptureProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedURLs: [URL] = []
    nonisolated(unsafe) static var capturedMethods: [String] = []
    nonisolated(unsafe) static var capturedHTTPBodies: [Data] = []
    nonisolated(unsafe) static var responseStatusCode = 200
    nonisolated(unsafe) static var responseStatusCodes: [Int] = []
    nonisolated(unsafe) static var responseData = Data(#"{"threads":[],"resultSizeEstimate":0}"#.utf8)
    nonisolated(unsafe) static var threadListResponseData: Data?
    nonisolated(unsafe) static var threadGetResponseData: Data?
    nonisolated(unsafe) static var messageGetResponseData: Data?
    nonisolated(unsafe) static var attachmentResponseData: Data?
    nonisolated(unsafe) static var draftListResponseData: Data?
    nonisolated(unsafe) static var draftGetResponseData: Data?
    nonisolated(unsafe) static var draftUpdateResponseData: Data?
    nonisolated(unsafe) static var failAttachmentPayloadRequests = false
    nonisolated(unsafe) static var expectedListMaxResults: String?
    nonisolated(unsafe) static var expectedListPageToken: String?
    nonisolated(unsafe) static var expectedListQuery: String?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "gmail.googleapis.com"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let url = request.url {
            Self.capturedURLs.append(url)
        }
        Self.capturedMethods.append(request.httpMethod ?? "GET")
        if let body = request.httpBody ?? Self.data(from: request.httpBodyStream) {
            Self.capturedHTTPBodies.append(body)
        }
        if request.url?.path == "/gmail/v1/users/me/threads",
           let components = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) {
            let queryItems = components.queryItems ?? []
            let maxResults = queryItems.first(where: { $0.name == "maxResults" })?.value
            let pageToken = queryItems.first(where: { $0.name == "pageToken" })?.value
            let query = queryItems.first(where: { $0.name == "q" })?.value
            if let expected = Self.expectedListMaxResults,
               maxResults != expected {
                respondWithError(message: "unexpected maxResults")
                return
            }
            if let expected = Self.expectedListPageToken,
               pageToken != expected {
                respondWithError(message: "unexpected pageToken")
                return
            }
            if let expected = Self.expectedListQuery,
               query != expected {
                respondWithError(message: "unexpected query")
                return
            }
        }
        if Self.failAttachmentPayloadRequests,
           request.url?.path.contains("/attachments/") == true {
            respondWithError(message: "unexpected attachment payload request")
            return
        }
        let statusCode: Int
        if Self.responseStatusCodes.isEmpty {
            statusCode = Self.responseStatusCode
        } else {
            statusCode = Self.responseStatusCodes.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://gmail.googleapis.com/")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData(for: request))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func respondWithError(message: String) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://gmail.googleapis.com/")!,
            statusCode: 500,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":{"message":"\#(message)"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func responseData(for request: URLRequest) -> Data {
        guard let path = request.url?.path else {
            return Self.responseData
        }
        let method = request.httpMethod?.uppercased() ?? "GET"
        if method == "DELETE" {
            return Data()
        }
        if path == "/gmail/v1/users/me/drafts" {
            return Self.draftListResponseData ?? Self.responseData
        }
        if path.hasPrefix("/gmail/v1/users/me/drafts/") {
            if method == "PUT" {
                return Self.draftUpdateResponseData ?? Self.responseData
            }
            return Self.draftGetResponseData ?? Self.responseData
        }
        if path == "/gmail/v1/users/me/threads" {
            return Self.threadListResponseData ?? Self.responseData
        }
        if path.hasPrefix("/gmail/v1/users/me/threads/") {
            return Self.threadGetResponseData ?? Self.responseData
        }
        if path.contains("/attachments/") {
            return Self.attachmentResponseData ?? Self.responseData
        }
        if path.hasPrefix("/gmail/v1/users/me/messages/") {
            return Self.messageGetResponseData ?? Self.responseData
        }
        return Self.responseData
    }

    private static func data(from stream: InputStream?) -> Data? {
        guard let stream else {
            return nil
        }
        stream.open()
        defer {
            stream.close()
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }

    static func reset() {
        capturedURLs = []
        capturedMethods = []
        capturedHTTPBodies = []
        responseStatusCode = 200
        responseStatusCodes = []
        responseData = Data(#"{"threads":[],"resultSizeEstimate":0}"#.utf8)
        threadListResponseData = nil
        threadGetResponseData = nil
        messageGetResponseData = nil
        attachmentResponseData = nil
        draftListResponseData = nil
        draftGetResponseData = nil
        draftUpdateResponseData = nil
        failAttachmentPayloadRequests = false
        expectedListMaxResults = nil
        expectedListPageToken = nil
        expectedListQuery = nil
    }
}
