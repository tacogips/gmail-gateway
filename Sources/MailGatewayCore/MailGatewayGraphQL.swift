import Foundation

func executeReaderGraphQL(
    config: MailGatewayConfig,
    query: String
) throws -> (body: [String: Any], exitCode: MailGatewayExitCode) {
    let service = MailGatewayService(config: config)
    do {
        let scannedQuery = try prepareGraphQLQuery(query)
        return (["data": try executeReaderGraphQLData(service: service, query: scannedQuery)], .success)
    } catch let error as MailGatewayError where shouldReturnGraphQLError(error) {
        return (graphQLErrorBody(error), .graphqlExecutionError)
    }
}

private func executeReaderGraphQLData(service: MailGatewayService, query: String) throws -> [String: Any] {
    if rootFieldSource("sendMessage", in: query) != nil || rootFieldSource("createDraft", in: query) != nil {
        throw MailGatewayError(
            "Mail write mutations are disabled in mail-gateway-reader",
            code: .sendDisabledInReader,
            exitCode: .graphqlExecutionError
        )
    }
    if rootFieldSource("accounts", in: query) != nil {
        return ["accounts": service.graphQLAccounts()]
    }
    if let source = rootFieldSource("account", in: query) {
        return [
            "account": service.graphQLAccount(id: try extractStringArgument("id", from: source)) as Any? ?? NSNull()
        ]
    }
    if let source = rootFieldSource("threads", in: query) {
        try rejectUnsupportedThreadSearchArguments(in: source)
        try rejectUnsupportedThreadSearchInputFields(in: source)
        let selection = selectionBody(for: "threads", in: source, atBraceDepth: 0) ?? ""
        let edgeSelection = selectionBody(for: "edges", in: selection, atBraceDepth: 0) ?? ""
        let nodeSelection = selectionBody(for: "node", in: edgeSelection, atBraceDepth: 0) ?? ""
        return [
            "threads": projectThreadConnectionSelection(
                try service.searchThreads(
                    accountId: try extractStringArgument("accountId", from: source),
                    query: try extractOptionalStringArgument("query", from: source),
                    starred: try extractOptionalBooleanArgument("starred", from: source) ?? false,
                    direction: try extractOptionalThreadSearchDirectionArgument("direction", from: source),
                    labelIds: try extractOptionalStringArrayArgument("labelIds", from: source),
                    receivedAfter: try extractOptionalStringArgument("receivedAfter", from: source),
                    receivedBefore: try extractOptionalStringArgument("receivedBefore", from: source),
                    first: try extractOptionalIntArgument("first", from: source) ?? 20,
                    after: try extractOptionalStringArgument("after", from: source),
                    includeEdges: directFieldExists("edges", in: selection),
                    includeNodeDetails: directFieldExists("node", in: edgeSelection),
                    includeFullNodeDetails: threadNodeSelectionRequiresFullHydration(nodeSelection)
                ),
                selection: selection
            )
        ]
    }
    if let source = rootFieldSource("thread", in: query) {
        return try graphQLThreadData(service: service, query: source)
    }
    if let source = rootFieldSource("messageFileSet", in: query) {
        return try graphQLMessageFileSetData(service: service, query: source)
    }
    if let source = rootFieldSource("message", in: query) {
        return try graphQLMessageData(service: service, query: source)
    }
    if let source = rootFieldSource("attachment", in: query) {
        return try graphQLAttachmentData(service: service, query: source)
    }
    throw MailGatewayError(
        "Unsupported GraphQL query",
        code: .invalidArgument,
        exitCode: .graphqlExecutionError
    )
}

private func threadNodeSelectionRequiresFullHydration(_ selection: String) -> Bool {
    directFieldExists("messages", in: selection) ||
        directFieldExists("subject", in: selection) ||
        directFieldExists("labels", in: selection)
}

public func executeWriteGraphQL(
    config: MailGatewayConfig,
    query: String,
    mode: MailGatewayWriteMode
) throws -> (body: [String: Any], exitCode: MailGatewayExitCode) {
    let service = MailGatewayService(config: config)
    do {
        let scannedQuery = try prepareGraphQLQuery(query)
        if let source = rootFieldSource("createDraft", in: scannedQuery) {
            return (
                [
                    "data": [
                        "createDraft": try MailGatewayWriteService(config: config).sendMessage(
                            input: try outboundMailInput(from: source),
                            mode: .draftDefault
                        )
                    ]
                ],
                .success
            )
        }
        if let source = rootFieldSource("sendMessage", in: scannedQuery) {
            return (
                [
                    "data": [
                        "sendMessage": try MailGatewayWriteService(config: config).sendMessage(
                            input: try outboundMailInput(from: source),
                            mode: mode
                        )
                    ]
                ],
                .success
            )
        }
        return (["data": try executeWriteQueryData(service: service, query: scannedQuery)], .success)
    } catch let error as MailGatewayError where shouldReturnGraphQLError(error) {
        return (graphQLErrorBody(error), .graphqlExecutionError)
    }
}

