import GatewaySDKKit

enum GmailGatewayGraphQLEnvelopeSerializer {
    static func canonicalize(_ envelope: GatewayEnvelope) -> GatewayEnvelope {
        var result = envelope
        if let rawOutput = try? value(for: envelope).jsonString() {
            result.rawOutput = rawOutput + "\n"
        }
        return result
    }

    static func output(_ envelope: GatewayEnvelope, pretty: Bool) throws -> String {
        let canonical = canonicalize(envelope)
        guard pretty else { return canonical.rawOutput }
        return try GatewayJSONValue.parse(canonical.rawOutput).jsonString(pretty: true) + "\n"
    }

    private static func value(for envelope: GatewayEnvelope) -> GatewayJSONValue {
        let errors = envelope.errors.map { error -> GatewayJSONValue in
            var value: [String: GatewayJSONValue] = ["message": .string(error.message)]
            if let code = error.code { value["code"] = .string(code) }
            if let path = error.path { value["path"] = .array(path.map(GatewayJSONValue.string)) }
            return .object(value)
        }
        var body: [String: GatewayJSONValue] = [
            "data": envelope.data ?? .null,
            "errors": .array(errors)
        ]
        if let requestId = envelope.requestId {
            body["extensions"] = .object(["requestId": .string(requestId)])
        }
        return .object(body)
    }
}
