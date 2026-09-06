import Foundation
@testable import GmailGatewayCore
import XCTest

final class PersistentAuthOutputRedactionTests: XCTestCase {
    func testAllPersistentAuthOutputsRedactProtectedValuesForEveryTargetMode() async throws {
        let targets: [(GmailGatewayCLIMode, AccessMode)] = [
            (.reader, .read),
            (.draftGateway, .readSend),
            (.directSender, .readSend)
        ]
        TestGmailRequestCaptureProtocol.reset()
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }

        for (mode, accessMode) in targets {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let configURL = try makeVaultOnlyConfig(at: root, accessMode: accessMode)
            let clientPath = root.appendingPathComponent("client.json")
            let client = redactionClient(for: mode)
            try client.legacyJSON().write(to: clientPath, atomically: true, encoding: .utf8)
            let loginToken = redactionToken(accessMode: accessMode, mode: mode)
            let store = TestSecureCredentialStore()
            let coordinator = GmailAuthCoordinator(
                config: try GmailGatewayConfigLoader.loadConfig(configPath: configURL.path, environment: [:]),
                environment: [:],
                policy: persistentPolicy(for: mode),
                store: store,
                loginResult: { _, _ in
                    GmailOAuthLoginResult(tokenStore: loginToken, redirectURI: client.redirectURIs[0])
                }
            )
            let cli = GmailGatewayCLI(mode: mode, authPolicy: persistentPolicy(for: mode), secureCredentialStore: store)

            let setup = try await coordinator.setup(
                credentialId: "gmail-personal",
                options: GmailOAuthSetupOptions(clientSecretPath: clientPath.path, replace: false, confirmedCredentialId: nil)
            )
            let login = try await coordinator.login(
                credentialId: "gmail-personal",
                options: GmailOAuthLoginOptions(openBrowser: false)
            )
            let refreshToken = try XCTUnwrap(loginToken.refreshToken)
            let status = await cli.runPersistent(
                arguments: ["--config", configURL.path, "auth", "status", "--credential", "gmail-personal"],
                environment: [:]
            )
            let doctor = await cli.runPersistent(arguments: ["--config", configURL.path, "doctor"], environment: [:])

            TestGmailRequestCaptureProtocol.responseStatusCode = 400
            TestGmailRequestCaptureProtocol.responseData = Data("""
            {"error":{"code":400,"message":"\(loginToken.accessToken)","status":"\(refreshToken)","errors":[{"reason":"\(client.redirectURIs[0])"}]}}
            """.utf8)
            let provider = await cli.runPersistent(
                arguments: [
                    "--config", configURL.path, "graphql", "--query",
                    #"{ profile(accountId: "personal") { emailAddress } }"#
                ],
                environment: [:]
            )
            let revoke = await cli.runPersistent(
                arguments: [
                    "--config", configURL.path, "auth", "revoke", "--credential", "gmail-personal",
                    "--confirm-credential", "gmail-personal"
                ],
                environment: [:]
            )

            let clientJSON = try client.legacyJSON()
            let environmentToken = try tokenJSON(redactionToken(
                accessMode: accessMode,
                mode: mode,
                clientFingerprint: try gmailOAuthClientFingerprint(client)
            ))
            let environment = [
                GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
                    credentialId: "gmail-personal",
                    valueKey: "oauth_client_secret_json"
                ): clientJSON,
                GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
                    credentialId: "gmail-personal",
                    valueKey: "token_store_json"
                ): environmentToken
            ]
            let environmentStatus = await cli.runPersistent(
                arguments: ["--config", configURL.path, "auth", "status", "--credential", "gmail-personal"],
                environment: environment
            )
            let environmentDoctor = await cli.runPersistent(
                arguments: ["--config", configURL.path, "doctor"],
                environment: environment
            )

            XCTAssertEqual(status.exitCode, GmailGatewayExitCode.success.rawValue, "\(mode)")
            XCTAssertEqual(doctor.exitCode, GmailGatewayExitCode.success.rawValue, "\(mode)")
            XCTAssertNotEqual(provider.exitCode, GmailGatewayExitCode.success.rawValue, "\(mode)")
            XCTAssertEqual(revoke.exitCode, GmailGatewayExitCode.success.rawValue, "\(mode)")
            XCTAssertEqual(environmentStatus.exitCode, GmailGatewayExitCode.success.rawValue, "\(mode)")
            XCTAssertEqual(environmentDoctor.exitCode, GmailGatewayExitCode.success.rawValue, "\(mode)")

            assertRedacted(
                values: protectedValues(
                    client: client,
                    token: loginToken,
                    clientJSON: clientJSON,
                    tokenJSON: environmentToken
                ),
                outputs: [
                    jsonString(setup, pretty: true),
                    jsonString(login, pretty: true),
                    status.stdout, status.stderr,
                    doctor.stdout, doctor.stderr,
                    provider.stdout, provider.stderr,
                    revoke.stdout, revoke.stderr,
                    environmentStatus.stdout, environmentStatus.stderr,
                    environmentDoctor.stdout, environmentDoctor.stderr
                ],
                mode: mode
            )
        }
    }

    func testInvalidEnvironmentAndFileTokenMetadataNeverLeaks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = try makeExplicitTokenConfig(at: root, accessMode: .read)
        let client = redactionClient(for: .reader)
        try client.legacyJSON().write(
            to: root.appendingPathComponent("client.json"), atomically: true, encoding: .utf8
        )
        let protected = [
            "access-token-metadata-sentinel",
            "refresh-token-metadata-sentinel",
            client.clientSecret ?? ""
        ]
        let invalidToken = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: protected[0],
            refreshToken: protected[1],
            tokenType: "Bearer",
            scope: protected[0],
            expiresAt: protected[1],
            emailAddress: protected[2],
            clientFingerprint: "mismatched-fingerprint"
        )
        let tokenData = try JSONEncoder().encode(invalidToken)
        try tokenData.write(to: root.appendingPathComponent("token.json"))
        let cli = GmailGatewayCLI(
            mode: .reader,
            authPolicy: .persistent(requiredAccessMode: .read),
            secureCredentialStore: TestSecureCredentialStore()
        )
        let fileStatus = await cli.runPersistent(
            arguments: ["--config", configURL.path, "auth", "status", "--credential", "gmail-personal"], environment: [:]
        )
        let fileDoctor = await cli.runPersistent(arguments: ["--config", configURL.path, "doctor"], environment: [:])

        let environment = [
            GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
                credentialId: "gmail-personal", valueKey: "oauth_client_secret_json"
            ): try client.legacyJSON(),
            GmailGatewayConfigLoader.getCredentialJSONEnvVarName(
                credentialId: "gmail-personal", valueKey: "token_store_json"
            ): try XCTUnwrap(String(data: tokenData, encoding: .utf8))
        ]
        let environmentStatus = await cli.runPersistent(
            arguments: ["--config", configURL.path, "auth", "status", "--credential", "gmail-personal"],
            environment: environment
        )
        let environmentDoctor = await cli.runPersistent(
            arguments: ["--config", configURL.path, "doctor"], environment: environment
        )

        XCTAssertEqual(fileStatus.exitCode, GmailGatewayExitCode.success.rawValue)
        XCTAssertEqual(environmentStatus.exitCode, GmailGatewayExitCode.success.rawValue)
        assertRedacted(
            values: protected,
            outputs: [
                fileStatus.stdout, fileStatus.stderr, fileDoctor.stdout, fileDoctor.stderr,
                environmentStatus.stdout, environmentStatus.stderr, environmentDoctor.stdout, environmentDoctor.stderr
            ],
            mode: .reader
        )
    }

    private func assertRedacted(
        values: [String],
        outputs: [String],
        mode: GmailGatewayCLIMode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for value in values where !value.isEmpty {
            for output in outputs {
                XCTAssertFalse(output.contains(value), "\(mode) leaked protected value: \(value)", file: file, line: line)
            }
        }
    }
}