private func shouldReturnGraphQLError(_ error: MailGatewayError) -> Bool {
    error.exitCode == .graphqlExecutionError || error.exitCode == .providerApiError
}

private func graphQLErrorBody(_ error: MailGatewayError) -> [String: Any] {
    let extensions: [String: Any] = [
        "code": error.code.rawValue,
        "exitCode": error.exitCode.rawValue,
        "requestId": UUID().uuidString
    ]
    let errors: [[String: Any]] = [[
        "message": error.message,
        "extensions": extensions
    ]]
    return [
        "data": NSNull(),
        "errors": errors
    ]
}

private func executeWriteQueryData(service: MailGatewayService, query: String) throws -> [String: Any] {
    if rootFieldSource("accounts", in: query) != nil {
        return ["accounts": service.graphQLAccounts(sendEnabled: true)]
    }
    if let source = rootFieldSource("account", in: query) {
        return [
            "account": service.graphQLAccount(
                id: try extractStringArgument("id", from: source),
                sendEnabled: true
            ) as Any? ?? NSNull()
        ]
    }
    return try executeReaderGraphQLData(service: service, query: query)
}

private func projectThreadConnectionSelection(_ connection: [String: Any], selection: String) -> [String: Any] {
    var object: [String: Any] = [:]
    if directFieldExists("totalCount", in: selection),
       let totalCount = connection["totalCount"] {
        object["totalCount"] = totalCount
    }
    if directFieldExists("pageInfo", in: selection),
       let pageInfo = connection["pageInfo"] {
        object["pageInfo"] = pageInfo
    }
    if directFieldExists("edges", in: selection),
       let edges = connection["edges"] {
        object["edges"] = projectThreadEdgesSelection(
            edges,
            selection: selectionBody(for: "edges", in: selection, atBraceDepth: 0) ?? ""
        )
    }
    return object
}

private func projectThreadEdgesSelection(_ edges: Any, selection: String) -> Any {
    guard let edgeObjects = edges as? [[String: Any]] else {
        return edges
    }
    guard !directFieldExists("node", in: selection) else {
        return edgeObjects
    }
    return edgeObjects.map { edge in
        var projected: [String: Any] = [:]
        if directFieldExists("cursor", in: selection),
           let cursor = edge["cursor"] {
            projected["cursor"] = cursor
        }
        return projected
    }
}

private func graphQLThreadData(service: MailGatewayService, query: String) throws -> [String: Any] {
    [
        "thread": try service.getThread(
            accountId: try extractStringArgument("accountId", from: query),
            threadId: try extractStringArgument("threadId", from: query)
        )
    ]
}

private func graphQLMessageFileSetData(service: MailGatewayService, query: String) throws -> [String: Any] {
    [
        "messageFileSet": try service.getMessageFileSet(
            accountId: try extractStringArgument("accountId", from: query),
            messageId: try extractStringArgument("messageId", from: query)
        )
    ]
}

private func graphQLMessageData(service: MailGatewayService, query: String) throws -> [String: Any] {
    [
        "message": try service.getMessage(
            accountId: try extractStringArgument("accountId", from: query),
            messageId: try extractStringArgument("messageId", from: query)
        )
    ]
}

private func graphQLAttachmentData(service: MailGatewayService, query: String) throws -> [String: Any] {
    let selection = selectionBody(for: "attachment", in: query, atBraceDepth: 0) ?? ""
    return [
        "attachment": projectAttachmentSelection(
            try service.getAttachment(
                accountId: extractStringArgument("accountId", from: query),
                messageId: extractStringArgument("messageId", from: query),
                attachmentId: extractStringArgument("attachmentId", from: query)
            ),
            selection: selection
        )
    ]
}

private func projectAttachmentSelection(_ attachment: Any, selection: String) -> Any {
    guard var object = attachment as? [String: Any] else {
        return attachment
    }
    object.removeValue(forKey: "localPath")
    for field in object.keys where !directFieldExists(field, in: selection) {
        object.removeValue(forKey: field)
    }
    return object
}

private func rootFieldSource(_ field: String, in query: String) -> String? {
    fieldSource(for: field, in: query, atBraceDepth: 1)
}

