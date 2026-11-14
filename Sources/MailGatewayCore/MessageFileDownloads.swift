import Foundation

struct MessageFileDownloadKey {
    let accountId: String
    let messageId: String
    let kind: MessageMaterializedFileKind
    let filename: String
}

private struct MessageFileMetadataInput {
    let accountId: String
    let messageId: String
    let kind: MessageMaterializedFileKind
    let url: URL
    let filename: String
    let mimeType: String
}

private enum MessageFileDownloadLayout {
    case flat
    case messageScoped
}

extension MailGatewayReaderService {
    public func getMessageFileSet(accountId: String, messageId: String) throws -> [String: Any] {
        _ = try requireAccount(accountId)
        return buildMessageFileSet(accountId: accountId, messageId: messageId)
    }

    public func downloadFile(downloadKey: String, outputDirectory: String?) throws -> [String: Any] {
        let key = try decodeMessageFileDownloadKey(downloadKey)
        return try downloadFile(key: key, rawDownloadKey: downloadKey, outputDirectory: outputDirectory, layout: .flat)
    }

    public func downloadFiles(downloadKeys: [String], outputDirectory: String?) throws -> [String: Any] {
        let files = try downloadKeys.map { downloadKey in
            let key = try decodeMessageFileDownloadKey(downloadKey)
            return try downloadFile(
                key: key,
                rawDownloadKey: downloadKey,
                outputDirectory: outputDirectory,
                layout: .messageScoped
            )
        }
        return [
            "fileCount": files.count,
            "files": files
        ]
    }

    private func downloadFile(
        key: MessageFileDownloadKey,
        rawDownloadKey: String,
        outputDirectory: String?,
        layout: MessageFileDownloadLayout
    ) throws -> [String: Any] {
        _ = try requireAccount(key.accountId)
        let sourceURL = messageFileURL(for: key)
        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw MailGatewayError(
                "Message file is not materialized locally",
                code: .attachmentNotFound,
                exitCode: .graphqlExecutionError,
                details: ["downloadKey": rawDownloadKey]
            )
        }

