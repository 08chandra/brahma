import Foundation

/// `@handle` completion for the composer. The active token is a trailing `@[A-Za-z0-9_-]*` that starts the text or follows whitespace.
public enum MentionCompleter {
    private static let tail = try! NSRegularExpression(pattern: "(?:^|\\s)@([A-Za-z0-9_-]*)\\z")

    /// The characters typed after the trailing `@`, or nil when the cursor is not in a mention.
    public static func activePrefix(in text: String) -> String? {
        let ns = text as NSString
        guard let m = tail.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    public static func suggestions(for text: String, handles: [String], limit: Int = 8) -> [String] {
        guard let prefix = activePrefix(in: text)?.lowercased() else { return [] }
        return Array(handles.filter { $0.lowercased().hasPrefix(prefix) }.sorted().prefix(limit))
    }

    public static func complete(_ text: String, with handle: String) -> String {
        guard let prefix = activePrefix(in: text) else { return text }
        return String(text.dropLast(prefix.count + 1)) + "@" + handle + " "
    }
}
