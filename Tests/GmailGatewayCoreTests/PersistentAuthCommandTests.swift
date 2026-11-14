@testable import GmailGatewayCore
import XCTest

final class PersistentAuthCommandTests: XCTestCase {
    func testReplacementConfirmationFailsBeforeClientFileReadOrStoreWrite() async throws {
        let store = TestSecureCredentialStore()
        let client = testClient()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: nil))
        let cli = GmailGatewayCLI(
            mode: .reader,
            authPolicy: .persistent(requiredAccessMode: .read),
            secureCredentialStore: store
        )

        let result = await cli.runPersistent(arguments: [
            "auth", "setup", "--credential", "gmail-personal",
            "--client-secret-path", "/path-that-must-not-be-read.json",
            "--replace", "--confirm-credential", "wrong"
        ], environment: [:])

        XCTAssertEqual(result.exitCode, GmailGatewayExitCode.invalidCliUsage.rawValue)
        XCTAssertFalse(result.stderr.contains("path-that-must-not-be-read"))
        let retained = try await vault.profile(credentialId: "gmail-personal", accessMode: .read)
        XCTAssertEqual(retained?.client, client)
    }

    func testPersistentStatusRedactsClientAndVaultDetails() async throws {
        let client = testClient()
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: try coherentToken(client: client)))
        let cli = GmailGatewayCLI(
            mode: .reader,
            authPolicy: .persistent(requiredAccessMode: .read),
            secureCredentialStore: store
        )

        let result = await cli.runPersistent(arguments: ["auth", "status", "--credential", "gmail-personal"], environment: [:])

        XCTAssertEqual(result.exitCode, GmailGatewayExitCode.success.rawValue)
        XCTAssertFalse(result.stdout.contains(client.clientSecret ?? "client-secret"))
        XCTAssertFalse(result.stdout.contains("gmail-profile:"))
    }

    func testVaultBackedProviderOperationsWorkForAllPersistentExecutablesWithoutCredentialEnvironment() async throws {
        let fixtures: [(GmailGatewayCLIMode, AccessMode)] = [
            (.reader, .read),
            (.directSender, .readSend),
            (.draftGateway, .readSend)
        ]
        TestGmailRequestCaptureProtocol.reset()
        TestGmailRequestCaptureProtocol.profileResponseData = Data(#"{"emailAddress":"person@example.com","messagesTotal":1,"threadsTotal":1,"historyId":"history-1"}"#.utf8)
        URLProtocol.registerClass(TestGmailRequestCaptureProtocol.self)
        defer {
            URLProtocol.unregisterClass(TestGmailRequestCaptureProtocol.self)
            TestGmailRequestCaptureProtocol.reset()
        }
        for (mode, accessMode) in fixtures {
            let configURL = try makeVaultOnlyConfig(accessMode: accessMode)
            defer { try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent()) }
            let client = testClient()
            let token = GmailOAuthTokenStore(
                accessMode: accessMode,
                accessToken: "access-token",
                refreshToken: "refresh-token",
                tokenType: "Bearer",
                scope: gmailScopes(accessMode: accessMode).joined(separator: " "),
                expiresAt: nil,
                emailAddress: "person@example.com",
                clientFingerprint: try gmailOAuthClientFingerprint(client),
                schemaVersion: 1,
                provider: .gmail,
                credentialId: "gmail-personal"
            )
            let store = TestSecureCredentialStore()
            let vault = GmailCredentialVault(store: store)
            try await vault.replaceProfile(GmailCredentialProfileEnvelope(
                schemaVersion: 1,
                provider: .gmail,
                credentialId: "gmail-personal",
                accessMode: accessMode,
                expectedScopes: gmailScopes(accessMode: accessMode).sorted(),
                client: client,
                token: token
            ))
            let cli = GmailGatewayCLI(mode: mode, authPolicy: persistentPolicy(for: mode), secureCredentialStore: store)

            let result = await cli.runPersistent(
                arguments: [
                    "--config", configURL.path, "graphql", "--query",
                    #"{ profile(accountId: "personal") { emailAddress } }"#
                ],
                environment: [:]
            )

            XCTAssertEqual(result.exitCode, GmailGatewayExitCode.success.rawValue, "\(mode)")
            XCTAssertTrue(result.stdout.contains("person@example.com"), "\(mode)")
        }
        XCTAssertEqual(TestGmailRequestCaptureProtocol.capturedURLs.map(\.path), [
            "/gmail/v1/users/me/profile",
            "/gmail/v1/users/me/profile",
            "/gmail/v1/users/me/profile"
        ])
    }

    func testMalformedGraphQLDoesNotHydrateOrRefreshPersistentCredentials() async throws {
        let client = testClient()
        let expiredToken = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "expired-access-token",
            refreshToken: "refresh-token",
            tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "),
            expiresAt: "2020-01-01T00:00:00Z",
            emailAddress: nil,
            clientFingerprint: try gmailOAuthClientFingerprint(client)
        )
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: expiredToken))
        let readsBefore = await store.dataReadCount()
        let writesBefore = await store.dataWriteCount()
        let cli = GmailGatewayCLI(mode: .reader, authPolicy: .persistent(requiredAccessMode: .read), secureCredentialStore: store)

        let result = await cli.runPersistent(arguments: ["graphql", "--query", "{ threads(accountId: ) { id } }"], environment: [:])
        let readsAfter = await store.dataReadCount()
        let writesAfter = await store.dataWriteCount()

        XCTAssertNotEqual(result.exitCode, GmailGatewayExitCode.success.rawValue)
        XCTAssertEqual(readsAfter, readsBefore)
        XCTAssertEqual(writesAfter, writesBefore)
    }

    func testInvalidProviderOperationArgumentsDoNotHydratePersistentCredentials() async throws {
        let client = testClient()
        let expiredToken = GmailOAuthTokenStore(
            accessMode: .read,
            accessToken: "expired-access-token",
            refreshToken: "refresh-token",
            tokenType: "Bearer",
            scope: gmailScopes(accessMode: .read).joined(separator: " "),
            expiresAt: "2020-01-01T00:00:00Z",
            emailAddress: nil,
            clientFingerprint: try gmailOAuthClientFingerprint(client)
        )
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        try await vault.replaceProfile(testProfile(client: client, token: expiredToken))
        let readsBefore = await store.dataReadCount()
        let writesBefore = await store.dataWriteCount()
        let cli = GmailGatewayCLI(mode: .reader, authPolicy: .persistent(requiredAccessMode: .read), secureCredentialStore: store)

        let result = await cli.runPersistent(arguments: [
            "graphql", "--query", #"{ threads(input: { accountId: "personal", first: 0 }) { totalCount } }"#
        ], environment: [:])
        let readsAfter = await store.dataReadCount()
        let writesAfter = await store.dataWriteCount()

        XCTAssertEqual(result.exitCode, GmailGatewayExitCode.graphqlExecutionError.rawValue)
        XCTAssertTrue(result.stdout.contains(GmailGatewayErrorCode.invalidArgument.rawValue))
        XCTAssertEqual(readsAfter, readsBefore)
        XCTAssertEqual(writesAfter, writesBefore)
    }

    func testUnsupportedPersistentMutationRetainsGraphQLErrorShapeWithoutHydration() async throws {
        let client = testClient()
        let configURL = try makeVaultOnlyConfig(accessMode: .readSend)
        defer { try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent()) }
        let store = TestSecureCredentialStore()
        let vault = GmailCredentialVault(store: store)
        let token = GmailOAuthTokenStore(
            accessMode: .readSend,
            accessToken: "access-token",
            refreshToken: "refresh-token",
            tokenType: "Bearer",
            scope: gmailScopes(accessMode: .readSend).joined(separator: " "),
            expiresAt: nil,
            emailAddress: "person@example.com",
            clientFingerprint: try gmailOAuthClientFingerprint(client)
        )
        try await vault.replaceProfile(GmailCredentialProfileEnvelope(
            schemaVersion: 1,
            provider: .gmail,
            credentialId: "gmail-personal",
            accessMode: .readSend,
            expectedScopes: gmailScopes(accessMode: .readSend).sorted(),
            client: client,
            token: token
        ))
        let readsBefore = await store.dataReadCount()
        let cli = GmailGatewayCLI(mode: .draftGateway, authPolicy: .persistent(requiredAccessMode: .readSend), secureCredentialStore: store)

        let result = await cli.runPersistent(arguments: [
            "--config", configURL.path, "graphql", "--query", #"mutation { modifyThreadLabels(input: { accountId: "personal", threadId: "thread", addLabelIds: [] }) { status } }"#
        ], environment: [:])
        let readsAfter = await store.dataReadCount()

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stdout.contains("CAPABILITY_DENIED"), result.stdout)
        XCTAssertEqual(readsAfter, readsBefore)
    }
}

func makeVaultOnlyConfig(accessMode: AccessMode) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let config = root.appendingPathComponent("config.toml")
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
    try source.write(to: config, atomically: true, encoding: .utf8)
    return config
}