        let outputURL = try copiedFileURL(
            sourceURL: sourceURL,
            key: key,
            outputDirectory: outputDirectory,
            layout: layout
        )
        return messageFileMetadata(
            MessageFileMetadataInput(
                accountId: key.accountId,
                messageId: key.messageId,
                kind: key.kind,
                url: outputURL,
                filename: key.filename,
                mimeType: mimeType(for: key.kind)
            ),
            includeDownloadKey: false
        )
    }

    private func buildMessageFileSet(accountId: String, messageId: String) -> [String: Any] {
        let files = messageFiles(accountId: accountId, messageId: messageId)
        return [
            "accountId": accountId,
            "messageId": messageId,
            "hasFiles": !files.isEmpty,
            "files": files
        ]
    }

    private func messageFiles(accountId: String, messageId: String) -> [[String: Any]] {
        let directory = messageDirectory(accountId: accountId, messageId: messageId)
        let bodyFiles = [
            messageFileIfExists(
                MessageFileMetadataInput(
                    accountId: accountId,
                    messageId: messageId,
                    kind: .bodyText,
                    url: directory.appendingPathComponent("body.txt"),
                    filename: "body.txt",
                    mimeType: "text/plain"
                )
            ),
            messageFileIfExists(
                MessageFileMetadataInput(
                    accountId: accountId,
                    messageId: messageId,
                    kind: .bodyHTML,
                    url: directory.appendingPathComponent("body.html"),
                    filename: "body.html",
                    mimeType: "text/html"
                )
            )
        ].compactMap { $0 }
        return bodyFiles + temporaryFiles(accountId: accountId, messageId: messageId, directory: directory)
    }

    private func messageFileIfExists(_ input: MessageFileMetadataInput) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: input.url.path) else {
            return nil
        }
        return messageFileMetadata(input)
    }

    private func temporaryFiles(accountId: String, messageId: String, directory: URL) -> [[String: Any]] {
        let tempDirectory = directory.appendingPathComponent("temp", isDirectory: true)
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
        return entries.map { entry in
            messageFileMetadata(
                MessageFileMetadataInput(
                    accountId: accountId,
                    messageId: messageId,
                    kind: .temporaryFile,
                    url: tempDirectory.appendingPathComponent(entry),
                    filename: entry,
                    mimeType: "application/octet-stream"
                )
            )
        }
    }

    private func copiedFileURL(
        sourceURL: URL,
        key: MessageFileDownloadKey,
        outputDirectory: String?,
        layout: MessageFileDownloadLayout
    ) throws -> URL {
        guard let outputDirectory = nonBlank(outputDirectory) else {
            return sourceURL
        }
        let directory = scopedOutputDirectory(
            root: try validateDownloadOutputDirectory(outputDirectory),
            key: key,
            layout: layout
        )
        let outputURL = directory.appendingPathComponent(key.filename)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: outputURL)
        } catch {
            throw MailGatewayError(
                "Failed to copy downloaded message file",
                code: .configInvalid,
                exitCode: .configurationError,
                details: [
                    "source": normalizedPath(sourceURL.path),
                    "destination": normalizedPath(outputURL.path),
                    "cause": error.localizedDescription
                ]
            )
        }
        return outputURL
    }

    private func scopedOutputDirectory(
        root: URL,
        key: MessageFileDownloadKey,
        layout: MessageFileDownloadLayout
    ) -> URL {
        switch layout {
        case .flat:
            return root
        case .messageScoped:
            return root
                .appendingPathComponent(sanitizedPathComponent(key.accountId), isDirectory: true)
                .appendingPathComponent(sanitizedPathComponent(key.messageId), isDirectory: true)
        }
    }

    private func messageDirectory(accountId: String, messageId: String) -> URL {
        URL(fileURLWithPath: attachmentRoot)
            .appendingPathComponent(sanitizedPathComponent(accountId), isDirectory: true)
            .appendingPathComponent(sanitizedPathComponent(messageId), isDirectory: true)
    }

    private func messageFileMetadata(
        _ input: MessageFileMetadataInput,
        includeDownloadKey: Bool = true
    ) -> [String: Any] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: input.url.path)
        var metadata: [String: Any] = [
            "kind": input.kind.rawValue,
            "filename": input.filename,
            "hasPayload": true,
            "mimeType": input.mimeType,
            "sizeBytes": attributes?[.size] as? NSNumber ?? NSNull(),
            "materializationState": AttachmentMaterializationState.cached.rawValue
        ]
        if includeDownloadKey {
            metadata["downloadKey"] = encodeMessageFileDownloadKey(MessageFileDownloadKey(
                accountId: input.accountId,
                messageId: input.messageId,
                kind: input.kind,
                filename: input.filename
            ))
        } else {
            metadata["localPath"] = normalizedPath(input.url.path)
        }
        return metadata
    }

    private func messageFileURL(for key: MessageFileDownloadKey) -> URL {
        let directory = messageDirectory(accountId: key.accountId, messageId: key.messageId)
        switch key.kind {
        case .bodyText:
            return directory.appendingPathComponent("body.txt")
        case .bodyHTML:
            return directory.appendingPathComponent("body.html")
        case .temporaryFile:
            return directory
                .appendingPathComponent("temp", isDirectory: true)
                .appendingPathComponent(sanitizedFilename(key.filename))
        }
    }

    private func validateDownloadOutputDirectory(_ outputDirectory: String) throws -> URL {
        let normalizedOutput = normalizedPath(outputDirectory)
        let allowedRoots = [attachmentRoot, cacheRoot, normalizedPath(NSTemporaryDirectory())]
        guard allowedRoots.contains(where: { isWithinRoot(rootPath: $0, candidatePath: normalizedOutput) }) else {
            throw MailGatewayError(
                "Download output directory must be under storage.attachment_dir, storage.cache_dir, " +
                    "or the system temporary directory",
                code: .configInvalid,
                exitCode: .configurationError,
                details: ["outputDirectory": normalizedOutput]
            )
        }
        return URL(fileURLWithPath: normalizedOutput, isDirectory: true)
    }

    private func mimeType(for kind: MessageMaterializedFileKind) -> String {
        switch kind {
        case .bodyText:
            return "text/plain"
        case .bodyHTML:
            return "text/html"
        case .temporaryFile:
            return "application/octet-stream"
        }
    }
}

func encodeMessageFileDownloadKey(_ key: MessageFileDownloadKey) -> String {
    let payload: [String: Any] = [
        "v": 1,
        "accountId": key.accountId,
        "messageId": key.messageId,
        "kind": key.kind.rawValue,
        "filename": key.filename
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
        return ""
    }
    return "mgf_" + base64URLString(data)
}

func decodeMessageFileDownloadKey(_ rawKey: String) throws -> MessageFileDownloadKey {
    guard rawKey.hasPrefix("mgf_"),
          let data = dataFromBase64URLString(String(rawKey.dropFirst(4))),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["v"] as? Int == 1,
          let accountId = object["accountId"] as? String,
          let messageId = object["messageId"] as? String,
          let kindRaw = object["kind"] as? String,
          let kind = MessageMaterializedFileKind(rawValue: kindRaw),
          let filename = object["filename"] as? String
    else {
        throw MailGatewayError(
            "Invalid message file download key",
            code: .invalidArgument,
            exitCode: .invalidCliUsage
        )
    }
    return MessageFileDownloadKey(
        accountId: accountId,
        messageId: messageId,
        kind: kind,
        filename: sanitizedFilename(filename)
    )
}

private func base64URLString(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func dataFromBase64URLString(_ value: String) -> Data? {
    var base64 = value
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let padding = (4 - base64.count % 4) % 4
    base64 += String(repeating: "=", count: padding)
    return Data(base64Encoded: base64)
}
