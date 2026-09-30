import Foundation
@testable import GmailGatewayCore
import XCTest

final class CanonicalCredentialTests: XCTestCase {
    func testProfileSourceReplacesProductSourceAcrossInputTypes() throws {
      let selected = try gmailCredentialEnvironment([
        "GMAIL_GATEWAY_TOKEN_STORE_PATH": "/unused/default-token.json",
        "GMAIL_GATEWAY_CREDENTIAL_WORK_ACCESS_TOKEN": "work-token",
        "GMAIL_GATEWAY_OAUTH_CLIENT_PATH": "/unused/default-client.json",
        "GMAIL_GATEWAY_CREDENTIAL_WORK_OAUTH_CLIENT_JSON": "inline-application"
      ], credentialIDs: ["work"])
      XCTAssertEqual(selected["GMAIL_GATEWAY_CREDENTIAL_WORK_ACCESS_TOKEN"], "work-token")
      XCTAssertNil(selected["GMAIL_GATEWAY_CREDENTIAL_WORK_TOKEN_STORE_PATH"])
      XCTAssertEqual(selected["GMAIL_GATEWAY_CREDENTIAL_WORK_OAUTH_CLIENT_SECRET_JSON"], "inline-application")
      XCTAssertNil(selected["GMAIL_GATEWAY_CREDENTIAL_WORK_OAUTH_CLIENT_SECRET_PATH"])
    }

    func testDirectTokenWorksInAllMailboxModesWithoutClientOrTokenFile() async throws {
        for accessMode in [AccessMode.read, .readSend, .readModify, .full] {
            let url = try makeVaultOnlyConfig(accessMode: accessMode)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let environment = ["GMAIL_GATEWAY_ACCESS_TOKEN": "external-token"]
            let config = try GmailGatewayConfigLoader.loadConfig(configPath: url.path, environment: environment)
            let credential = try XCTUnwrap(config.credentials.first)
            XCTAssertEqual(try validGmailAccessToken(credential: credential, use: .read), "external-token")
            XCTAssertFalse(FileManager.default.fileExists(atPath: credential.tokenStorePath))
            let modes: [GmailGatewayCLIMode]
            switch accessMode {
            case .read: modes = [.reader]
            case .readSend: modes = [.draftGateway, .directSender]
            case .readModify: modes = [.mailboxThreads]
            case .full: modes = [.messageBox]
            }
            for mode in modes {
                let cli = GmailGatewayCLI(mode: mode, authPolicy: persistentPolicy(for: mode), secureCredentialStore: TestSecureCredentialStore())
                let status = await cli.runPersistent(arguments: ["--config", url.path, "auth", "status", "--credential", credential.id], environment: environment)
                XCTAssertEqual(status.exitCode, 0, status.stdout + status.stderr)
                XCTAssertTrue(status.stdout.contains("ENVIRONMENT_TOKEN"), status.stdout)
                XCTAssertFalse(status.stdout.contains("external-token"))
            }
            if accessMode == .read || accessMode == .readSend {
                let coordinator = GmailAuthCoordinator(config: config, environment: environment,
                    policy: .persistent(requiredAccessMode: accessMode), store: TestSecureCredentialStore())
                let hydrated = try await coordinator.hydratedConfig()
                XCTAssertEqual(hydrated.credentials.first?.directAccessToken, "external-token")
                let status = try await coordinator.status(credentialId: credential.id)
                XCTAssertEqual(status["tokenSource"] as? String, "ENVIRONMENT_TOKEN")
            }
        }
    }

    func testDirectTokenProfileOverridesDefaultAndRejectsAmbiguousSources() throws {
        let environment = try gmailCredentialEnvironment([
            "GMAIL_GATEWAY_ACCESS_TOKEN": "default-token",
            "GMAIL_GATEWAY_CREDENTIAL_WORK_ACCESS_TOKEN": "work-token"
        ], credentialIDs: ["work"])
        XCTAssertEqual(environment["GMAIL_GATEWAY_CREDENTIAL_WORK_ACCESS_TOKEN"], "work-token")
        XCTAssertThrowsError(try gmailCredentialEnvironment([
            "GMAIL_GATEWAY_ACCESS_TOKEN": "secret-token", "GMAIL_GATEWAY_TOKEN_STORE_PATH": "/unused/token.json"
        ])) { error in
            XCTAssertFalse(String(describing: error).contains("secret-token"))
        }
        XCTAssertThrowsError(try gmailCredentialEnvironment(["GMAIL_GATEWAY_ACCESS_TOKEN": "invalid\ntoken"]))
    }

    func testCanonicalOAuthClientAliasesPreserveLegacySources() throws {
        let canonical = "GMAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_OAUTH_CLIENT_JSON"
        let legacy = "GMAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_OAUTH_CLIENT_SECRET_JSON"
        let json = #"{"installed":{"client_id":"client-id"}}"#
        let canonicalEnvironment = try gmailCredentialEnvironment([canonical: json])
        XCTAssertEqual(canonicalEnvironment[legacy], json)
        XCTAssertEqual(try gmailCredentialEnvironment([canonical: json, legacy: json])[legacy], json)
        XCTAssertThrowsError(try gmailCredentialEnvironment([canonical: "canonical-secret", legacy: "legacy-secret"])) { error in
            XCTAssertFalse(String(describing: error).contains("canonical-secret"))
            XCTAssertFalse(String(describing: error).contains("legacy-secret"))
        }
    }

    func testOrdinaryPersistentQueryUsesDirectTokenWithoutLogin() async throws {
        TestGmailRequestCaptureProtocol.reset()
        TestGmailRequestCaptureProtocol.responseData = Data(#"{"threads":[],"resultSizeEstimate":0}"#.utf8)
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["GMAIL_GATEWAY_ACCESS_TOKEN": "external-token", "XDG_CONFIG_HOME": root.path, "XDG_STATE_HOME": root.path]
        let cli = GmailGatewayCLI(mode: .reader, authPolicy: .persistent(requiredAccessMode: .read), secureCredentialStore: TestSecureCredentialStore())
        let result = await cli.runPersistent(arguments: ["graphql", "--query", #"{ threads(input: { accountId: "personal" }) { totalCount } }"#], environment: environment)
        XCTAssertEqual(result.exitCode, 0, result.stdout + result.stderr)
        XCTAssertFalse(TestGmailRequestCaptureProtocol.capturedURLs.isEmpty)
        XCTAssertFalse(result.stdout.contains("external-token"))
        XCTAssertFalse(result.stderr.contains("external-token"))
        let login = await cli.runPersistent(arguments: ["auth", "login"], environment: environment)
        XCTAssertEqual(login.exitCode, 2, login.stderr)
        XCTAssertTrue(login.stderr.contains("immutable"))
    }
}
