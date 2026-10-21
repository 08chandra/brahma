import Foundation

/// Agent text is rendered verbatim: no Markdown, no links. Only known `@handles` get emphasis.
public enum MessageText {
    private static let mention = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_])@([A-Za-z0-9_-]+)")

    public static func attributed(_ text: String, handles: Set<String>) -> AttributedString {
        var result = AttributedString(text)  // plain String initializer: never parsed as Markdown
        let known = Set(handles.map { $0.lowercased() }).union(["owner"])
        let ns = text as NSString
        for m in mention.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var handle = ns.substring(with: m.range(at: 1))
            while handle.hasSuffix("-") || handle.hasSuffix("_") { handle.removeLast() }
            guard !handle.isEmpty, known.contains(handle.lowercased()),
                  let full = Range(m.range, in: text) else { continue }
            let start = text.distance(from: text.startIndex, to: full.lowerBound)
            let length = handle.count + 1  // "@" plus the handle without trailing separators (ASCII only)
            let lower = result.characters.index(result.startIndex, offsetBy: start)
            let upper = result.characters.index(lower, offsetBy: length)
            result[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return result
    }
}
