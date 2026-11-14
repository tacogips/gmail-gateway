import Foundation
import MailGatewayCore

func testMessageFileDownload(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let materializedDir = URL(fileURLWithPath: fixture.attachmentRoot)
        .appendingPathComponent("personal", isDirectory: true)
        .appendingPathComponent("message-2", isDirectory: true)
    try writeMessageFiles(in: materializedDir)
    let lookupResult = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", """
        { messageFileSet(accountId: "personal", messageId: "message-2") \
        { hasFiles files { kind filename hasPayload downloadKey materializationState } } }
        """
    ])
    try assertMessageFileLookup(lookupResult)
    let bodyDownloadKey = try downloadKey(kind: "BODY_TEXT", from: lookupResult)
    try assertDownloadedFile(
        downloadKey: bodyDownloadKey,
        fixture: fixture,
        expectedKind: "BODY_TEXT",
        expectedContents: "private body payload"
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

func writeMessageFiles(in materializedDir: URL) throws {
    try writeText(materializedDir.appendingPathComponent("body.txt").path, "private body payload")
    try writeText(materializedDir.appendingPathComponent("body.html").path, "<p>private html payload</p>")
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
    expectedContents: String
) throws {
    let downloadDir = URL(fileURLWithPath: fixture.cacheRoot)
        .appendingPathComponent("downloads", isDirectory: true)
        .path
    let downloadResult = runCli([
        "file", "download",
        "--config", fixture.configPath,
        "--key", downloadKey,
        "--output-dir", downloadDir
    ])
    try assert(downloadResult.exitCode == 0, "file download command should succeed")
    let download = try decodeObject(downloadResult.stdout)
    guard let downloadedPath = download["localPath"] as? String else {
        throw SmokeTestFailure.assertionFailed("file download should return localPath")
    }
    try assert(download["kind"] as? String == expectedKind, "downloaded file kind should match")
    let downloadedContents = try? String(contentsOfFile: downloadedPath, encoding: .utf8)
    try assert(downloadedContents == expectedContents, "downloaded file payload should match")
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
