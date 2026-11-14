import Foundation
import MailGatewayCore

func testMessageFileDownload(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    var env = credentialEnv(fixture: fixture)
    env[MailGatewayConfigLoader.getCredentialJSONEnvVarName(
        credentialId: "gmail-personal",
        valueKey: "token_store_json"
    )] = gmailReadTokenStoreJSON()

    GmailRequestCaptureProtocol.reset()
    GmailRequestCaptureProtocol.responseBody = """
    {
      "id": "message-2",
      "threadId": "thread-2",
      "payload": {
        "mimeType": "multipart/alternative",
        "parts": [
          {
            "mimeType": "text/plain",
            "body": {
              "size": 20,
              "data": "cHJpdmF0ZSBib2R5IHBheWxvYWQ"
            }
          },
          {
            "mimeType": "text/html",
            "body": {
              "size": 27,
              "data": "PHA-cHJpdmF0ZSBodG1sIHBheWxvYWQ8L3A-"
            }
          }
        ]
      }
    }
    """
    URLProtocol.registerClass(GmailRequestCaptureProtocol.self)
    defer {
        URLProtocol.unregisterClass(GmailRequestCaptureProtocol.self)
        GmailRequestCaptureProtocol.reset()
    }

    let materializedDir = URL(fileURLWithPath: fixture.attachmentRoot)
        .appendingPathComponent("personal", isDirectory: true)
        .appendingPathComponent("message-2", isDirectory: true)
    try writeTemporaryMessageFiles(in: materializedDir)
    let lookupResult = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", """
        { messageFileSet(accountId: "personal", messageId: "message-2") \
        { hasFiles files { kind filename hasPayload localPath downloadKey materializationState } } }
        """
    ], env: env)
    try assertMessageFileLookup(lookupResult)
    let bodyDownloadKey = try downloadKey(kind: "BODY_TEXT", from: lookupResult)
    try assertDownloadedFile(
        downloadKey: bodyDownloadKey,
        fixture: fixture,
        expectedKind: "BODY_TEXT",
        expectedContents: "private body payload",
        env: env
    )
    let temporaryDownloadKey = try downloadKey(kind: "TEMPORARY_FILE", from: lookupResult)
    try assertDownloadedFile(
        downloadKey: temporaryDownloadKey,
        fixture: fixture,
        expectedKind: "TEMPORARY_FILE",
        expectedContents: "temporary payload"
    )
    try assertDownloadedFiles(
        downloadKeys: [bodyDownloadKey, temporaryDownloadKey],
        fixture: fixture,
        expected: [
            "BODY_TEXT": "private body payload",
            "TEMPORARY_FILE": "temporary payload"
        ]
    )
}

func testRemoteAttachmentDownload(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    var env = credentialEnv(fixture: fixture)
    env[MailGatewayConfigLoader.getCredentialJSONEnvVarName(
        credentialId: "gmail-personal",
        valueKey: "token_store_json"
    )] = gmailReadTokenStoreJSON()

    GmailRequestCaptureProtocol.reset()
    URLProtocol.registerClass(GmailRequestCaptureProtocol.self)
    defer {
        URLProtocol.unregisterClass(GmailRequestCaptureProtocol.self)
        GmailRequestCaptureProtocol.reset()
    }

    let remoteAttachmentId = "remote-attachment-" + String(repeating: "x", count: 220)
    GmailRequestCaptureProtocol.responseBody = """
    {
      "id": "remote-message",
      "threadId": "remote-thread",
      "labelIds": ["INBOX"],
      "payload": {
        "mimeType": "multipart/mixed",
        "parts": [
          {
            "partId": "1",
            "filename": "temp video.mp4",
            "mimeType": "video/mp4",
            "body": {
              "attachmentId": "\(remoteAttachmentId)",
              "size": 20
            }
          }
        ]
      }
    }
    """
    let lookupResult = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", """
        { message(accountId: "personal", messageId: "remote-message") \
        { attachments { id filename mimeType sizeBytes downloadKey materializationState } } }
        """
    ], env: env)
    try assert(lookupResult.exitCode == 0, "remote attachment metadata lookup should succeed")
    let downloadKey = try remoteAttachmentDownloadKey(from: lookupResult)

    GmailRequestCaptureProtocol.responseBody = #"{"data":"cmVtb3RlIHZpZGVvIHBheWxvYWQ","size":20}"#
    try assertDownloadedFile(
        downloadKey: downloadKey,
        fixture: fixture,
        expectedKind: "ATTACHMENT",
        expectedContents: "remote video payload",
        env: env
    )
    try assert(
        GmailRequestCaptureProtocol.capturedURLs.contains {
            $0.path == "/gmail/v1/users/me/messages/remote-message/attachments/\(remoteAttachmentId)"
        },
        "remote attachment download should call Gmail attachment payload endpoint"
    )

    let cachedLookup = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", """
        { attachment(accountId: "personal", messageId: "remote-message", attachmentId: "\(remoteAttachmentId)") \
        { filename localPath materializationState } }
        """
    ])
    let cachedOutput = try decodeObject(cachedLookup.stdout)
    let cachedAttachment = (cachedOutput["data"] as? [String: Any])?["attachment"] as? [String: Any]
    try assert(cachedLookup.exitCode == 0, "cached long-id attachment lookup should succeed without live auth")
    try assert(
        cachedAttachment?["filename"] as? String == "temp_video.mp4",
        "cached long-id attachment lookup should return sanitized cache filename"
    )
    try assert(
        cachedAttachment?["materializationState"] as? String == "CACHED",
        "cached long-id attachment lookup should report cached state"
    )
    try assert(cachedAttachment?["localPath"] == nil, "cached long-id attachment lookup should not expose local path")
}

func writeTemporaryMessageFiles(in materializedDir: URL) throws {
    try writeText(materializedDir
        .appendingPathComponent("temp", isDirectory: true)
        .appendingPathComponent("tmp-1-report.txt")
        .path, "temporary payload")
}

func assertMessageFileLookup(_ result: MailGatewayCommandResult) throws {
    try assert(result.exitCode == 0, "message file set lookup should succeed")
    try assert(!result.stdout.contains("private body payload"), "GraphQL output should not include text body payload")
    try assert(!result.stdout.contains("private html payload"), "GraphQL output should not include HTML body payload")
    try assert(!result.stdout.contains("temporary payload"), "GraphQL output should not include temporary file payload")
    try assert(!result.stdout.contains("localPath"), "GraphQL metadata should not expose local payload paths")
    try assert(!result.stdout.contains("directory"), "GraphQL metadata should not expose local payload directories")
    try assert(
        containsEither(result.stdout, #""kind":"BODY_TEXT""#, #""kind" : "BODY_TEXT""#),
        "lookup should include text body file metadata"
    )
    try assert(
        containsEither(result.stdout, #""kind":"BODY_HTML""#, #""kind" : "BODY_HTML""#),
        "lookup should include HTML body file metadata"
    )
    try assert(
        containsEither(result.stdout, #""kind":"TEMPORARY_FILE""#, #""kind" : "TEMPORARY_FILE""#),
        "lookup should include temporary file metadata"
    )
}

func downloadKey(kind: String, from result: MailGatewayCommandResult) throws -> String {
    let lookup = try decodeObject(result.stdout)
    let data = lookup["data"] as? [String: Any]
    let fileSet = data?["messageFileSet"] as? [String: Any]
    let files = fileSet?["files"] as? [[String: Any]]
    let matchingFile = files?.first { $0["kind"] as? String == kind }
    guard let downloadKey = matchingFile?["downloadKey"] as? String else {
        throw SmokeTestFailure.assertionFailed("\(kind) file should include a download key")
    }
    return downloadKey
}

func assertDownloadedFile(
    downloadKey: String,
    fixture: Fixture,
    expectedKind: String,
    expectedContents: String,
    env: [String: String] = [:]
) throws {
    let downloadDir = URL(fileURLWithPath: fixture.cacheRoot)
        .appendingPathComponent("downloads", isDirectory: true)
        .path
    let downloadResult = runCli([
        "file", "download",
        "--config", fixture.configPath,
        "--key", downloadKey,
        "--output-dir", downloadDir
    ], env: env)
    try assert(downloadResult.exitCode == 0, "file download command should succeed")
    let download = try decodeObject(downloadResult.stdout)
    guard let downloadedPath = download["localPath"] as? String else {
        throw SmokeTestFailure.assertionFailed("file download should return localPath")
    }
    try assert(download["kind"] as? String == expectedKind, "downloaded file kind should match")
    let downloadedContents = try? String(contentsOfFile: downloadedPath, encoding: .utf8)
    try assert(downloadedContents == expectedContents, "downloaded file payload should match")
}

func remoteAttachmentDownloadKey(from result: MailGatewayCommandResult) throws -> String {
    let lookup = try decodeObject(result.stdout)
    let data = lookup["data"] as? [String: Any]
    let message = data?["message"] as? [String: Any]
    let attachments = message?["attachments"] as? [[String: Any]]
    guard let attachment = attachments?.first,
          attachment["filename"] as? String == "temp video.mp4",
          attachment["mimeType"] as? String == "video/mp4",
          attachment["materializationState"] as? String == "NOT_MATERIALIZED",
          let downloadKey = attachment["downloadKey"] as? String else {
        throw SmokeTestFailure.assertionFailed("remote attachment metadata should include a download key")
    }
    return downloadKey
}

func gmailReadTokenStoreJSON() -> String {
    """
    {
      "accessMode": "read",
      "accessToken": "test-access-token",
      "refreshToken": null,
      "tokenType": "Bearer",
      "scope": "https://www.googleapis.com/auth/gmail.readonly",
      "expiresAt": "2999-01-01T00:00:00Z",
      "emailAddress": "person@example.com"
    }
    """
}

func assertDownloadedFiles(
    downloadKeys: [String],
    fixture: Fixture,
    expected: [String: String]
) throws {
    let downloadDir = URL(fileURLWithPath: fixture.cacheRoot)
        .appendingPathComponent("batch-downloads", isDirectory: true)
        .path
    let keyedArguments = downloadKeys.flatMap { ["--key", $0] }
    let downloadResult = runCli(
        ["file", "download", "--config", fixture.configPath] +
        keyedArguments +
        ["--output-dir", downloadDir]
    )
    try assert(downloadResult.exitCode == 0, "batch file download command should succeed")
    let output = try decodeObject(downloadResult.stdout)
    try assert(output["fileCount"] as? Int == downloadKeys.count, "batch download file count should match")
    guard let files = output["files"] as? [[String: Any]] else {
        throw SmokeTestFailure.assertionFailed("batch file download should return files")
    }
    try assert(files.count == downloadKeys.count, "batch download should return each file")
    for file in files {
        guard let kind = file["kind"] as? String,
              let expectedContents = expected[kind],
              let downloadedPath = file["localPath"] as? String else {
            throw SmokeTestFailure.assertionFailed("batch file download should return expected file metadata")
        }
        let downloadedContents = try? String(contentsOfFile: downloadedPath, encoding: .utf8)
        try assert(downloadedContents == expectedContents, "batch downloaded file payload should match")
    }
}
