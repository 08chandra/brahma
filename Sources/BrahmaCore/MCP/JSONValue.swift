import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    var numberValue: Double? { if case .number(let n) = self { n } else { nil } }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
}

extension JSONValue {
    /// A `JSONSerialization` value as a `JSONValue` (anything else is `.null`).
    static func from(_ value: Any?) -> JSONValue {
        switch value {
        case nil: return .null
        case let s as String: return .string(s)
        case let n as NSNumber:
            // `JSONSerialization` gives booleans as NSNumber (objCType "c"); tell them apart without CoreFoundation.
            if String(cString: n.objCType) == "c" { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let o as [String: Any]: return .object(o.mapValues { from($0) })
        case let a as [Any]: return .array(a.map { from($0) })
        default: return .null
        }
    }
}
