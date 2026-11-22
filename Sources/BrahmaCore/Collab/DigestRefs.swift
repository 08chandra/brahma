import Foundation

/// Plan C Task C3b: a ref as one engine-written line of an agent's digest, for one reader (`ResolvedRef`). Nothing of the
/// content is pasted: a chip names the ref, its pin and its size; `open_ref` reads it.
/// - full: `[file ENG-142:src/checkout.tsx:40-88 @a1b2c3d · 49 lines · Swift]`, `[artifact AR-4 "Checkout mock" · html]`,
///   `[ask A-31 "Pricing PRD" · pendingOwner]`, `[run:551 · failed exit 1]`, `[resource F-14 · md · tainted]`; other kinds
///   `[<kind> <canonical> · <engine subtitle>]`. Agent-chosen titles are flattened and capped (`SafeTitle`), their double
///   quotes made single, and never shown for tainted content;
/// - locked: `[locked <kind> · ask the owner]`: no title, path, size or canonical;
/// - refused or missing: `""` (the caller leaves it out).
/// A ref the owner gave, forwarded by an agent, says so: `[file the owner gave @A, forwarded by @A (data) · …]`.
public enum DigestRefs {
    /// The last line of a message whose refs are listed.
    public static let footer = "    (open_ref to read; nothing is pasted)"

    /// The header of a message written by a session that read outside content.
    public static func taintedHeader(_ source: String) -> String {
        "[from a session that read external content: \(Store.flat(TaintPolicy.flat(source), max: 120))]"
    }

    /// Whether a digest line is a ref chip (the footer follows chips; a verified quote's text is not one).
    static func isChip(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("[") && !t.hasPrefix("[quote ") && !t.hasPrefix("[locked message")
    }

    public static func line(_ r: ResolvedRef, forwardedBy: String? = nil) -> String {
        switch r.visibility {
        case .locked: return "[locked \(r.ref.kind.rawValue) · ask the owner]"
        case .refused, .missing: return ""
        case .full: break
        }
        let bare = Store.unpinned(r.ref).canonical
        var kind = r.ref.kind.rawValue
        var name = bare
        var parts: [String] = []
        /// The part of the engine's subtitle after its first ` · ` (`"F-14 · md"` → `"md"`).
        func afterFirst(_ s: String) -> String? {
            guard let range = s.range(of: " · ") else { return nil }
            let rest = String(s[range.upperBound...])
            return rest.isEmpty ? nil : rest
        }
        func titled(_ title: String) -> String { " \"" + Store.flat(title, max: SafeTitle.max).replacingOccurrences(of: "\"", with: "'") + "\"" }
        switch r.ref.kind {
        case .file:
            if !r.ref.isWorktree, r.ref.params["share"] == nil, let rev = r.ref.rev { name += " @\(rev.prefix(7))" }
            let total = leadingCount(r.subtitle)
            if let range = r.ref.range {
                let last = total.map { min(range.end, $0) } ?? range.end
                parts.append(Store.lines(max(0, last - range.start + 1)))
            } else if let total {
                parts.append(Store.lines(total))
            }
            parts.append(Store.language(of: r.ref.id))
            if r.ref.isWorktree { parts.append(r.ref.rev == nil ? "uncommitted" : "uncommitted, as shared") }
            if r.state == .tooLarge { parts.append("too large to show") }
        case .diff, .commit:
            if !r.ref.isWorktree, let rev = r.ref.rev { name += " @\(rev.prefix(7))" }
            if !r.subtitle.isEmpty { parts.append(Store.flat(r.subtitle, max: 120)) }
        case .artifact:
            if !r.tainted { name += titled(r.title) }
            if let k = afterFirst(r.subtitle) { parts.append(k) }
        case .ask:
            if !r.tainted {
                let prefix = bare + " "
                name += titled(r.title.hasPrefix(prefix) ? String(r.title.dropFirst(prefix.count)) : r.title)
            }
            if !r.subtitle.isEmpty { parts.append(r.subtitle) }
        case .run:
            kind = ""
            if !r.subtitle.isEmpty { parts.append(r.subtitle.replacingOccurrences(of: " · ", with: " ")) }
        case .resource:
            if !r.tainted { name += titled(r.title) }
            if let k = afterFirst(r.subtitle) { parts.append(k) }
        case .message, .thread:
            // Never the message's text (the subtitle holds it): where it is.
            parts.append(r.title)
        default:
            if !r.subtitle.isEmpty { parts.append(Store.flat(r.subtitle, max: 120)) }
        }
        if r.tainted { parts.append("tainted") }
        switch r.state {
        case .redacted: parts.append("redacted")
        case .purged: parts.append("purged")
        default: break
        }
        let rest = parts.map { " · " + $0 }.joined()
        if r.provenance == .owner, let forwardedBy {
            let word = r.ref.kind == .resource || r.ref.kind == .file ? "file" : r.ref.kind.rawValue
            return "[\(word) the owner gave @\(forwardedBy), forwarded by @\(forwardedBy) (data) · \(name)\(rest)]"
        }
        return "[" + (kind.isEmpty ? "" : kind + " ") + name + rest + "]"
    }

    /// The count an engine subtitle starts with (`"49 lines · …"`, `"1 line · …"`), or nil.
    static func leadingCount(_ subtitle: String) -> Int? {
        let head = subtitle.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard let n = Int(head), subtitle.hasPrefix("\(n) line") else { return nil }
        return n
    }
}
