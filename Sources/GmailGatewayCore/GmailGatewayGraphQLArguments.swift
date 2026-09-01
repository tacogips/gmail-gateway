import Foundation

func extractStringArgument(_ name: String, from query: String) throws -> String {
    guard let range = rangeOfArgumentLabel(name, in: query) else {
        throw GmailGatewayError(
            "Missing GraphQL argument: \(name)",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    var index = range.upperBound
    while index < query.endIndex,
          query[index].isWhitespace {
        index = query.index(after: index)
    }
    guard index < query.endIndex,
          query[index] == "\"" else {
        throw GmailGatewayError(
            "GraphQL argument \(name) must be a string literal",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    return try readGraphQLStringArgument(name: name, query: query, index: query.index(after: index))
}

func extractOptionalStringArgument(_ name: String, from query: String) throws -> String? {
    guard let range = rangeOfArgumentLabel(name, in: query) else {
        return nil
    }
    var index = range.upperBound
    while index < query.endIndex,
          query[index].isWhitespace {
        index = query.index(after: index)
    }
    guard index < query.endIndex,
          query[index] == "\"" else {
        throw GmailGatewayError(
            "GraphQL argument \(name) must be a string literal",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    return try readGraphQLStringArgument(name: name, query: query, index: query.index(after: index))
}

func extractOptionalBooleanArgument(_ name: String, from query: String) throws -> Bool? {
    guard let range = rangeOfArgumentLabel(name, in: query) else {
        return nil
    }
    let start = skipWhitespace(in: query, from: range.upperBound)
    var end = start
    while end < query.endIndex,
          isGraphQLIdentifier(query[end]) {
        end = query.index(after: end)
    }
    let value = String(query[start..<end])
    if value == "true" {
        return true
    }
    if value == "false" {
        return false
    }
    if value == "null" {
        return nil
    }
    throw GmailGatewayError(
        "GraphQL argument \(name) must be a boolean literal",
        code: .invalidArgument,
        exitCode: .graphqlExecutionError
    )
}

func extractOptionalIntArgument(_ name: String, from query: String) throws -> Int? {
    guard let range = rangeOfArgumentLabel(name, in: query) else {
        return nil
    }
    var index = skipWhitespace(in: query, from: range.upperBound)
    if query[index...].hasPrefix("null") {
        return nil
    }
    let start = index
    if index < query.endIndex,
       query[index] == "-" {
        index = query.index(after: index)
    }
    while index < query.endIndex,
          query[index].isNumber {
        index = query.index(after: index)
    }
    guard start < index,
          let value = Int(query[start..<index]) else {
        throw GmailGatewayError(
            "GraphQL argument \(name) must be an integer literal",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    return value
}

func extractOptionalThreadSearchDirectionArgument(
    _ name: String,
    from query: String
) throws -> ThreadSearchDirection? {
    guard let value = try extractOptionalStringOrEnumArgument(name, from: query) else {
        return nil
    }
    switch value.uppercased() {
    case ThreadSearchDirection.sent.rawValue:
        return .sent
    case ThreadSearchDirection.received.rawValue:
        return .received
    case ThreadSearchDirection.all.rawValue:
        return .all
    default:
        throw GmailGatewayError(
            "GraphQL argument \(name) must be SENT, RECEIVED, or ALL",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
}

func extractOptionalStringOrEnumArgument(_ name: String, from query: String) throws -> String? {
    guard let range = rangeOfArgumentLabel(name, in: query) else {
        return nil
    }
    var index = skipWhitespace(in: query, from: range.upperBound)
    if index < query.endIndex,
       query[index] == "\"" {
        return try readGraphQLStringArgument(name: name, query: query, index: query.index(after: index))
    }
    let start = index
    while index < query.endIndex,
          isGraphQLIdentifier(query[index]) {
        index = query.index(after: index)
    }
    guard start < index else {
        throw GmailGatewayError(
            "GraphQL argument \(name) must be a string or enum literal",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    let value = String(query[start..<index])
    if value == "null" {
        return nil
    }
    return value
}

func outboundMailInput(from query: String) throws -> OutboundMailInput {
    OutboundMailInput(
        accountId: try extractStringArgument("accountId", from: query),
        to: try extractOptionalStringArrayArgument("to", from: query) ?? [],
        cc: try extractOptionalStringArrayArgument("cc", from: query) ?? [],
        bcc: try extractOptionalStringArrayArgument("bcc", from: query) ?? [],
        replyTo: try extractOptionalStringArgument("replyTo", from: query),
        subject: try extractOptionalStringArgument("subject", from: query),
        textBody: try extractOptionalStringArgument("textBody", from: query),
        htmlBody: try extractOptionalStringArgument("htmlBody", from: query),
        attachmentPaths: try extractOptionalStringArrayArgument("attachmentPaths", from: query) ?? []
    )
}

func replyMessageInput(from query: String) throws -> ReplyMessageInput {
    ReplyMessageInput(
        accountId: try extractStringArgument("accountId", from: query),
        messageId: try extractStringArgument("messageId", from: query),
        to: try extractOptionalStringArrayArgument("to", from: query) ?? [],
        cc: try extractOptionalStringArrayArgument("cc", from: query) ?? [],
        bcc: try extractOptionalStringArrayArgument("bcc", from: query) ?? [],
        replyAll: try extractOptionalBooleanArgument("replyAll", from: query) ?? false,
        textBody: try extractOptionalStringArgument("textBody", from: query),
        htmlBody: try extractOptionalStringArgument("htmlBody", from: query),
        attachmentPaths: try extractOptionalStringArrayArgument("attachmentPaths", from: query) ?? []
    )
}

func forwardMessageInput(from query: String) throws -> ForwardMessageInput {
    ForwardMessageInput(
        accountId: try extractStringArgument("accountId", from: query),
        messageId: try extractStringArgument("messageId", from: query),
        to: try extractOptionalStringArrayArgument("to", from: query) ?? [],
        cc: try extractOptionalStringArrayArgument("cc", from: query) ?? [],
        bcc: try extractOptionalStringArrayArgument("bcc", from: query) ?? [],
        textBody: try extractOptionalStringArgument("textBody", from: query),
        htmlBody: try extractOptionalStringArgument("htmlBody", from: query),
        includeAttachments: try extractOptionalBooleanArgument("includeAttachments", from: query) ?? true,
        attachmentPaths: try extractOptionalStringArrayArgument("attachmentPaths", from: query) ?? []
    )
}

let supportedThreadSearchFields: Set<String> = [
    "accountId",
    "query",
    "starred",
    "direction",
    "labelIds",
    "receivedAfter",
    "receivedBefore",
    "first",
    "after"
]

func rejectUnsupportedThreadSearchArguments(in query: String) throws {
    guard let argumentBody = extractFieldArgumentListBody(from: query) else {
        return
    }
    let supportedArguments = supportedThreadSearchFields.union(["input"])
    let unsupportedArguments = objectFieldLabels(in: argumentBody).filter { !supportedArguments.contains($0) }
    guard unsupportedArguments.isEmpty else {
        throw GmailGatewayError(
            "Unsupported threads argument(s): \(unsupportedArguments.joined(separator: ", "))",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
}

func rejectUnsupportedThreadSearchInputFields(in query: String) throws {
    guard let inputBody = try extractObjectArgumentBody("input", from: query) else {
        return
    }
    let unsupportedFields = objectFieldLabels(in: inputBody).filter { !supportedThreadSearchFields.contains($0) }
    guard unsupportedFields.isEmpty else {
        throw GmailGatewayError(
            "Unsupported ThreadSearchInput field(s): \(unsupportedFields.joined(separator: ", "))",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
}

func extractFieldArgumentListBody(from query: String) -> String? {
    var index = query.startIndex
    while index < query.endIndex,
          isGraphQLIdentifier(query[index]) {
        index = query.index(after: index)
    }
    index = skipWhitespace(in: query, from: index)
    guard index < query.endIndex,
          query[index] == "(",
          let end = indexAfterBalancedDelimiter(in: query, from: index, open: "(", close: ")") else {
        return nil
    }
    return String(query[query.index(after: index)..<query.index(before: end)])
}

func extractObjectArgumentBody(_ name: String, from query: String) throws -> String? {
    guard let range = rangeOfArgumentLabel(name, in: query) else {
        return nil
    }
    let start = skipWhitespace(in: query, from: range.upperBound)
    guard start < query.endIndex,
          query[start] == "{" else {
        throw GmailGatewayError(
            "GraphQL argument \(name) must be an object literal",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    guard let end = indexAfterBalancedDelimiter(in: query, from: start, open: "{", close: "}") else {
        throw GmailGatewayError(
            "GraphQL argument \(name) object literal is unterminated",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    return String(query[query.index(after: start)..<query.index(before: end)])
}

func objectFieldLabels(in objectBody: String) -> [String] {
    var labels: [String] = []
    var index = objectBody.startIndex
    var inString = false
    var escaping = false
    var braceDepth = 0
    var bracketDepth = 0
    var parenDepth = 0
    while index < objectBody.endIndex {
        let character = objectBody[index]
        if inString {
            if escaping {
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "\"" {
                inString = false
            }
            index = objectBody.index(after: index)
            continue
        }
        if character == "\"" {
            inString = true
            index = objectBody.index(after: index)
            continue
        }
        if character == "{" {
            braceDepth += 1
            index = objectBody.index(after: index)
            continue
        }
        if character == "}" {
            braceDepth = max(0, braceDepth - 1)
            index = objectBody.index(after: index)
            continue
        }
        if character == "[" {
            bracketDepth += 1
            index = objectBody.index(after: index)
            continue
        }
        if character == "]" {
            bracketDepth = max(0, bracketDepth - 1)
            index = objectBody.index(after: index)
            continue
        }
        if character == "(" {
            parenDepth += 1
            index = objectBody.index(after: index)
            continue
        }
        if character == ")" {
            parenDepth = max(0, parenDepth - 1)
            index = objectBody.index(after: index)
            continue
        }
        if braceDepth == 0,
           bracketDepth == 0,
           parenDepth == 0,
           character == "_" || character.isLetter {
            let start = index
            repeat {
                index = objectBody.index(after: index)
            } while index < objectBody.endIndex && isGraphQLIdentifier(objectBody[index])
            let labelEnd = skipWhitespace(in: objectBody, from: index)
            if labelEnd < objectBody.endIndex,
               objectBody[labelEnd] == ":" {
                labels.append(String(objectBody[start..<index]))
            }
            continue
        }
        index = objectBody.index(after: index)
    }
    return labels
}

func extractOptionalStringArrayArgument(_ name: String, from query: String) throws -> [String]? {
    guard let range = rangeOfArgumentLabel(name, in: query) else {
        return nil
    }
    var index = skipWhitespace(in: query, from: range.upperBound)
    guard index < query.endIndex,
          query[index] == "[" else {
        throw GmailGatewayError(
            "GraphQL argument \(name) must be a string array literal",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    index = query.index(after: index)
    var values: [String] = []
    while index < query.endIndex {
        index = skipWhitespace(in: query, from: index)
        if index < query.endIndex,
           query[index] == "]" {
            return values
        }
        guard index < query.endIndex,
              query[index] == "\"" else {
            throw GmailGatewayError(
                "GraphQL argument \(name) must contain string literals",
                code: .invalidArgument,
                exitCode: .graphqlExecutionError
            )
        }
        values.append(try readGraphQLStringArgument(name: name, query: query, index: query.index(after: index)))
        index = indexAfterStringLiteral(in: query, from: query.index(after: index))
        index = skipWhitespace(in: query, from: index)
        if index < query.endIndex,
           query[index] == "," {
            index = query.index(after: index)
        }
    }
    throw GmailGatewayError(
        "GraphQL argument \(name) array literal is unterminated",
        code: .invalidArgument,
        exitCode: .graphqlExecutionError
    )
}

func rangeOfArgumentLabel(_ name: String, in query: String) -> Range<String.Index>? {
    var index = query.startIndex
    var inString = false
    var escaping = false
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
        if query[index...].hasPrefix(name) {
            let nameEndIndex = query.index(index, offsetBy: name.count)
            let before = index > query.startIndex ? query[query.index(before: index)] : " "
            let after = nameEndIndex < query.endIndex ? query[nameEndIndex] : " "
            if parenDepth > 0 && !isGraphQLIdentifier(before) && !isGraphQLIdentifier(after) {
                var labelEndIndex = nameEndIndex
                while labelEndIndex < query.endIndex,
                      query[labelEndIndex].isWhitespace {
                    labelEndIndex = query.index(after: labelEndIndex)
                }
                if labelEndIndex < query.endIndex,
                   query[labelEndIndex] == ":" {
                    return index..<query.index(after: labelEndIndex)
                }
            }
        }
        index = query.index(after: index)
    }
    return nil
}

func readGraphQLStringArgument(name: String, query: String, index: String.Index) throws -> String {
    var index = index
    var value = ""
    var escaping = false
    while index < query.endIndex {
        let character = query[index]
        if escaping {
            switch character {
            case "n":
                value.append("\n")
            case "r":
                value.append("\r")
            case "t":
                value.append("\t")
            case "\"", "\\", "/":
                value.append(character)
            case "b":
                value.append("\u{08}")
            case "f":
                value.append("\u{0c}")
            default:
                value.append(character)
            }
            escaping = false
        } else if character == "\\" {
            escaping = true
        } else if character == "\"" {
            return value
        } else {
            value.append(character)
        }
        index = query.index(after: index)
    }
    throw GmailGatewayError(
        "GraphQL argument \(name) string literal is unterminated",
        code: .invalidArgument,
        exitCode: .graphqlExecutionError
    )
}

func indexAfterStringLiteral(in query: String, from startIndex: String.Index) -> String.Index {
    var index = startIndex
    var escaping = false
    while index < query.endIndex {
        let character = query[index]
        if escaping {
            escaping = false
        } else if character == "\\" {
            escaping = true
        } else if character == "\"" {
            return query.index(after: index)
        }
        index = query.index(after: index)
    }
    return query.endIndex
}
