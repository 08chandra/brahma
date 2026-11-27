import Foundation

/// Completion for the composer. The active token is a trailing `@handle` (mentions), `#channel`, or a ref prefix (`A-`, `AR-`,
/// `F-`, or a path with a `/`) that starts the text or follows whitespace. Plan C adds `#`, paths and the `A-`/`AR-`/`F-` numbers
/// from the Show indices (the caller passes the candidates; nothing here reads the store).
public enum MentionCompleter {
    private static let tail = try! NSRegularExpression(pattern: "(?:^|\\s)@([A-Za-z0-9_-]*)\\z")
    private static let channelTail = try! NSRegularExpression(pattern: "(?:^|\\s)#([A-Za-z0-9_-]*)\\z")
    private static let refTail = try! NSRegularExpression(pattern: "(?:^|\\s)((?:AR|A|F)-[0-9]*|[A-Za-z0-9_.-]*/[A-Za-z0-9_./-]*)\\z")

    public enum Token: Equatable, Sendable {
        case mention(String)
        case channel(String)
        /// `A-`, `AR-`, `F-` with the digits typed so far, or a path fragment.
        case ref(String)
    }

    /// The characters typed after the trailing `@`, or nil when the cursor is not in a mention.
    public static func activePrefix(in text: String) -> String? {
        let ns = text as NSString
        guard let m = tail.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// The token under the cursor: a mention, a channel or a ref prefix.
    public static func activeToken(in text: String) -> Token? {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let m = tail.firstMatch(in: text, range: range) { return .mention(ns.substring(with: m.range(at: 1))) }
        if let m = channelTail.firstMatch(in: text, range: range) { return .channel(ns.substring(with: m.range(at: 1))) }
        if let m = refTail.firstMatch(in: text, range: range) {
            let t = ns.substring(with: m.range(at: 1))
            if !t.isEmpty { return .ref(t) }
        }
        return nil
    }

    public static func suggestions(for text: String, handles: [String], limit: Int = 8) -> [String] {
        guard let prefix = activePrefix(in: text)?.lowercased() else { return [] }
        return Array(handles.filter { $0.lowercased().hasPrefix(prefix) }.sorted().prefix(limit))
    }

    /// Suggestions for any token: handles for `@`, channel names for `#`, and for a ref prefix the matching `refs` (`A-7`, `AR-4`,
    /// `F-12`, paths) the caller offers from the Show indices.
    public static func suggestions(for text: String, handles: [String], channels: [String], refs: [String], limit: Int = 8) -> [String] {
        switch activeToken(in: text) {
        case .mention(let p)?:
            return Array(handles.filter { $0.lowercased().hasPrefix(p.lowercased()) }.sorted().prefix(limit))
        case .channel(let p)?:
            return Array(channels.filter { $0.lowercased().hasPrefix(p.lowercased()) }.sorted().prefix(limit))
        case .ref(let p)?:
            let lower = p.lowercased()
            return Array(refs.filter { $0.lowercased().hasPrefix(lower) || $0.lowercased().contains(lower) }.sorted().prefix(limit))
        case nil:
            return []
        }
    }

    public static func complete(_ text: String, with handle: String) -> String {
        guard let prefix = activePrefix(in: text) else { return text }
        return String(text.dropLast(prefix.count + 1)) + "@" + handle + " "
    }

    /// Replaces the active token with `value` (`@h`, `#ch`, or a ref as it is) and a space.
    public static func complete(_ text: String, token value: String) -> String {
        switch activeToken(in: text) {
        case .mention(let p)?: return String(text.dropLast(p.count + 1)) + "@" + value + " "
        case .channel(let p)?: return String(text.dropLast(p.count + 1)) + "#" + value + " "
        case .ref(let p)?: return String(text.dropLast(p.count)) + value + " "
        case nil: return text
        }
    }
}
