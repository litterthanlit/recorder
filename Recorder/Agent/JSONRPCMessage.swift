import Foundation

/// A JSON-RPC request id: an integer or a string (MCP never allows `null`).
enum JSONRPCID: Hashable {
    case number(Int)
    case string(String)

    init?(_ value: JSONValue) {
        if let number = value.intValue {
            self = .number(number)
        } else if let string = value.stringValue {
            self = .string(string)
        } else {
            return nil
        }
    }

    var json: JSONValue {
        switch self {
        case let .number(value): return .number(Double(value))
        case let .string(value): return .string(value)
        }
    }
}

/// One message read from a client, classified.
enum JSONRPCIncoming: Equatable {
    case request(id: JSONRPCID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    /// A response to something we sent (we never send requests, so it's ignored).
    case response
    /// Not a valid message; answered with an error when it had a usable id.
    case invalid(id: JSONRPCID?, code: Int, message: String)

    static func parse(_ data: Data) -> JSONRPCIncoming {
        guard let value = try? JSONValue.parse(data) else {
            return .invalid(id: nil, code: JSONRPC.parseError, message: "Parse error: not valid JSON")
        }
        return classify(value)
    }

    static func classify(_ value: JSONValue) -> JSONRPCIncoming {
        guard case let .object(object) = value else {
            let message = value.arrayValue != nil
                ? "Batched requests aren't supported"
                : "Invalid request: expected a JSON object"
            return .invalid(id: nil, code: JSONRPC.invalidRequest, message: message)
        }
        if let version = object["jsonrpc"], version != .string("2.0") {
            return .invalid(id: object["id"].flatMap(JSONRPCID.init), code: JSONRPC.invalidRequest, message: "Invalid request: jsonrpc must be \"2.0\"")
        }
        guard let method = object["method"]?.stringValue else {
            if object["result"] != nil || object["error"] != nil {
                return .response
            }
            return .invalid(id: object["id"].flatMap(JSONRPCID.init), code: JSONRPC.invalidRequest, message: "Invalid request: missing method")
        }
        let params = object["params"]
        if let params, params.objectValue == nil {
            return .invalid(id: object["id"].flatMap(JSONRPCID.init), code: JSONRPC.invalidRequest, message: "Invalid request: params must be an object")
        }
        guard let rawID = object["id"] else {
            return .notification(method: method, params: params)
        }
        guard let id = JSONRPCID(rawID) else {
            return .invalid(id: nil, code: JSONRPC.invalidRequest, message: "Invalid request: id must be a string or an integer")
        }
        return .request(id: id, method: method, params: params)
    }
}

/// Builders and error codes for the messages a server sends.
enum JSONRPC {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    /// MCP 2026-07-28: the request's protocol version isn't supported.
    static let unsupportedProtocolVersion = -32022

    static func result(id: JSONRPCID, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id.json, "result": result]
    }

    static func error(id: JSONRPCID?, code: Int, message: String, data: JSONValue? = nil) -> JSONValue {
        var error: [String: JSONValue] = ["code": .number(Double(code)), "message": .string(message)]
        if let data {
            error["data"] = data
        }
        return ["jsonrpc": "2.0", "id": id?.json ?? .null, "error": .object(error)]
    }

    static func notification(method: String, params: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "method": .string(method), "params": params]
    }
}
