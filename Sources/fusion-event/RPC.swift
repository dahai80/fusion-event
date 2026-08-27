import Foundation

enum RPCErrorCode: Int {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case internalError = -32603
    case guardBlock = -32010
    case timeout = -32011
    case ruleValidation = -32020
    case sourceDisabled = -32021
}

struct RPCRequest: Codable, Sendable {
    let jsonrpc: String
    let id: RPCId?
    let method: String
    let params: AnyCodable?

    init(method: String, params: AnyCodable? = nil, id: RPCId? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

enum RPCId: Codable, Equatable, Hashable, Sendable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else { throw DecodingError.typeMismatch(RPCId.self, .init(codingPath: decoder.codingPath, debugDescription: "id must be int or string")) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        }
    }
}

struct RPCError: Codable, Sendable {
    let code: Int
    let message: String
    let data: AnyCodable?
    init(code: Int, message: String, data: AnyCodable? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

struct RPCResponse: Codable, Sendable {
    let jsonrpc: String
    let id: RPCId?
    let result: AnyCodable?
    let error: RPCError?
    init(id: RPCId?, result: AnyCodable?, error: RPCError? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }
}

struct RPCNotification: Codable, Sendable {
    let jsonrpc: String
    let method: String
    let params: AnyCodable?
    init(method: String, params: AnyCodable? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

public struct AnyCodable: Codable, @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) { self.value = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.value = NSNull() }
        else if let v = try? c.decode(Bool.self) { self.value = v }
        else if let v = try? c.decode(Int.self) { self.value = v }
        else if let v = try? c.decode(Double.self) { self.value = v }
        else if let v = try? c.decode(String.self) { self.value = v }
        else if let v = try? c.decode([AnyCodable].self) { self.value = v.map { $0.value } }
        else if let v = try? c.decode([String: AnyCodable].self) {
            self.value = v.mapValues { $0.value }
        } else { self.value = NSNull() }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let v as AnyCodable: try c.encode(v)
        case let v as Bool: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as UInt64: try c.encode(v)
        case let v as Int64: try c.encode(v)
        case let v as UInt: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [String: [String: AnyCodable]]: try c.encode(v.mapValues { AnyCodable($0) })
        case let v as [String: AnyCodable]: try c.encode(v)
        case let v as [String: UInt64]: try c.encode(v)
        case let v as [String: Int]: try c.encode(v)
        case let v as [String: String]: try c.encode(v)
        case let v as [String: Bool]: try c.encode(v)
        case let v as [AnyCodable]: try c.encode(v)
        case let v as [Any]: try c.encode(v.map { AnyCodable($0) })
        case let v as [String: Any]: try c.encode(v.mapValues { AnyCodable($0) })
        default:
            try c.encodeNil()
        }
    }
}

enum RPCCodec {
    static func encode<T: Encodable>(_ value: T) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(value)) ?? Data()
    }

    static func decodeRequest(_ data: Data) -> RPCRequest? {
        let dec = JSONDecoder()
        return try? dec.decode(RPCRequest.self, from: data)
    }

    static func decodeAny(_ data: Data) -> AnyCodable? {
        let dec = JSONDecoder()
        return try? dec.decode(AnyCodable.self, from: data)
    }

    static func line(_ data: Data) -> Data {
        var d = data
        if !d.isEmpty && d.last != 0x0A { d.append(0x0A) }
        return d
    }
}
