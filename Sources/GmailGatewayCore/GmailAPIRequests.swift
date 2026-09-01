import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

func fullQueryItems() -> [URLQueryItem] {
    [
        URLQueryItem(name: "format", value: "full")
    ]
}

func gmailURLComponents(path: String) -> URLComponents {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "gmail.googleapis.com"
    components.path = path
    return components
}

func urlPathEncode(_ value: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

func getGmailObject<T: Decodable>(
    components: URLComponents,
    accessToken: String,
    context: String,
    as type: T.Type
) throws -> T {
    let data = try getGmailData(components: components, accessToken: accessToken, context: context)
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch {
        throw GmailGatewayError(
            "Gmail API response was not a JSON object",
            code: .providerApiError,
            exitCode: .providerApiError
        )
    }
}

func getGmailData(
    components: URLComponents,
    accessToken: String,
    context: String
) throws -> Data {
    guard let url = components.url else {
        throw GmailGatewayError(
            "Failed to construct Gmail API URL",
            code: .providerApiError,
            exitCode: .providerApiError
        )
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 30
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    let response = try performGmailHTTPRequest(request, context: context)
    return response.data
}

func postGmailJSONObject(
    path: String,
    accessToken: String,
    body: [String: Any],
    context: String
) throws -> [String: Any] {
    try gmailJSONObject(method: "POST", path: path, accessToken: accessToken, body: body, context: context)
}

func putGmailJSONObject(
    path: String,
    accessToken: String,
    body: [String: Any],
    context: String
) throws -> [String: Any] {
    try gmailJSONObject(method: "PUT", path: path, accessToken: accessToken, body: body, context: context)
}

func deleteGmailResource(
    path: String,
    accessToken: String,
    context: String
) throws {
    var request = try gmailJSONRequest(method: "DELETE", path: path, accessToken: accessToken)
    request.setValue(nil, forHTTPHeaderField: "Content-Type")
    _ = try performGmailHTTPRequest(request, context: context)
}

private func gmailJSONObject(
    method: String,
    path: String,
    accessToken: String,
    body: [String: Any],
    context: String
) throws -> [String: Any] {
    var request = try gmailJSONRequest(method: method, path: path, accessToken: accessToken)
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    let response = try performGmailHTTPRequest(request, context: context)
    guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
        throw GmailGatewayError(
            "Gmail API response was not a JSON object",
            code: .providerApiError,
            exitCode: .providerApiError
        )
    }
    return object
}

private func gmailJSONRequest(
    method: String,
    path: String,
    accessToken: String
) throws -> URLRequest {
    guard let url = gmailURLComponents(path: path).url else {
        throw GmailGatewayError(
            "Failed to construct Gmail API URL",
            code: .providerApiError,
            exitCode: .providerApiError
        )
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 30
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
}
