import Foundation

/// A tool the server offers (MCP `tools/list`).
struct MCPTool {
    /// Hints for clients; all default to the cautious side.
    struct Annotations: Equatable {
        var readOnly = false
        var destructive = false
        var idempotent = false
        var openWorld = false
    }

    let name: String
    let title: String
    let description: String
    let inputSchema: JSONValue
    var annotations = Annotations()

    var json: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(annotations.readOnly),
                "destructiveHint": .bool(annotations.destructive),
                "idempotentHint": .bool(annotations.idempotent),
                "openWorldHint": .bool(annotations.openWorld)
            ]
        ]
    }
}

/// A prompt template the user can pick (MCP `prompts/list` and `prompts/get`).
struct MCPPrompt {
    struct Argument {
        let name: String
        let description: String
        var required = false
    }

    let name: String
    let title: String
    let description: String
    let arguments: [Argument]
    /// The user message for the given arguments (missing optional ones are absent).
    let text: ([String: String]) -> String

    var json: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "arguments": .array(arguments.map { argument -> JSONValue in
                [
                    "name": .string(argument.name),
                    "description": .string(argument.description),
                    "required": .bool(argument.required)
                ]
            })
        ]
    }

    func messages(for arguments: [String: String]) -> JSONValue {
        [
            "description": .string(description),
            "messages": [
                ["role": "user", "content": ["type": "text", "text": .string(text(arguments))]]
            ]
        ]
    }
}

/// Builders for the JSON Schemas (2020-12) that describe tool arguments. Small functions
/// rather than one big literal, which keeps the type checker fast.
enum Schema {
    static func object(
        _ properties: [(String, JSONValue)],
        required: [String] = [],
        description: String? = nil
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": "object",
            "properties": .object(Dictionary(properties, uniquingKeysWith: { _, last in last }))
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        if let description {
            schema["description"] = .string(description)
        }
        return .object(schema)
    }

    /// An object that takes no arguments.
    static let empty: JSONValue = ["type": "object", "properties": [:], "additionalProperties": false]

    static func string(_ description: String, oneOf values: [String]? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let values {
            schema["enum"] = .array(values.map { .string($0) })
        }
        return .object(schema)
    }

    static func number(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "number", "description": .string(description)]
        if let minimum {
            schema["minimum"] = .number(minimum)
        }
        if let maximum {
            schema["maximum"] = .number(maximum)
        }
        return .object(schema)
    }

    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "integer", "description": .string(description)]
        if let minimum {
            schema["minimum"] = .number(Double(minimum))
        }
        if let maximum {
            schema["maximum"] = .number(Double(maximum))
        }
        return .object(schema)
    }

    static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }

    static func array(of items: JSONValue, _ description: String, maxItems: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "array", "items": items, "description": .string(description)]
        if let maxItems {
            schema["maxItems"] = .number(Double(maxItems))
        }
        return .object(schema)
    }

    /// A time: seconds as a number, or a "m:ss.s" string.
    static func time(_ description: String) -> JSONValue {
        ["type": ["number", "string"], "description": .string(description + " Seconds, or \"m:ss.s\".")]
    }
}

/// Builders for `tools/call` results (MCP `CallToolResult`).
enum MCPToolResult {
    /// Plain text.
    static func text(_ text: String, isError: Bool = false) -> JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }

    /// A failure the agent can act on (a bad argument, a take that isn't there).
    static func error(_ message: String) -> JSONValue {
        text(message, isError: true)
    }

    /// Structured data, also serialized into a text block for clients that only read text,
    /// with an optional one-line summary first.
    static func structured(_ value: JSONValue, summary: String? = nil, images: [(data: Data, mimeType: String)] = []) -> JSONValue {
        var content: [JSONValue] = []
        if let summary {
            content.append(["type": "text", "text": .string(summary)])
        }
        content.append(["type": "text", "text": .string(value.text)])
        for image in images {
            content.append(["type": "image", "data": .string(image.data.base64EncodedString()), "mimeType": .string(image.mimeType)])
        }
        return ["content": .array(content), "structuredContent": value, "isError": false]
    }

    /// Whether a result (as the bridge returned it) reports a failure.
    static func isError(_ result: JSONValue) -> Bool {
        result["isError"]?.boolValue ?? false
    }
}
