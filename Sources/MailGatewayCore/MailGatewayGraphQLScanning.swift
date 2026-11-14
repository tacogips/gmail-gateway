func prepareGraphQLQuery(_ query: String) throws -> String {
    let scannedQuery = strippingGraphQLComments(from: query)
    try rejectUnsupportedGraphQLFragmentsAndSpreads(in: scannedQuery)
    try rejectMultipleGraphQLRootFields(in: scannedQuery)
    return scannedQuery
}

private func strippingGraphQLComments(from query: String) -> String {
    var scannedQuery = ""
    var index = query.startIndex
    var inString = false
    var escaping = false
    var inComment = false
    while index < query.endIndex {
        let character = query[index]
        if inComment {
            if character == "\n" || character == "\r" {
                inComment = false
                scannedQuery.append(character)
            } else {
                scannedQuery.append(" ")
            }
            index = query.index(after: index)
            continue
        }
        if inString {
            scannedQuery.append(character)
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
            scannedQuery.append(character)
        } else if character == "#" {
            inComment = true
            scannedQuery.append(" ")
        } else {
            scannedQuery.append(character)
        }
        index = query.index(after: index)
    }
    return scannedQuery
}

private func rejectUnsupportedGraphQLFragmentsAndSpreads(in query: String) throws {
    if containsGraphQLSpread(in: query) || containsGraphQLName("fragment", in: query) {
        throw MailGatewayError(
            "GraphQL fragments and spreads are not supported",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
}

private func rejectMultipleGraphQLRootFields(in query: String) throws {
    let rootFields = graphQLRootFieldNames(in: query)
    guard rootFields.count <= 1 else {
        throw MailGatewayError(
            "Multiple GraphQL root fields are not supported: \(rootFields.joined(separator: ", "))",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
}

private func containsGraphQLSpread(in query: String) -> Bool {
    var index = query.startIndex
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
        } else if query[index...].hasPrefix("...") {
            return true
        }
        index = query.index(after: index)
    }
    return false
}

private func containsGraphQLName(_ name: String, in query: String) -> Bool {
    var index = query.startIndex
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
        } else if query[index...].hasPrefix(name) {
            let endIndex = query.index(index, offsetBy: name.count)
            let before = index > query.startIndex ? query[query.index(before: index)] : " "
            let after = endIndex < query.endIndex ? query[endIndex] : " "
            if !isGraphQLScanIdentifier(before) && !isGraphQLScanIdentifier(after) {
                return true
            }
        }
        index = query.index(after: index)
    }
    return false
}

private func graphQLRootFieldNames(in query: String) -> [String] {
    var names: [String] = []
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
        guard braceDepth == 1,
              parenDepth == 0,
              isGraphQLScanNameStart(character) else {
            index = query.index(after: index)
            continue
        }
        let parsed = graphQLRootFieldName(in: query, from: index)
        names.append(parsed.name)
        index = parsed.nextIndex
    }
    return names
}

private func graphQLRootFieldName(in query: String, from startIndex: String.Index) -> (name: String, nextIndex: String.Index) {
    let firstName = readGraphQLScanName(in: query, from: startIndex)
    var index = skipGraphQLScanWhitespace(in: query, from: firstName.endIndex)
    let fieldName: String
    if index < query.endIndex,
       query[index] == ":" {
        index = skipGraphQLScanWhitespace(in: query, from: query.index(after: index))
        let actualName = readGraphQLScanName(in: query, from: index)
        fieldName = actualName.name
        index = skipGraphQLScanWhitespace(in: query, from: actualName.endIndex)
    } else {
        fieldName = firstName.name
    }
    if index < query.endIndex,
       query[index] == "(",
       let endIndex = indexAfterBalancedGraphQLScanDelimiter(in: query, from: index, open: "(", close: ")") {
        index = skipGraphQLScanWhitespace(in: query, from: endIndex)
    }
    if index < query.endIndex,
       query[index] == "{",
       let endIndex = indexAfterBalancedGraphQLScanDelimiter(in: query, from: index, open: "{", close: "}") {
        index = endIndex
    }
    return (fieldName, index)
}

private func readGraphQLScanName(in query: String, from startIndex: String.Index) -> (name: String, endIndex: String.Index) {
    var index = startIndex
    while index < query.endIndex,
          isGraphQLScanIdentifier(query[index]) {
        index = query.index(after: index)
    }
    return (String(query[startIndex..<index]), index)
}

private func skipGraphQLScanWhitespace(in query: String, from startIndex: String.Index) -> String.Index {
    var index = startIndex
    while index < query.endIndex,
          query[index].isWhitespace {
        index = query.index(after: index)
    }
    return index
}

private func indexAfterBalancedGraphQLScanDelimiter(
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

private func isGraphQLScanIdentifier(_ character: Character) -> Bool {
    character == "_" || character.isLetter || character.isNumber
}

private func isGraphQLScanNameStart(_ character: Character) -> Bool {
    character == "_" || character.isLetter
}
