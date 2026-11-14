import Foundation

func mailGatewayVersion() -> String {
    if let version = try? String(contentsOfFile: "VERSION", encoding: .utf8),
       let trimmed = nonBlank(version) {
        return trimmed
    }
    return "0.1.5"
}

func nonBlank(_ value: String?) -> String? {
    guard let value else {
        return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func normalizedPath(_ path: String) -> String {
    let expanded = NSString(string: path).expandingTildeInPath
    let isAbsolute = expanded.hasPrefix("/")
    var parts: [String] = []
    for component in expanded.split(separator: "/", omittingEmptySubsequences: true) {
        if component == "." {
            continue
        }
        if component == ".." {
            if !parts.isEmpty {
                parts.removeLast()
            }
            continue
        }
        parts.append(String(component))
    }
    let normalized = parts.joined(separator: "/")
    if isAbsolute {
        return "/" + normalized
    }
    return normalized.isEmpty ? "." : normalized
}

func isWithinRoot(rootPath: String, candidatePath: String) -> Bool {
    let root = canonicalPath(rootPath)
    let candidate = canonicalPath(candidatePath)
    return candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
}

private func canonicalPath(_ path: String) -> String {
    let normalized = normalizedPath(path)
    let isAbsolute = normalized.hasPrefix("/")
    var resolved = URL(
        fileURLWithPath: isAbsolute ? "/" : FileManager.default.currentDirectoryPath,
        isDirectory: true
    )
    for component in normalized.split(separator: "/", omittingEmptySubsequences: true) {
        resolved.appendPathComponent(String(component))
        if FileManager.default.fileExists(atPath: resolved.path) {
            resolved = resolved.resolvingSymlinksInPath()
        }
    }
    return normalizedPath(resolved.path)
}

func sanitizedPathComponent(_ value: String) -> String {
    let cleaned = value.map { character -> Character in
        character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
            ? character
            : "_"
    }
    let trimmed = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
    return trimmed.isEmpty ? "item" : trimmed
}

func sanitizedFilename(_ value: String) -> String {
    let lastPathComponent = URL(fileURLWithPath: value).lastPathComponent
    let cleaned = lastPathComponent.map { character -> Character in
        character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
            ? character
            : "_"
    }
    let trimmed = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return trimmed.isEmpty ? "file" : trimmed
}

func base64URLString(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func dataFromBase64URLString(_ value: String) -> Data? {
    guard isBase64URLString(value),
          value.count % 4 != 1 else {
        return nil
    }
    var base64 = value
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let padding = (4 - base64.count % 4) % 4
    base64 += String(repeating: "=", count: padding)
    return Data(base64Encoded: base64)
}

func formURLEncoded(_ fields: [(String, String)]) -> String {
    fields
        .map { key, value in
            "\(urlFormEncode(key))=\(urlFormEncode(value))"
        }
        .joined(separator: "&")
}

func intValue(_ value: Any?) -> Int? {
    if let value = value as? NSNumber {
        if value === kCFBooleanTrue || value === kCFBooleanFalse || CFGetTypeID(value) == CFBooleanGetTypeID() {
            return nil
        }
        let double = value.doubleValue
        guard double.isFinite,
              double >= Double(Int.min),
              double <= Double(Int.max),
              double.rounded(.towardZero) == double else {
            return nil
        }
        return Int(double)
    }
    if value is Bool {
        return nil
    }
    if let value = value as? Int {
        return value
    }
    if let value = value as? String {
        return nonBlank(value).flatMap(Int.init)
    }
    return nil
}

private func urlFormEncode(_ value: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private func isBase64URLString(_ value: String) -> Bool {
    var hasPadding = false
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 48...57, 65...90, 97...122, 45, 95:
            if hasPadding {
                return false
            }
        case 61:
            hasPadding = true
        default:
            return false
        }
    }
    return true
}
