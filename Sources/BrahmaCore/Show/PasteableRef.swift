import Foundation

/// Plan C Task C4a fix round 4 (R4-4, Ruling 58 (3)): a ref as the `search` tool prints it on its own `    ref: ` line, one
/// JSON string literal an agent pastes into `open_ref` as is. Inside the quotes only printable ASCII other than `"`, `\`,
/// `[` and `]` stays itself; every other character (`"`, `\`, `[`, `]`, `·`, controls, anything non-ASCII) is a `\uXXXX`
/// escape. So nothing a path or a page name holds can close the line's quotes, open a bracket or print a `·`: no
/// hit-shaped segment can be forged on the line, and the literal still decodes to the exact ref.
public enum PasteableRef {
    /// The literal of `raw`, or nil when it would be longer than `RefGrammar.maxLength` (the line is then left out).
    public static func literal(_ raw: String) -> String? {
        var out = "\""
        for unit in raw.utf16 {
            switch unit {
            case 0x20...0x7E where unit != 0x22 && unit != 0x5C && unit != 0x5B && unit != 0x5D:
                out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            default:
                out += "\\u" + String(format: "%04X", Int(unit))
            }
            guard out.count < RefGrammar.maxLength else { return nil }
        }
        out += "\""
        return out.count <= RefGrammar.maxLength ? out : nil
    }

    /// The ref a literal names (`open_ref` takes either form), or nil when `s`, trimmed, is not exactly one JSON string
    /// literal of at most `RefGrammar.maxLength` characters.
    public static func decode(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.count <= RefGrammar.maxLength, t.hasPrefix("\""), t.hasSuffix("\"") else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data(t.utf8))
    }
}
