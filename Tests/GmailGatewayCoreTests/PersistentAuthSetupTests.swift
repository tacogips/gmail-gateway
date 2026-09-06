import Foundation
@testable import GmailGatewayCore
import XCTest

final class PersistentAuthSetupTests: XCTestCase {
    func testSetupStatusAndConfirmedRevokeUseInjectedStore() async throws {
        let clientFile = try makeClientFile(authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth")
        defer { try? FileManager.default.removeItem(at: clientFile) }
        let config = try GmailGatewayConfigLoader.loadConfig(environment: [:])
        let coordinator = GmailAuthCoordinator(
            config: config,
            policy: .persistent(requiredAccessMode: .read),
            store: TestSecureCredentialStore()
        )

        let setup = try await coordinator.setup(
            credentialId: "gmail-personal",
            options: GmailOAuthSetupOptions(clientSecretPath: clientFile.path, replace: false, confirmedCredentialId: nil)
        )
        XCTAssertEqual(setup["clientStored"] as? Bool, true)
        let status = try await coordinator.status(credentialId: "gmail-personal")
        XCTAssertEqual(status["persistentClientExists"] as? Bool, true)
        XCTAssertEqual(status["persistentTokenExists"] as? Bool, false)
        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.revoke(credentialId: "gmail-personal", confirmedCredentialId: nil)
        }
        let revoke = try await coordinator.revoke(credentialId: "gmail-personal", confirmedCredentialId: "gmail-personal")
        XCTAssertEqual(revoke["revoked"] as? Bool, false)
    }

