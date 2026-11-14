import Foundation
import Testing
@testable import GmailGatewayCore

@Test func doctorIsAvailableFromEveryBinaryAndRedactsEnvironmentValues() throws {
    let fixture = try DoctorFixture(accessMode: .readSend, includeToken: true)
    defer { fixture.remove() }

    for mode in [GmailGatewayCLIMode.reader, .draftGateway, .directSender] {
        let result = GmailGatewayCLI(mode: mode).run(
            arguments: ["doctor", "--config", fixture.configPath],
            environment: fixture.environment
        )
        let output = try decodeDoctorOutput(result.stdout)
        let statuses = try #require(output["environment"] as? [[String: Any]])
        let credentials = try #require(output["credentials"] as? [[String: Any]])
        let credential = try #require(credentials.first)
        let oauth = try #require(credential["oauthClient"] as? [String: Any])
        let auth = try #require(credential["auth"] as? [String: Any])

        #expect(result.exitCode == GmailGatewayExitCode.success.rawValue)
        #expect(output["ok"] as? Bool == true)
        #expect(output["executable"] as? String == modeName(mode))
        #expect(oauth["source"] as? String == "ENVIRONMENT_JSON")
        #expect(auth["source"] as? String == "ENVIRONMENT_JSON")
        #expect(statuses.contains { status in
            status["name"] as? String == fixture.oauthJSONEnvironmentName &&
                status["set"] as? Bool == true &&
                status["selected"] as? Bool == true
        })
        #expect(statuses.contains { status in
            status["name"] as? String == fixture.tokenJSONEnvironmentName &&
                status["set"] as? Bool == true &&
                status["selected"] as? Bool == true
        })
        #expect(!result.stdout.contains("doctor-client-id"))
        #expect(!result.stdout.contains("doctor-access-token"))
        #expect(!result.stdout.contains("doctor-refresh-token"))
    }
}

@Test func doctorReturnsAuthenticationExitCodeWhenOnlyTokenIsMissing() throws {
    let fixture = try DoctorFixture(accessMode: .read, includeToken: false)
    defer { fixture.remove() }

    let result = GmailGatewayCLI().run(
        arguments: ["doctor", "--config", fixture.configPath],
        environment: fixture.environment
    )
    let output = try decodeDoctorOutput(result.stdout)
    let issues = try #require(output["issues"] as? [[String: Any]])

    #expect(result.exitCode == GmailGatewayExitCode.authenticationBootstrapError.rawValue)
    #expect(output["ok"] as? Bool == false)
    #expect(issues.contains { $0["code"] as? String == "AUTH_MISSING" })
    #expect(!issues.contains { $0["category"] as? String == "CONFIGURATION" })
}

@Test func doctorRequiresReadSendAccessForWriteBinaries() throws {
    let fixture = try DoctorFixture(accessMode: .read, includeToken: true)
    defer { fixture.remove() }

    let reader = GmailGatewayCLI().run(
        arguments: ["doctor", "--config", fixture.configPath],
        environment: fixture.environment
    )
    let sender = GmailGatewayCLI(mode: .directSender).run(
        arguments: ["doctor", "--config", fixture.configPath],
        environment: fixture.environment
    )
    let senderOutput = try decodeDoctorOutput(sender.stdout)
    let senderIssues = try #require(senderOutput["issues"] as? [[String: Any]])

    #expect(reader.exitCode == GmailGatewayExitCode.success.rawValue)
    #expect(sender.exitCode == GmailGatewayExitCode.configurationError.rawValue)
    #expect(senderIssues.contains { $0["code"] as? String == "ACCESS_MODE_INSUFFICIENT" })
}

@Test func doctorHelpIsListedForEveryBinary() {
    for mode in [GmailGatewayCLIMode.reader, .draftGateway, .directSender] {
        let result = GmailGatewayCLI(mode: mode).run(arguments: ["--help"], environment: [:])
        #expect(result.stdout.contains("  doctor\n"))
    }
}

private struct DoctorFixture {
    let root: String
    let configPath: String
    let oauthJSONEnvironmentName: String
    let tokenJSONEnvironmentName: String
    let environment: [String: String]

    init(accessMode: AccessMode, includeToken: Bool) throws {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gmail-gateway-doctor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        root = rootURL.path
        configPath = rootURL.appendingPathComponent("config.toml").path
        oauthJSONEnvironmentName = GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
            credentialId: "gmail-personal",
            valueKey: "oauth_client_secret_json"
        )
        tokenJSONEnvironmentName = GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
            credentialId: "gmail-personal",
            valueKey: "token_store_json"
        )
        let config = """
        [storage]
        cache_dir = "cache"
        attachment_dir = "attachments"
        allowed_send_attachment_roots = ["send"]

        [[credentials]]
        id = "gmail-personal"
        provider = "gmail"
        access_mode = "\(accessMode.rawValue)"
        oauth_client_secret_path = "client.json"
        token_store_path = "token.json"

        [[accounts]]
        id = "personal"
        provider = "gmail"
        email_address = "person@example.com"
        credential_id = "gmail-personal"
        default_label_ids = ["INBOX"]
        """
        try Data(config.utf8).write(to: URL(fileURLWithPath: configPath))
        var environment = [
            oauthJSONEnvironmentName: """
            {
              "installed": {
                "client_id": "doctor-client-id",
                "auth_uri": "https://accounts.example.test/o/oauth2/auth",
                "token_uri": "https://tokens.example.test/token"
              }
            }
            """
        ]
        if includeToken {
            environment[tokenJSONEnvironmentName] = """
            {
              "accessMode": "\(accessMode.rawValue)",
              "accessToken": "doctor-access-token",
              "refreshToken": "doctor-refresh-token",
              "expiresAt": "2999-01-01T00:00:00Z",
              "emailAddress": "person@example.com"
            }
            """
        }
        self.environment = environment
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }
}

private func decodeDoctorOutput(_ output: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
}

private func modeName(_ mode: GmailGatewayCLIMode) -> String {
    switch mode {
    case .reader:
        return "gmail-gateway-reader"
    case .draftGateway:
        return "gmail-gateway-draft"
    case .directSender:
        return "gmail-gateway-sender"
    case .mailboxThreads:
        return "gmail-gateway-threads"
    case .messageBox:
        return "gmail-gateway-message-box"
    }
}
