import Foundation

/// Any JSON value: MCP messages, tool arguments and results, whose shape is only known at
/// run time.
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Coding

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            if !value.isFinite {
                // JSON has no NaN or infinity.
                try container.encodeNil()
            } else if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
                // Whole numbers as integers, so a request id of 1 comes back as 1, not 1.0.
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    /// Parses UTF-8 JSON text.
    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Compact JSON on one line (no newlines anywhere, so it can be newline-framed), keys
    /// sorted so the same value always encodes the same way.
    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Every case encodes; finite numbers are checked above.
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    /// `encoded()` plus the newline that ends a message on a stream.
    func line() -> Data {
        var data = encoded()
        data.append(0x0A)
        return data
    }

    /// The value as JSON text, for a tool result's text block.
    var text: String {
        String(decoding: encoded(), as: UTF8.self)
    }

    /// Converts any `Encodable` (a summary struct, say) into a `JSONValue`.
    static func encoding<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }

    /// Decodes this value as `T` (tool arguments into a typed struct, say).
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: encoded())
    }
}

// MARK: - Reading

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case let .object(object) = self {
            return object[key]
        }
        return nil
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    /// A whole number (JSON has no separate integer type).
    var intValue: Int? {
        guard case let .number(value) = self, value.isFinite, value.rounded() == value,
              abs(value) < 9_007_199_254_740_992
        else { return nil }
        return Int(value)
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    var isNull: Bool {
        self == .null
    }

    /// A number, or `null` for NaN and infinity (which JSON can't hold).
    static func finite(_ value: Double) -> JSONValue {
        value.isFinite ? .number(value) : .null
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) {
        self = .number(Double(value))
    }
}

extension JSONValue: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) {
        self = .number(value)
    }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension JSONValue: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