    func testConfirmedSetupReplaceRepairsInvalidVaultEnvelope() async throws {
        let clientFile = try makeClientFile(authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth")
        defer { try? FileManager.default.removeItem(at: clientFile) }
        let store = TestSecureCredentialStore()
        await store.put(Data("invalid-envelope".utf8), account: "gmail-profile:gmail-personal:read")
        let coordinator = GmailAuthCoordinator(
            config: try GmailGatewayConfigLoader.loadConfig(environment: [:]),
            policy: .persistent(requiredAccessMode: .read),
            store: store
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.setup(
                credentialId: "gmail-personal",
                options: GmailOAuthSetupOptions(clientSecretPath: clientFile.path, replace: false, confirmedCredentialId: nil)
            )
        }
        let result = try await coordinator.setup(
            credentialId: "gmail-personal",
            options: GmailOAuthSetupOptions(clientSecretPath: clientFile.path, replace: true, confirmedCredentialId: "gmail-personal")
        )
        XCTAssertEqual(result["clientStored"] as? Bool, true)
        let profile = try await GmailCredentialVault(store: store).profile(credentialId: "gmail-personal", accessMode: .read)
        XCTAssertNotNil(profile)
    }

    func testPersistentCLIParsesSetupAndKeepsSecretsOutOfOutput() async throws {
        let clientFile = try makeClientFile(authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth")
        defer { try? FileManager.default.removeItem(at: clientFile) }
        let cli = GmailGatewayCLI(
            mode: .reader,
            authPolicy: .persistent(requiredAccessMode: .read),
            secureCredentialStore: TestSecureCredentialStore()
        )
        let result = await cli.runPersistent(
            arguments: [
                "auth", "setup", "--credential", "gmail-personal",
                "--client-secret-path", clientFile.path
            ],
            environment: [:]
        )
        XCTAssertEqual(result.exitCode, GmailGatewayExitCode.success.rawValue)
        XCTAssertFalse(result.stdout.contains("not-a-real-secret"))
        XCTAssertFalse(result.stdout.contains(clientFile.path))
    }

    func testLegacyAuthorizationEndpointNormalizesAndFingerprintsIdentically() throws {
        let legacy = try makeClientFile(authorizationEndpoint: "https://accounts.google.com/o/oauth2/auth")
        let current = try makeClientFile(authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth")
        defer { try? FileManager.default.removeItem(at: legacy); try? FileManager.default.removeItem(at: current) }

        let legacyClient = try loadGmailOAuthClientRecord(from: legacy.path)
        let currentClient = try loadGmailOAuthClientRecord(from: current.path)
        XCTAssertEqual(legacyClient.authorizationEndpoint, "https://accounts.google.com/o/oauth2/v2/auth")
        XCTAssertEqual(try gmailOAuthClientFingerprint(legacyClient), try gmailOAuthClientFingerprint(currentClient))
    }

    func testAcceptsPortlessLocalhostDesktopClientFixture() throws {
        let fixture = Data(
            #"{"installed":{"client_id":"client.apps.googleusercontent.com","project_id":"sample-project","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token","client_secret":"secret","redirect_uris":["http://localhost"]}}"#.utf8
        )

        let client = try loadGmailOAuthClientRecord(from: fixture)

        XCTAssertEqual(client.kind, "installed")
        XCTAssertEqual(client.redirectURIs, ["http://localhost"])
    }

    func testSetupRedirectsProduceMatchingReceiverAndAuthorizationURIs() async throws {
        let cases = [
            (redirectURI: "http://127.0.0.1/persistent-ipv4-callback", host: "127.0.0.1", path: "/persistent-ipv4-callback"),
            (redirectURI: "http://localhost/persistent-callback", host: "localhost", path: "/persistent-callback"),
            (redirectURI: "http://[::1]/persistent-ipv6-callback", host: "::1", path: "/persistent-ipv6-callback")
        ]
        for testCase in cases {
            let clientFile = try makeClientFile(
                authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
                redirectURI: testCase.redirectURI
            )
            defer { try? FileManager.default.removeItem(at: clientFile) }
            let store = TestSecureCredentialStore()
            let config = persistentConfig(
                tokenPath: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path,
                fallback: true
            )
            let coordinator = GmailAuthCoordinator(
                config: config,
                environment: [:],
                policy: .persistent(requiredAccessMode: .read),
                store: store
            )
            _ = try await coordinator.setup(
                credentialId: "gmail-personal",
                options: GmailOAuthSetupOptions(clientSecretPath: clientFile.path, replace: false, confirmedCredentialId: nil)
            )
            let storedProfile = try await GmailCredentialVault(store: store).profile(
                credentialId: "gmail-personal",
                accessMode: .read
            )
            let profile = try XCTUnwrap(storedProfile)
            let redirect = try selectedGmailOAuthLoopbackRedirect(client: profile.client, requestedURI: nil)
            let receiver = try LoopbackOAuthReceiver(redirect: redirect)
            let authorizationURL = try buildAuthorizationURL(
                client: GoogleOAuthClient(
                    clientId: profile.client.clientId,
                    clientSecret: profile.client.clientSecret,
                    authURI: profile.client.authorizationEndpoint,
                    tokenURI: profile.client.tokenEndpoint
                ),
                credential: config.credentials[0],
                redirectURI: receiver.redirectURI,
                state: "state-value",
                codeVerifier: "verifier-value"
            )
            let query = try XCTUnwrap(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
            let authorizationRedirect = try XCTUnwrap(query.first(where: { $0.name == "redirect_uri" })?.value)
            let receiverComponents = try XCTUnwrap(URLComponents(string: receiver.redirectURI))

            XCTAssertEqual(authorizationRedirect, receiver.redirectURI)
            XCTAssertEqual(receiverComponents.host, testCase.host == "::1" ? "[::1]" : testCase.host)
            XCTAssertEqual(receiverComponents.path, testCase.path)
        }
    }

    func testRejectsNonGoogleTokenEndpoint() throws {
        let file = try makeClientFile(authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth", tokenEndpoint: "https://example.test/token")
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try loadGmailOAuthClientRecord(from: file.path))
    }

    func testRejectsUnapprovedEndpointAndRedirectVariants() throws {
        let invalidAuthorizationEndpoints = [
            "http://accounts.google.com/o/oauth2/v2/auth",
            "https://accounts.google.com:443/o/oauth2/v2/auth",
            "https://user@accounts.google.com/o/oauth2/v2/auth",
            "https://accounts.google.com/o/oauth2/v2/auth?x=1",
            "https://accounts.google.com/o/oauth2/v2/auth#fragment"
        ]
        for endpoint in invalidAuthorizationEndpoints {
            let file = try makeClientFile(authorizationEndpoint: endpoint)
            defer { try? FileManager.default.removeItem(at: file) }
            XCTAssertThrowsError(try loadGmailOAuthClientRecord(from: file.path), endpoint)
        }
        for redirect in [
            "https://127.0.0.1:8080/oauth2callback",
            "http://example.invalid:8080/oauth2callback",
            "http://127.0.0.1:8080/oauth2callback?state=bad",
            "http://127.0.0.1:8080/oauth2callback#fragment"
        ] {
            let file = try makeClientFile(
                authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
                redirectURI: redirect
            )
            defer { try? FileManager.default.removeItem(at: file) }
            XCTAssertThrowsError(try loadGmailOAuthClientRecord(from: file.path), redirect)
        }
    }

    func testRejectsWebOAuthClient() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: file) }
        let payload: [String: Any] = ["web": ["client_id": "client-id", "auth_uri": "https://accounts.google.com/o/oauth2/v2/auth", "token_uri": "https://oauth2.googleapis.com/token", "redirect_uris": ["http://127.0.0.1:8080/oauth2callback"]]]
        try JSONSerialization.data(withJSONObject: payload).write(to: file)
        XCTAssertThrowsError(try loadGmailOAuthClientRecord(from: file.path))
    }

    func testLoginAuthorizationUsesExactScopesAndPKCE() throws {
        let credential = CredentialConfig(
            id: "gmail-personal", provider: .gmail, accessMode: .readSend,
            oauthClientSecretPath: "/unused", oauthClientSecretJSON: nil,
            tokenStorePath: "/unused", tokenStoreJSON: nil
        )
        let client = GoogleOAuthClient(
            clientId: "client-id.apps.googleusercontent.com",
            clientSecret: nil,
            authURI: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenURI: "https://oauth2.googleapis.com/token"
        )
        let url = try buildAuthorizationURL(
            client: client,
            credential: credential,
            redirectURI: "http://127.0.0.1:8080/oauth2callback",
            state: "state-value",
            codeVerifier: "verifier-value"
        )
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values: [String: String?] = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value) })
        XCTAssertEqual(values["scope"], gmailScopes(accessMode: .readSend).joined(separator: " "))
        XCTAssertEqual(values["include_granted_scopes"], "false")
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertEqual(values["state"], "state-value")
        XCTAssertNotNil(values["code_challenge"] ?? nil)
    }
}

private func makeClientFile(
    authorizationEndpoint: String,
    tokenEndpoint: String = "https://oauth2.googleapis.com/token",
    redirectURI: String = "http://127.0.0.1:8080/oauth2callback"
) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    let object: [String: Any] = ["installed": [
        "client_id": "client-id.apps.googleusercontent.com",
        "client_secret": "not-a-real-secret",
        "project_id": "project",
        "auth_uri": authorizationEndpoint,
        "token_uri": tokenEndpoint,
        "redirect_uris": [redirectURI]
    ]]
    try JSONSerialization.data(withJSONObject: object).write(to: root)
    return root
}