private func makeVaultOnlyConfig(at root: URL, accessMode: AccessMode) throws -> URL {
    let configURL = root.appendingPathComponent("config.toml")
    let source = """
    [storage]
    cache_dir = "cache"
    attachment_dir = "attachments"
    allowed_send_attachment_roots = ["send"]

    [[credentials]]
    id = "gmail-personal"
    provider = "gmail"
    access_mode = "\(accessMode.rawValue)"

    [[accounts]]
    id = "personal"
    provider = "gmail"
    email_address = "person@example.com"
    credential_id = "gmail-personal"
    default_label_ids = ["INBOX"]
    """
    try source.write(to: configURL, atomically: true, encoding: .utf8)
    return configURL
}

private func makeExplicitTokenConfig(at root: URL, accessMode: AccessMode) throws -> URL {
    let configURL = root.appendingPathComponent("config.toml")
    let source = """
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
    try source.write(to: configURL, atomically: true, encoding: .utf8)
    return configURL
}

private func redactionClient(for mode: GmailGatewayCLIMode) -> GmailOAuthClientRecord {
    GmailOAuthClientRecord(
        kind: "installed",
        clientId: "client-id.apps.googleusercontent.com",
        clientSecret: "client-secret-sentinel-\(mode.executableName)",
        projectId: "project",
        authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
        tokenEndpoint: "https://oauth2.googleapis.com/token",
        redirectURIs: ["http://127.0.0.1:8080/redirect-artifact-sentinel-\(mode.executableName)"]
    )
}

private func redactionToken(
    accessMode: AccessMode,
    mode: GmailGatewayCLIMode,
    clientFingerprint: String? = nil
) -> GmailOAuthTokenStore {
    GmailOAuthTokenStore(
        accessMode: accessMode,
        accessToken: "access-token-sentinel-\(mode.executableName)",
        refreshToken: "refresh-token-sentinel-\(mode.executableName)",
        tokenType: "Bearer",
        scope: gmailScopes(accessMode: accessMode).joined(separator: " "),
        expiresAt: nil,
        emailAddress: "person@example.com",
        clientFingerprint: clientFingerprint,
        schemaVersion: 1,
        provider: .gmail,
        credentialId: "gmail-personal"
    )
}

private func tokenJSON(_ token: GmailOAuthTokenStore) throws -> String {
    try XCTUnwrap(String(data: JSONEncoder().encode(token), encoding: .utf8))
}

private func protectedValues(
    client: GmailOAuthClientRecord,
    token: GmailOAuthTokenStore,
    clientJSON: String,
    tokenJSON: String
) -> [String] {
    [
        client.clientSecret ?? "",
        client.redirectURIs[0],
        token.accessToken,
        token.refreshToken ?? "",
        clientJSON,
        tokenJSON
    ]
}
