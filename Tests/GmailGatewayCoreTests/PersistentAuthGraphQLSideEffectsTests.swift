@testable import GmailGatewayCore
import XCTest

final class PersistentAuthGraphQLSideEffectsTests: XCTestCase {
    func testReaderRejectsInvalidThreadArgumentsBeforeVaultReadOrRefresh() async throws {
        let client = testClient()
        let token = GmailOAuthTokenStore(
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
        try await GmailCredentialVault(store: store).replaceProfile(testProfile(client: client, token: token))
        let readsBefore = await store.dataReadCount()
        let writesBefore = await store.dataWriteCount()
        let cli = GmailGatewayCLI(mode: .reader, authPolicy: .persistent(requiredAccessMode: .read), secureCredentialStore: store)

        let result = await cli.runPersistent(arguments: [
            "graphql", "--query", #"{ threads(input: { accountId: "personal", first: 501 }) { totalCount } }"#
        ], environment: [:])
        let readsAfter = await store.dataReadCount()
        let writesAfter = await store.dataWriteCount()

        XCTAssertEqual(result.exitCode, GmailGatewayExitCode.graphqlExecutionError.rawValue)
        XCTAssertTrue(result.stdout.contains(GmailGatewayErrorCode.invalidArgument.rawValue), result.stdout)
        XCTAssertEqual(readsAfter, readsBefore)
        XCTAssertEqual(writesAfter, writesBefore)
    }

    func testDraftAndSenderRejectBodylessRepliesBeforeVaultReadOrRefresh() async throws {
        try await assertInvalidReplyDoesNotReadVault(mode: .draftGateway, root: "createReplyDraft", arguments: "accountId: \"personal\", messageId: \"message-1\"")
        try await assertInvalidReplyDoesNotReadVault(mode: .directSender, root: "replyMessage", arguments: "accountId: \"personal\", messageId: \"message-1\"")
    }

    func testReplyPreflightRejectsInjectedExplicitRecipient() {
        let input = ReplyMessageInput(
            accountId: "personal",
            messageId: "message-1",
            to: ["victim@example.com\nBcc: attacker@example.com"],
            cc: [],
            bcc: [],
            replyAll: false,
            textBody: "body",
            htmlBody: nil,
            attachmentPaths: []
        )
        let account = AccountConfig(
            id: "personal",
            provider: .gmail,
            emailAddress: "person@example.com",
            credentialId: "gmail-personal",
            defaultLabelIds: []
        )

        do {
            try validateReplyInputBeforeProvider(input, account: account, operation: .send)
            XCTFail("reply preflight must reject header injection")
        } catch let error as GmailGatewayError {
            XCTAssertEqual(error.code.rawValue, GmailGatewayErrorCode.invalidArgument.rawValue)
            XCTAssertEqual(error.exitCode, .graphqlExecutionError)
        } catch {
            XCTFail("Expected GmailGatewayError, received \(error)")
        }
    }

    private func assertInvalidReplyDoesNotReadVault(
        mode: GmailGatewayCLIMode,
        root: String,
        arguments: String
    ) async throws {
        let config = try makePersistentReadSendConfig()
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
        let client = testClient()
        let token = GmailOAuthTokenStore(
            accessMode: .readSend,
            accessToken: "expired-access-token",
            refreshToken: "refresh-token",
            tokenType: "Bearer",
            scope: gmailScopes(accessMode: .readSend).joined(separator: " "),
            expiresAt: "2020-01-01T00:00:00Z",
            emailAddress: "person@example.com",
            clientFingerprint: try gmailOAuthClientFingerprint(client)
        )
        let store = TestSecureCredentialStore()
        try await GmailCredentialVault(store: store).replaceProfile(GmailCredentialProfileEnvelope(
            schemaVersion: 1,
            provider: .gmail,
            credentialId: "gmail-personal",
            accessMode: .readSend,
            expectedScopes: gmailScopes(accessMode: .readSend).sorted(),
            client: client,
            token: token
        ))
        let readsBefore = await store.dataReadCount()
        let writesBefore = await store.dataWriteCount()
        let cli = GmailGatewayCLI(mode: mode, authPolicy: .persistent(requiredAccessMode: .readSend), secureCredentialStore: store)

        let result = await cli.runPersistent(arguments: [
            "--config", config.path, "graphql", "--query",
            "mutation { \(root)(input: { \(arguments) }) { status } }"
        ], environment: [:])
        let readsAfter = await store.dataReadCount()
        let writesAfter = await store.dataWriteCount()

        XCTAssertEqual(result.exitCode, GmailGatewayExitCode.graphqlExecutionError.rawValue)
        XCTAssertTrue(result.stdout.contains(GmailGatewayErrorCode.invalidArgument.rawValue), result.stdout)
        XCTAssertEqual(readsAfter, readsBefore)
        XCTAssertEqual(writesAfter, writesBefore)
    }
}

private func makePersistentReadSendConfig() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let config = root.appendingPathComponent("config.toml")
    try """
    [storage]
    cache_dir = "cache"
    attachment_dir = "attachments"
    allowed_send_attachment_roots = ["send"]

    [[credentials]]
    id = "gmail-personal"
    provider = "gmail"
    access_mode = "read_send"

    [[accounts]]
    id = "personal"
    provider = "gmail"
    email_address = "person@example.com"
    credential_id = "gmail-personal"
    default_label_ids = ["INBOX"]
    """.write(to: config, atomically: true, encoding: .utf8)
    return config
}
