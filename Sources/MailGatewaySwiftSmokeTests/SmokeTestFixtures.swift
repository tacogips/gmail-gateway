import Foundation
import MailGatewayCore

enum SmokeTestFailure: Error, CustomStringConvertible {
    case assertionFailed(String)

    var description: String {
        switch self {
        case .assertionFailed(let message):
            return message
        }
    }
}

struct Fixture {
    let clientSecretPath: String
    let rootDir: String
    let configPath: String
    let cacheRoot: String
    let attachmentRoot: String
    let sendRoot: String
    let tokenPath: String
}

struct FixtureDirectories {
    let configDir: String
    let cacheDir: String
    let attachmentRoot: String
    let sendRoot: String
    let secretsDir: String
    let tokensDir: String
}

func assert(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw SmokeTestFailure.assertionFailed(message)
    }
}

func writeText(_ path: String, _ text: String) throws {
    try FileManager.default.createDirectory(
        atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
        withIntermediateDirectories: true
    )
    try text.write(toFile: path, atomically: true, encoding: .utf8)
}

func createFixture(
    includeCredentialPaths: Bool = true,
    oauthClientSecretPathValue: String? = nil,
    tokenStorePathValue: String? = nil,
    accessMode: AccessMode = .read
) throws -> Fixture {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mail-gateway-\(UUID().uuidString)", isDirectory: true)
    let directories = try createFixtureDirectories(root: root)
    let clientSecretPath = URL(fileURLWithPath: directories.secretsDir)
        .appendingPathComponent("client.json")
        .path
    let tokenPath = URL(fileURLWithPath: directories.tokensDir)
        .appendingPathComponent("account.json")
        .path
    try writeText(clientSecretPath, "{\"installed\":true}\n")

    let configPath = URL(fileURLWithPath: directories.configDir)
        .appendingPathComponent("config.toml")
        .path
    try writeFixtureConfig(
        configPath: configPath,
        includeCredentialPaths: includeCredentialPaths,
        oauthClientSecretPathValue: oauthClientSecretPathValue,
        tokenStorePathValue: tokenStorePathValue,
        accessMode: accessMode
    )

    return Fixture(
        clientSecretPath: clientSecretPath,
        rootDir: root.path,
        configPath: configPath,
        cacheRoot: directories.cacheDir,
        attachmentRoot: directories.attachmentRoot,
        sendRoot: directories.sendRoot,
        tokenPath: tokenPath
    )
}

func createFixtureDirectories(root: URL) throws -> FixtureDirectories {
    let directories = FixtureDirectories(
        configDir: root.appendingPathComponent("config", isDirectory: true).path,
        cacheDir: root.appendingPathComponent("cache", isDirectory: true).path,
        attachmentRoot: root.appendingPathComponent("attachments", isDirectory: true).path,
        sendRoot: root.appendingPathComponent("send", isDirectory: true).path,
        secretsDir: root.appendingPathComponent("secrets", isDirectory: true).path,
        tokensDir: root.appendingPathComponent("tokens", isDirectory: true).path
    )
    for directory in [
        directories.configDir,
        directories.cacheDir,
        directories.attachmentRoot,
        directories.sendRoot,
        directories.secretsDir,
        directories.tokensDir
    ] {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }
    return directories
}

func writeFixtureConfig(
    configPath: String,
    includeCredentialPaths: Bool,
    oauthClientSecretPathValue: String?,
    tokenStorePathValue: String?,
    accessMode: AccessMode = .read
) throws {
    let credentialLines = includeCredentialPaths
        ? """
        oauth_client_secret_path = "\(oauthClientSecretPathValue ?? "../secrets/client.json")"
        token_store_path = "\(tokenStorePathValue ?? "../tokens/account.json")"
        """
        : ""
    try writeText(
        configPath,
        """
        [storage]
        cache_dir = "../cache"
        attachment_dir = "../attachments"
        allowed_send_attachment_roots = ["../send"]

        [[credentials]]
        id = "gmail-personal"
        provider = "gmail"
        access_mode = "\(accessMode.rawValue)"
        \(credentialLines)

        [[accounts]]
        id = "personal"
        provider = "gmail"
        email_address = "person@example.com"
        credential_id = "gmail-personal"
        default_label_ids = ["INBOX"]
        """
    )
}

func decodeObject(_ text: String) throws -> [String: Any] {
    let data = Data(text.utf8)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw SmokeTestFailure.assertionFailed("expected JSON object")
    }
    return object
}

func runCli(_ arguments: [String], env: [String: String] = [:]) -> MailGatewayCommandResult {
    MailGatewayCLI().run(arguments: arguments, environment: env)
}

func runCli(
    _ arguments: [String],
    mode: MailGatewayCLIMode,
    env: [String: String] = [:]
) -> MailGatewayCommandResult {
    MailGatewayCLI(mode: mode).run(arguments: arguments, environment: env)
}

func credentialEnv(fixture: Fixture, oauthPath: String? = nil, tokenPath: String? = nil) -> [String: String] {
    [
        MailGatewayConfigLoader.getCredentialPathEnvVarName(
            credentialId: "gmail-personal",
            pathKey: "oauth_client_secret_path"
        ): oauthPath ?? fixture.clientSecretPath,
        MailGatewayConfigLoader.getCredentialPathEnvVarName(
            credentialId: "gmail-personal",
            pathKey: "token_store_path"
        ): tokenPath ?? fixture.tokenPath
    ]
}

func trackedFixture(
    cleanup: inout [String],
    includeCredentialPaths: Bool = true
) throws -> Fixture {
    let fixture = try createFixture(includeCredentialPaths: includeCredentialPaths)
    cleanup.append(fixture.rootDir)
    return fixture
}

func containsEither(_ text: String, _ lhs: String, _ rhs: String) -> Bool {
    text.contains(lhs) || text.contains(rhs)
}

final class GmailRequestCaptureProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedURLs: [URL] = []
    nonisolated(unsafe) static var responseBody = #"{"threads":[],"resultSizeEstimate":0}"#

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
        let data = Data(Self.responseBody.utf8)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://gmail.googleapis.com/")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        capturedURLs = []
        responseBody = #"{"threads":[],"resultSizeEstimate":0}"#
    }
}
