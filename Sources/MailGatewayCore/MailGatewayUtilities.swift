import Foundation

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
    let root = normalizedPath(rootPath)
    let candidate = normalizedPath(candidatePath)
    return candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
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