private func fieldSource(for field: String, in query: String, atBraceDepth braceDepth: Int) -> String? {
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

private func selectionBody(for field: String, in query: String, atBraceDepth braceDepth: Int) -> String? {
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

private func directFieldExists(_ field: String, in selection: String) -> Bool {
    rangeOfField(field, in: selection, atBraceDepth: 0) != nil
}

private func rangeOfField(_ field: String, in query: String, atBraceDepth requiredBraceDepth: Int?) -> Range<String.Index>? {
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

private func skipWhitespace(in query: String, from startIndex: String.Index) -> String.Index {
    var index = startIndex
    while index < query.endIndex,
          query[index].isWhitespace {
        index = query.index(after: index)
    }
    return index
}

private func indexAfterBalancedDelimiter(
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

private func isGraphQLIdentifier(_ character: Character) -> Bool {
    character == "_" || character.isLetter || character.isNumber
}

private func extractStringArgument(_ name: String, from query: String) throws -> String {
    guard let range = rangeOfArgumentLabel(name, in: query) else {
        throw MailGatewayError(
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
        throw MailGatewayError(
            "GraphQL argument \(name) must be a string literal",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    return try readGraphQLStringArgument(name: name, query: query, index: query.index(after: index))
}

private func extractOptionalStringArgument(_ name: String, from query: String) throws -> String? {
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
        throw MailGatewayError(
            "GraphQL argument \(name) must be a string literal",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    return try readGraphQLStringArgument(name: name, query: query, index: query.index(after: index))
}

private func extractOptionalBooleanArgument(_ name: String, from query: String) throws -> Bool? {
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
    throw MailGatewayError(
        "GraphQL argument \(name) must be a boolean literal",
        code: .invalidArgument,
        exitCode: .graphqlExecutionError
    )
}

private func extractOptionalIntArgument(_ name: String, from query: String) throws -> Int? {
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
        throw MailGatewayError(
            "GraphQL argument \(name) must be an integer literal",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    return value
}

private func extractOptionalThreadSearchDirectionArgument(
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
        throw MailGatewayError(
            "GraphQL argument \(name) must be SENT, RECEIVED, or ALL",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
}

private func extractOptionalStringOrEnumArgument(_ name: String, from query: String) throws -> String? {
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
        throw MailGatewayError(
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

private func outboundMailInput(from query: String) throws -> OutboundMailInput {
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

private let supportedThreadSearchFields: Set<String> = [
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

private func rejectUnsupportedThreadSearchArguments(in query: String) throws {
    guard let argumentBody = extractFieldArgumentListBody(from: query) else {
        return
    }
    let supportedArguments = supportedThreadSearchFields.union(["input"])
    let unsupportedArguments = objectFieldLabels(in: argumentBody).filter { !supportedArguments.contains($0) }
    guard unsupportedArguments.isEmpty else {
        throw MailGatewayError(
            "Unsupported threads argument(s): \(unsupportedArguments.joined(separator: ", "))",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
}

private func rejectUnsupportedThreadSearchInputFields(in query: String) throws {
    guard let inputBody = try extractObjectArgumentBody("input", from: query) else {
        return
    }
    let unsupportedFields = objectFieldLabels(in: inputBody).filter { !supportedThreadSearchFields.contains($0) }
    guard unsupportedFields.isEmpty else {
        throw MailGatewayError(
            "Unsupported ThreadSearchInput field(s): \(unsupportedFields.joined(separator: ", "))",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
}

private func extractFieldArgumentListBody(from query: String) -> String? {
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

private func extractObjectArgumentBody(_ name: String, from query: String) throws -> String? {
    guard let range = rangeOfArgumentLabel(name, in: query) else {
        return nil
    }
    let start = skipWhitespace(in: query, from: range.upperBound)
    guard start < query.endIndex,
          query[start] == "{" else {
        throw MailGatewayError(
            "GraphQL argument \(name) must be an object literal",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    guard let end = indexAfterBalancedDelimiter(in: query, from: start, open: "{", close: "}") else {
        throw MailGatewayError(
            "GraphQL argument \(name) object literal is unterminated",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    return String(query[query.index(after: start)..<query.index(before: end)])
}

private func objectFieldLabels(in objectBody: String) -> [String] {
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

private func extractOptionalStringArrayArgument(_ name: String, from query: String) throws -> [String]? {
    guard let range = rangeOfArgumentLabel(name, in: query) else {
        return nil
    }
    var index = skipWhitespace(in: query, from: range.upperBound)
    guard index < query.endIndex,
          query[index] == "[" else {
        throw MailGatewayError(
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
            throw MailGatewayError(
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
    throw MailGatewayError(
        "GraphQL argument \(name) array literal is unterminated",
        code: .invalidArgument,
        exitCode: .graphqlExecutionError
    )
}

private func rangeOfArgumentLabel(_ name: String, in query: String) -> Range<String.Index>? {
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

private func readGraphQLStringArgument(name: String, query: String, index: String.Index) throws -> String {
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
    throw MailGatewayError(
        "GraphQL argument \(name) string literal is unterminated",
        code: .invalidArgument,
        exitCode: .graphqlExecutionError
    )
}

private func indexAfterStringLiteral(in query: String, from startIndex: String.Index) -> String.Index {
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
