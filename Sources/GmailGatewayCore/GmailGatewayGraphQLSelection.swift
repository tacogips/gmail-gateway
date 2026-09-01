import Foundation

func rootFieldSource(_ field: String, in query: String) -> String? {
    fieldSource(for: field, in: query, atBraceDepth: 1)
}

func fieldSource(for field: String, in query: String, atBraceDepth braceDepth: Int) -> String? {
    guard let range = rangeOfField(field, in: query, atBraceDepth: braceDepth) else {
        return nil
    }
    var index = skipWhitespace(in: query, from: range.upperBound)
    if index < query.endIndex,
       query[index] == "(",
       let endIndex = indexAfterBalancedDelimiter(in: query, from: index, open: "(", close: ")") {
        index = skipWhitespace(in: query, from: endIndex)
    }
    if index < query.endIndex,
       query[index] == "{",
       let endIndex = indexAfterBalancedDelimiter(in: query, from: index, open: "{", close: "}") {
        return String(query[range.lowerBound..<endIndex])
    }
    return String(query[range.lowerBound..<index])
}

func selectionBody(for field: String, in query: String, atBraceDepth braceDepth: Int) -> String? {
    guard let range = rangeOfField(field, in: query, atBraceDepth: braceDepth) else {
        return nil
    }
    var index = skipWhitespace(in: query, from: range.upperBound)
    if index < query.endIndex,
       query[index] == "(",
       let endIndex = indexAfterBalancedDelimiter(in: query, from: index, open: "(", close: ")") {
        index = skipWhitespace(in: query, from: endIndex)
    }
    guard index < query.endIndex,
          query[index] == "{",
          let endIndex = indexAfterBalancedDelimiter(in: query, from: index, open: "{", close: "}") else {
        return nil
    }
    return String(query[query.index(after: index)..<query.index(before: endIndex)])
}

func directFieldExists(_ field: String, in selection: String) -> Bool {
    rangeOfField(field, in: selection, atBraceDepth: 0) != nil
}

func rangeOfField(_ field: String, in query: String, atBraceDepth requiredBraceDepth: Int?) -> Range<String.Index>? {
    var index = query.startIndex
    var inString = false
    var escaping = false
    var braceDepth = 0
    var parenDepth = 0
    while index < query.endIndex {
        let character = query[index]
        if inString {
            if escaping {
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "\"" {
                inString = false
            }
            index = query.index(after: index)
            continue
        }
        if character == "\"" {
            inString = true
            index = query.index(after: index)
            continue
        }
        if character == "{" {
            braceDepth += 1
            index = query.index(after: index)
            continue
        }
        if character == "}" {
            braceDepth = max(0, braceDepth - 1)
            index = query.index(after: index)
            continue
        }
        if character == "(" {
            parenDepth += 1
            index = query.index(after: index)
            continue
        }
        if character == ")" {
            parenDepth = max(0, parenDepth - 1)
            index = query.index(after: index)
            continue
        }
        if query[index...].hasPrefix(field) {
            let endIndex = query.index(index, offsetBy: field.count)
            let before = index > query.startIndex ? query[query.index(before: index)] : " "
            let after = endIndex < query.endIndex ? query[endIndex] : " "
            let braceDepthMatches = requiredBraceDepth.map { $0 == braceDepth } ?? true
            if braceDepthMatches && parenDepth == 0 && !isGraphQLIdentifier(before) && !isGraphQLIdentifier(after),
               !isAliasName(in: query, range: index..<endIndex) {
                return index..<endIndex
            }
        }
        index = query.index(after: index)
    }
    return nil
}

private func isAliasName(in query: String, range: Range<String.Index>) -> Bool {
    let index = skipWhitespace(in: query, from: range.upperBound)
    return index < query.endIndex && query[index] == ":"
}

func skipWhitespace(in query: String, from startIndex: String.Index) -> String.Index {
    var index = startIndex
    while index < query.endIndex,
          query[index].isWhitespace {
        index = query.index(after: index)
    }
    return index
}

func indexAfterBalancedDelimiter(
    in query: String,
    from openIndex: String.Index,
    open: Character,
    close: Character
) -> String.Index? {
    var index = openIndex
    var depth = 0
    var inString = false
    var escaping = false
    while index < query.endIndex {
        let character = query[index]
        if inString {
            if escaping {
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "\"" {
                inString = false
            }
            index = query.index(after: index)
            continue
        }
        if character == "\"" {
            inString = true
            index = query.index(after: index)
            continue
        }
        if character == open {
            depth += 1
        } else if character == close {
            depth -= 1
            if depth == 0 {
                return query.index(after: index)
            }
        }
        index = query.index(after: index)
    }
    return nil
}

func isGraphQLIdentifier(_ character: Character) -> Bool {
    character == "_" || character.isLetter || character.isNumber
}
