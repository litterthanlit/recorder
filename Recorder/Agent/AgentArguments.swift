import Foundation

/// A problem with a tool call that the agent can fix: a bad argument, a take that isn't
/// there. Its message is what the agent reads.
struct AgentToolError: Error, Equatable, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String {
        message
    }
}

/// A tool's arguments, read with checks whose errors say exactly what's wrong.
struct AgentArguments {
    let values: [String: JSONValue]

    init(_ json: JSONValue) {
        values = json.objectValue ?? [:]
    }

    init(values: [String: JSONValue]) {
        self.values = values
    }

    /// Present and not `null`.
    func has(_ key: String) -> Bool {
        value(key) != nil
    }

    func value(_ key: String) -> JSONValue? {
        guard let value = values[key], !value.isNull else { return nil }
        return value
    }

    func string(_ key: String) throws -> String? {
        guard let value = value(key) else { return nil }
        guard let string = value.stringValue else {
            throw AgentToolError("\(key) must be a string.")
        }
        return string
    }

    func requiredString(_ key: String) throws -> String {
        guard let string = try string(key), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError("\(key) is required.")
        }
        return string
    }

    /// A number (a numeric string is accepted too).
    func double(_ key: String) throws -> Double? {
        guard let value = value(key) else { return nil }
        if let number = value.doubleValue, number.isFinite {
            return number
        }
        if let text = value.stringValue, let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite {
            return number
        }
        throw AgentToolError("\(key) must be a number.")
    }

    func double(_ key: String, in range: ClosedRange<Double>) throws -> Double? {
        guard let number = try double(key) else { return nil }
        guard range.contains(number) else {
            throw AgentToolError("\(key) must be between \(Self.format(range.lowerBound)) and \(Self.format(range.upperBound)) (got \(Self.format(number))).")
        }
        return number
    }

    func int(_ key: String) throws -> Int? {
        guard let number = try double(key) else { return nil }
        guard number.rounded() == number, abs(number) < 1e15 else {
            throw AgentToolError("\(key) must be a whole number.")
        }
        return Int(number)
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = value(key) else { return nil }
        if let flag = value.boolValue {
            return flag
        }
        switch value.stringValue?.lowercased() {
        case "true", "yes", "on":
            return true
        case "false", "no", "off":
            return false
        default:
            throw AgentToolError("\(key) must be true or false.")
        }
    }

    /// Seconds: a number, or a string like "1:23.5", "0:05" or "12.5s".
    func time(_ key: String) throws -> TimeInterval? {
        guard let value = value(key) else { return nil }
        guard let seconds = AgentTime.parse(value) else {
            throw AgentToolError("\(key) must be a time in seconds (like 12.5) or \"m:ss.s\" (like \"1:05.2\").")
        }
        return seconds
    }

    /// One of a fixed set of words.
    func choice<Choice: RawRepresentable & CaseIterable>(_ key: String, _ type: Choice.Type) throws -> Choice? where Choice.RawValue == String {
        guard let text = try string(key) else { return nil }
        let normalized = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "-", with: "_")
        if let match = Choice.allCases.first(where: { $0.rawValue.lowercased() == normalized }) {
            return match
        }
        let options = Choice.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
        throw AgentToolError("\(key) must be one of \(options) (got \"\(text)\").")
    }

    func object(_ key: String) throws -> AgentArguments? {
        guard let value = value(key) else { return nil }
        guard let object = value.objectValue else {
            throw AgentToolError("\(key) must be an object.")
        }
        return AgentArguments(values: object)
    }

    func array(_ key: String) throws -> [JSONValue]? {
        guard let value = value(key) else { return nil }
        guard let array = value.arrayValue else {
            throw AgentToolError("\(key) must be an array.")
        }
        return array
    }

    /// A list of objects (like an `operations` array).
    func objects(_ key: String) throws -> [AgentArguments]? {
        guard let array = try array(key) else { return nil }
        return try array.enumerated().map { index, element in
            guard let object = element.objectValue else {
                throw AgentToolError("\(key)[\(index)] must be an object.")
            }
            return AgentArguments(values: object)
        }
    }

    static func format(_ number: Double) -> String {
        number.rounded() == number && abs(number) < 1e9 ? String(Int(number)) : String(format: "%.3g", number)
    }
}

/// Times as agents write them.
enum AgentTime {
    /// Seconds from a number, or from a string: "83.5", "12.5s", "1:23.5" or "1:02:03".
    static func parse(_ value: JSONValue) -> TimeInterval? {
        if let number = value.doubleValue {
            return number.isFinite ? number : nil
        }
        guard var text = value.stringValue?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else {
            return nil
        }
        if text.hasSuffix("s") {
            text.removeLast()
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        var seconds: Double = 0
        for (index, part) in parts.enumerated() {
            guard let number = Double(part), number.isFinite, number >= 0 else { return nil }
            // Minutes and seconds after the first part stay under 60.
            if index > 0, number >= 60 { return nil }
            seconds = seconds * 60 + number
        }
        return seconds
    }

    /// Rounded to milliseconds, for results.
    static func json(_ seconds: TimeInterval) -> JSONValue {
        .finite((seconds * 1000).rounded() / 1000)
    }
}
