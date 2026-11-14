import Foundation

struct ParsedArgs {
    let positionals: [String]
    let flags: [String: StringOrBool]
    let repeatedFlags: [String: [StringOrBool]]
}

enum StringOrBool {
    case string(String)
    case bool(Bool)
}

func parseArguments(_ arguments: [String]) throws -> ParsedArgs {
    var positionals: [String] = []
    var flags: [String: StringOrBool] = [:]
    var repeatedFlags: [String: [StringOrBool]] = [:]
    let booleanFlags: Set<String> = ["all", "open-browser", "pretty"]
    var index = 0

    while index < arguments.count {
        let token = arguments[index]
        if !token.hasPrefix("--") {
            positionals.append(token)
            index += 1
            continue
        }

        let flagBody = String(token.dropFirst(2))
        guard !flagBody.isEmpty else {
            throw GmailGatewayError("Invalid empty flag", code: .invalidArgument, exitCode: .invalidCliUsage)
        }

        let split = flagBody.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(split[0])
        if split.count == 2 {
            let value = StringOrBool.string(String(split[1]))
            flags[key] = value
            repeatedFlags[key, default: []].append(value)
            index += 1
            continue
        }

        let next = index + 1 < arguments.count ? arguments[index + 1] : nil
        if booleanFlags.contains(key),
           next == nil || next != "true" && next != "false" {
            let value = StringOrBool.bool(true)
            flags[key] = value
            repeatedFlags[key, default: []].append(value)
            index += 1
            continue
        }

        if let next,
           !next.hasPrefix("--") {
            let value = StringOrBool.string(next)
            flags[key] = value
            repeatedFlags[key, default: []].append(value)
            index += 2
            continue
        }

        let value = StringOrBool.bool(true)
        flags[key] = value
        repeatedFlags[key, default: []].append(value)
        index += 1
    }

    return ParsedArgs(positionals: positionals, flags: flags, repeatedFlags: repeatedFlags)
}

func getStringFlag(_ flags: [String: StringOrBool], _ name: String) throws -> String? {
    guard let value = flags[name] else {
        return nil
    }
    switch value {
    case .string(let value):
        return value
    case .bool:
        throw GmailGatewayError("--\(name) requires a value", code: .invalidArgument, exitCode: .invalidCliUsage)
    }
}

func getStringFlags(_ flags: [String: [StringOrBool]], _ name: String) throws -> [String] {
    try (flags[name] ?? []).map { value in
        switch value {
        case .string(let value):
            return value
        case .bool:
            throw GmailGatewayError("--\(name) requires a value", code: .invalidArgument, exitCode: .invalidCliUsage)
        }
    }
}

func getBooleanFlag(_ flags: [String: StringOrBool], _ name: String) throws -> Bool {
    try getBooleanFlag(flags, name, defaultValue: false)
}

func getBooleanFlag(_ flags: [String: StringOrBool], _ name: String, defaultValue: Bool) throws -> Bool {
    guard let value = flags[name] else {
        return defaultValue
    }
    switch value {
    case .bool(let value):
        return value
    case .string("true"):
        return true
    case .string("false"):
        return false
    case .string:
        throw GmailGatewayError(
            "--\(name) accepts only true or false when given a value",
            code: .invalidArgument,
            exitCode: .invalidCliUsage
        )
    }
}

func getIntFlag(
    _ flags: [String: StringOrBool],
    _ name: String,
    defaultValue: Int,
    minimum: Int,
    maximum: Int
) throws -> Int {
    guard let rawValue = try getStringFlag(flags, name) else {
        return defaultValue
    }
    guard let value = Int(rawValue),
          value >= minimum,
          value <= maximum else {
        throw GmailGatewayError(
            "--\(name) must be an integer from \(minimum) through \(maximum)",
            code: .invalidArgument,
            exitCode: .invalidCliUsage
        )
    }
    return value
}

func loadQuery(flags: [String: StringOrBool]) throws -> String {
    let inlineQuery = try getStringFlag(flags, "query")
    let queryFile = try getStringFlag(flags, "query-file")
    if (inlineQuery == nil) == (queryFile == nil) {
        throw GmailGatewayError(
            "Exactly one of --query or --query-file is required",
            code: .invalidArgument,
            exitCode: .invalidCliUsage
        )
    }
    if let inlineQuery {
        return inlineQuery
    }
    let path = queryFile!
    do {
        return try String(contentsOfFile: path, encoding: .utf8)
    } catch {
        throw GmailGatewayError(
            "Failed to read GraphQL query file: \(path)",
            code: .invalidArgument,
            exitCode: .invalidCliUsage,
            details: ["cause": error.localizedDescription]
        )
    }
}

func loadVariables(flags: [String: StringOrBool]) throws -> [String: Any] {
    let inlineVariables = try getStringFlag(flags, "variables")
    let variablesFile = try getStringFlag(flags, "variables-file")
    if inlineVariables != nil && variablesFile != nil {
        throw GmailGatewayError(
            "Use only one of --variables or --variables-file",
            code: .invalidArgument,
            exitCode: .invalidCliUsage
        )
    }
    if let inlineVariables {
        return try parseJsonObject(
            inlineVariables,
            invalidJsonMessage: "--variables must be valid JSON",
            invalidObjectMessage: "--variables must be a JSON object"
        )
    }
    if let variablesFile {
        return try loadVariablesFile(variablesFile)
    }
    return [:]
}

func rejectUnsupportedVariables(flags: [String: StringOrBool]) throws {
    if flags["variables"] != nil || flags["variables-file"] != nil {
        throw GmailGatewayError(
            "GraphQL variables are not supported yet; inline literal arguments in --query or --query-file",
            code: .invalidArgument,
            exitCode: .invalidCliUsage
        )
    }
}

private func loadVariablesFile(_ path: String) throws -> [String: Any] {
    do {
        let source = try String(contentsOfFile: path, encoding: .utf8)
        return try parseJsonObject(
            source,
            invalidJsonMessage: "Failed to parse JSON variables file: \(path)",
            invalidObjectMessage: "JSON variables file must contain an object: \(path)"
        )
    } catch let error as GmailGatewayError {
        throw error
    } catch {
        throw GmailGatewayError(
            "Failed to read JSON variables file: \(path)",
            code: .invalidArgument,
            exitCode: .invalidCliUsage,
            details: ["cause": error.localizedDescription]
        )
    }
}

private func parseJsonObject(
    _ source: String,
    invalidJsonMessage: String,
    invalidObjectMessage: String
) throws -> [String: Any] {
    let value: Any
    do {
        value = try JSONSerialization.jsonObject(with: Data(source.utf8))
    } catch {
        throw GmailGatewayError(
            invalidJsonMessage,
            code: .invalidArgument,
            exitCode: .invalidCliUsage,
            details: ["cause": error.localizedDescription]
        )
    }
    guard let object = value as? [String: Any] else {
        throw GmailGatewayError(invalidObjectMessage, code: .invalidArgument, exitCode: .invalidCliUsage)
    }
    return object
}

func errorOutput(_ error: GmailGatewayError) -> [String: Any] {
    var payload: [String: Any] = [
        "message": error.message,
        "code": error.code.rawValue,
        "exitCode": error.exitCode.rawValue,
        "requestId": UUID().uuidString
    ]
    if !error.details.isEmpty {
        payload["details"] = error.details
    }
    return ["error": payload]
}

func jsonString(_ payload: Any, pretty: Bool) -> String {
    let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    guard JSONSerialization.isValidJSONObject(payload),
          let data = try? JSONSerialization.data(withJSONObject: payload, options: options),
          let text = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return text
}
