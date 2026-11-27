import Foundation

/// A JSON value parsed strictly, for request bodies the gateway checks and re-sends (Plan X1 Ruling X1-35, Ruling 46).
///
/// Parsers disagree on bodies that repeat a key: one takes the first value, another the last, another merges. If the policy
/// read one value and the provider another, a body could pass as a client tool and reach the provider as a server tool. So
/// this parser refuses a key that appears twice in any object, at any depth, comparing keys after unescaping (`"type"` is
/// `type`), and the gateway never forwards the bytes it received: the provider gets `serialized()` of the tree the policy
/// checked. That serialization keeps each object's keys in the order received, writes every number with exactly the digits
/// received (no `Double` round trip: `9223372036854775809` and long decimals survive), re-escapes strings, and adds no
/// whitespace. Parsing and serializing are linear in the body (Ruling X1-36: the path of the current value is a stack of
/// components, rendered to text only when a refusal needs it, at most `maxPathLength` characters); nesting deeper than
/// `maxDepth` containers is refused. The server refuses a body over `GatewayLimits.maxBodyBytes` (32 MiB) on its
/// `Content-Length`, before reading it, so no larger body ever reaches the parser.
public indirect enum StrictJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    /// The number exactly as received (validated against the JSON grammar).
    case number(String)
    case string(String)
    case array([StrictJSON])
    /// Members in the order received; keys unique.
    case object([Member])

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: StrictJSON
        public init(_ key: String, _ value: StrictJSON) { self.key = key; self.value = value }
    }

    /// The most containers (objects and arrays) one value may be nested in, the outermost included.
    public static let maxDepth = 64
    /// The longest path a refusal shows; a longer one keeps its end, after an ellipsis.
    public static let maxPathLength = 256

    /// How much work a parse did (Ruling 47's deterministic seam: a test proves growth is linear by counting, not timing).
    struct Work: Equatable {
        /// Values and keys parsed.
        var steps = 0
        /// Paths rendered to text (only for a refusal).
        var pathRenders = 0
    }

    /// Why a body was refused: malformed JSON, or a repeated key (with its path, e.g. `messages[0].content[1].type`).
    public enum Failure: Error, Equatable, Sendable {
        case malformed
        case tooDeep
        case duplicateKey(path: String)
    }

    // MARK: Access

    public subscript(key: String) -> StrictJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }

    public var members: [Member]? { if case .object(let m) = self { m } else { nil } }

    /// A copy with the member `key` set (replaced in place, or appended) — objects only.
    public func setting(_ key: String, to value: StrictJSON) -> StrictJSON {
        guard case .object(var members) = self else { return self }
        if let i = members.firstIndex(where: { $0.key == key }) { members[i].value = value } else { members.append(Member(key, value)) }
        return .object(members)
    }

    /// A copy without the member `key` — objects only.
    public func removing(_ key: String) -> StrictJSON {
        guard case .object(let members) = self else { return self }
        return .object(members.filter { $0.key != key })
    }

    // MARK: Parsing

    public static func parse(_ data: Data) throws(Failure) -> StrictJSON {
        var work = Work()
        return try parse(data, work: &work)
    }

    /// `parse(_:)`, counting its work into `work`.
    static func parse(_ data: Data, work: inout Work) throws(Failure) -> StrictJSON {
        var parser = Parser(bytes: [UInt8](data))
        defer { work = parser.work }
        parser.skipSpace()
        let value = try parser.value(depth: 0)
        parser.skipSpace()
        guard parser.i == parser.bytes.count else { throw .malformed }
        return value
    }

    /// One step of the path to the value being parsed.
    private enum PathComponent {
        case key(String)
        case index(Int)
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        /// The path to the value being parsed, as components; rendered only for a refusal.
        var path: [PathComponent] = []
        var work = Work()

        init(bytes: [UInt8]) { self.bytes = bytes }

        /// The current path as text (`messages[0].content[1].type`), at most `maxPathLength` characters, keeping the end.
        mutating func renderedPath() -> String {
            work.pathRenders += 1
            var text = ""
            for component in path {
                switch component {
                case .key(let key): text += (text.isEmpty ? "" : ".") + StrictJSON.shown(key)
                case .index(let n): text += "[\(n)]"
                }
            }
            guard text.count > StrictJSON.maxPathLength else { return text }
            return "…" + text.suffix(StrictJSON.maxPathLength - 1)
        }

        mutating func skipSpace() {
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0a || bytes[i] == 0x0d { i += 1 }
        }

        mutating func expect(_ literal: String) throws(Failure) {
            let l = Array(literal.utf8)
            guard i + l.count <= bytes.count, Array(bytes[i..<(i + l.count)]) == l else { throw .malformed }
            i += l.count
        }

        /// The value at `i`; `depth` is the number of containers it is inside.
        mutating func value(depth: Int) throws(Failure) -> StrictJSON {
            work.steps += 1
            guard i < bytes.count else { throw .malformed }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                guard depth < StrictJSON.maxDepth else { throw .tooDeep }
                return try object(depth: depth + 1)
            case UInt8(ascii: "["):
                guard depth < StrictJSON.maxDepth else { throw .tooDeep }
                return try array(depth: depth + 1)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func object(depth: Int) throws(Failure) -> StrictJSON {
            i += 1
            skipSpace()
            var members: [Member] = []
            var seen: Set<String> = []
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object([]) }
            while true {
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw .malformed }
                work.steps += 1
                let key = try string()
                path.append(.key(key))
                guard seen.insert(key).inserted else { throw .duplicateKey(path: renderedPath()) }
                skipSpace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw .malformed }
                i += 1
                skipSpace()
                members.append(Member(key, try value(depth: depth)))
                path.removeLast()
                skipSpace()
                guard i < bytes.count else { throw .malformed }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                guard bytes[i] == UInt8(ascii: ",") else { throw .malformed }
                i += 1
                skipSpace()
            }
        }

        mutating func array(depth: Int) throws(Failure) -> StrictJSON {
            i += 1
            skipSpace()
            var items: [StrictJSON] = []
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array([]) }
            while true {
                path.append(.index(items.count))
                items.append(try value(depth: depth))
                path.removeLast()
                skipSpace()
                guard i < bytes.count else { throw .malformed }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                guard bytes[i] == UInt8(ascii: ",") else { throw .malformed }
                i += 1
                skipSpace()
            }
        }

        /// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`, returned as received.
        mutating func number() throws(Failure) -> String {
            let start = i
            func digits() -> Int {
                let from = i
                while i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) { i += 1 }
                return i - from
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard i < bytes.count else { throw .malformed }
            if bytes[i] == UInt8(ascii: "0") { i += 1 } else { guard digits() > 0 else { throw .malformed } }
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
                i += 1
                guard digits() > 0 else { throw .malformed }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                guard digits() > 0 else { throw .malformed }
            }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }

        /// A string literal at `i` (the opening quote), unescaped; refuses control characters, bad escapes, lone surrogates
        /// and invalid UTF-8.
        mutating func string() throws(Failure) -> String {
            i += 1
            var out: [UInt8] = []
            while true {
                guard i < bytes.count else { throw .malformed }
                let b = bytes[i]
                if b == UInt8(ascii: "\"") { i += 1; break }
                guard b >= 0x20 else { throw .malformed }
                guard b == UInt8(ascii: "\\") else { out.append(b); i += 1; continue }
                guard i + 1 < bytes.count else { throw .malformed }
                let e = bytes[i + 1]
                i += 2
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5c)
                case UInt8(ascii: "/"): out.append(0x2f)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0c)
                case UInt8(ascii: "n"): out.append(0x0a)
                case UInt8(ascii: "r"): out.append(0x0d)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        guard i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") else { throw .malformed }
                        i += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw .malformed }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(scalar) {
                        throw .malformed
                    }
                    guard let u = Unicode.Scalar(scalar) else { throw .malformed }
                    out.append(contentsOf: Array(String(Character(u)).utf8))
                default:
                    throw .malformed
                }
            }
            guard let s = String(bytes: out, encoding: .utf8) else { throw .malformed }
            return s
        }

        mutating func hex4() throws(Failure) -> UInt32 {
            guard i + 4 <= bytes.count else { throw .malformed }
            var v: UInt32 = 0
            for b in bytes[i..<(i + 4)] {
                let d: UInt32
                switch b {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt32(b - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt32(b - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): d = UInt32(b - UInt8(ascii: "A") + 10)
                default: throw .malformed
                }
                v = v << 4 | d
            }
            i += 4
            return v
        }
    }

    /// A key as a refusal path shows it: short and plain, else `?`.
    static func shown(_ key: String) -> String {
        let plain = !key.isEmpty && key.utf8.count <= 64 && key.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
        return plain ? key : "?"
    }

    // MARK: Serializing

    /// Compact JSON: keys in the order held, numbers as received, strings re-escaped.
    public func serialized() -> Data {
        var out: [UInt8] = []
        write(into: &out)
        return Data(out)
    }

    private func write(into out: inout [UInt8]) {
        switch self {
        case .null: out.append(contentsOf: Array("null".utf8))
        case .bool(let b): out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case .number(let n): out.append(contentsOf: Array(n.utf8))
        case .string(let s): Self.writeString(s, into: &out)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (n, item) in items.enumerated() {
                if n > 0 { out.append(UInt8(ascii: ",")) }
                item.write(into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let members):
            out.append(UInt8(ascii: "{"))
            for (n, member) in members.enumerated() {
                if n > 0 { out.append(UInt8(ascii: ",")) }
                Self.writeString(member.key, into: &out)
                out.append(UInt8(ascii: ":"))
                member.value.write(into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for b in s.utf8 {
            switch b {
            case 0x22: out.append(contentsOf: [0x5c, 0x22])
            case 0x5c: out.append(contentsOf: [0x5c, 0x5c])
            case 0x0a: out.append(contentsOf: [0x5c, UInt8(ascii: "n")])
            case 0x0d: out.append(contentsOf: [0x5c, UInt8(ascii: "r")])
            case 0x09: out.append(contentsOf: [0x5c, UInt8(ascii: "t")])
            case 0..<0x20: out.append(contentsOf: Array(String(format: "\\u%04x", b).utf8))
            default: out.append(b)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}
