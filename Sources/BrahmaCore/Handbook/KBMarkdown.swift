import Foundation

/// One section of a handbook page: the untitled lead (`top`, level 0) or an ATX heading with its own text up to the next
/// heading of any level. `restrictions` is the page restriction (when set), the marker of every enclosing heading and its
/// own marker: every element must be satisfied to read it (`KBAccess`).
public struct KBSection: Equatable, Sendable {
    /// The heading with its restriction marker stripped; nil for the lead.
    public var heading: String?
    public var level: Int
    public var slug: String
    /// `[restricted]` → `["@executive"]`; `[restricted: a, b]` → those role ids.
    public var marker: Restriction?
    public var restrictions: [Restriction]
    /// Its own text, without the heading line.
    public var text: String

    public init(heading: String?, level: Int, slug: String, marker: Restriction?, restrictions: [Restriction], text: String) {
        self.heading = heading; self.level = level; self.slug = slug; self.marker = marker; self.restrictions = restrictions
        self.text = text
    }
}

/// The handbook's Markdown structure. Only what the engine needs to lock restricted sections in place: ATX headings outside
/// fenced code blocks (```` ``` ```` and `~~~` runs of three or more, closed by the same character at least as long), the
/// `[restricted…]` marker at the end of a heading, and links in `[[Path]]` and `kb:Path` form. Lines indented four spaces
/// or more are neither headings nor fences.
public enum KBMarkdown {
    /// A parsed section and where it sits in the body's lines.
    struct Located {
        var section: KBSection
        /// The heading line's index; nil for the lead.
        var headingLine: Int?
        /// The section's own text lines.
        var textLines: Range<Int>

        /// The heading line and the text, as lines of the body.
        var lineRange: Range<Int> { (headingLine ?? textLines.lowerBound)..<textLines.upperBound }
    }

    public static func sections(_ body: String, page: Restriction?) -> [KBSection] {
        located(body, page: page).map(\.section)
    }

    /// Every `[[Path]]` and `kb:Path` link, normalized, with the slug of the section it sits in (the heading line counts as
    /// the section's). Invalid names are ignored; a path is listed once per section (case-insensitively), in order.
    public static func links(_ body: String) -> [(sectionSlug: String, path: String)] {
        let lines = Self.lines(body)
        var out: [(sectionSlug: String, path: String)] = []
        for loc in located(body, page: nil) {
            let text = lines[loc.lineRange].joined(separator: "\n")
            let ns = text as NSString
            var found: [(location: Int, raw: String)] = []
            for m in wikiLink.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                found.append((m.range.location, ns.substring(with: m.range(at: 1))))
            }
            for m in kbLink.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                found.append((m.range.location, trimTrailingPunctuation(ns.substring(with: m.range(at: 1)))))
            }
            var seen = Set<String>()
            for (_, raw) in found.sorted(by: { $0.location < $1.location }) {
                guard let path = try? HandbookPath.normalize(raw), seen.insert(path.lowercased()).inserted else { continue }
                out.append((loc.section.slug, path))
            }
        }
        return out
    }

    /// `body` with the section `slug`'s own text replaced by `text` (its heading line and every other section kept). A slug
    /// the body does not have leaves it unchanged.
    public static func replacing(section slug: String, in body: String, with text: String) -> String {
        guard let loc = located(body, page: nil).first(where: { $0.section.slug == slug }) else { return body }
        var lines = Self.lines(body)
        lines.replaceSubrange(loc.textLines, with: text.isEmpty ? [] : Self.lines(text))
        return lines.joined(separator: "\n")
    }

    /// Whether `text` can stand as one section's text under a heading of level `belowLevel`: its fences are balanced and no
    /// ATX heading of level `belowLevel` or above (a smaller number) appears outside a fence.
    public static func isSingleSectionText(_ text: String, belowLevel: Int) -> Bool {
        var fence: (char: Character, length: Int)?
        for line in lines(text) {
            if let f = fence {
                if closesFence(line, f) { fence = nil }
                continue
            }
            if let open = opensFence(line) { fence = open; continue }
            if let h = atxHeading(line), h.level <= belowLevel { return false }
        }
        return fence == nil
    }

    /// `"+<added> −<removed> lines"`: the line multiset difference between `old` and `new`.
    public static func diffSummary(old: String, new: String) -> String {
        var counts: [Substring: Int] = [:]
        let oldLines = old.isEmpty ? [] : old.split(separator: "\n", omittingEmptySubsequences: false)
        let newLines = new.isEmpty ? [] : new.split(separator: "\n", omittingEmptySubsequences: false)
        for l in oldLines { counts[l, default: 0] += 1 }
        var added = 0
        for l in newLines {
            if let n = counts[l], n > 0 { counts[l] = n - 1 } else { added += 1 }
        }
        let removed = counts.values.reduce(0, +)
        return "+\(added) −\(removed) lines"
    }

    /// Lowercased, spaces as `-`, only `[a-z0-9-]` kept.
    public static func slug(_ text: String) -> String {
        String(text.lowercased().replacingOccurrences(of: " ", with: "-").filter { ch in
            ch == "-" || (ch.isASCII && (ch.isLetter || ch.isNumber))
        })
    }

    // MARK: Parsing

    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func located(_ body: String, page: Restriction?) -> [Located] {
        let lines = Self.lines(body)
        let base: [Restriction] = page.map { [$0] } ?? []
        var headings: [(line: Int, level: Int, heading: String, marker: Restriction?)] = []
        var fence: (char: Character, length: Int)?
        for (i, line) in lines.enumerated() {
            if let f = fence {
                if closesFence(line, f) { fence = nil }
                continue
            }
            if let open = opensFence(line) { fence = open; continue }
            if let h = atxHeading(line) {
                let (heading, marker) = splitMarker(h.text)
                headings.append((i, h.level, heading, marker))
            }
        }

        var used: Set<String> = ["top"]
        func unique(_ s: String) -> String {
            let root = s.isEmpty ? "section" : s
            var candidate = root, n = 2
            while used.contains(candidate) {
                candidate = "\(root)-\(n)"
                n += 1
            }
            used.insert(candidate)
            return candidate
        }

        let leadEnd = headings.first?.line ?? lines.count
        var out = [Located(section: KBSection(heading: nil, level: 0, slug: "top", marker: nil, restrictions: base,
                                              text: lines[0..<leadEnd].joined(separator: "\n")),
                           headingLine: nil, textLines: 0..<leadEnd)]
        var stack: [(level: Int, marker: Restriction?)] = []
        for (n, h) in headings.enumerated() {
            while let last = stack.last, last.level >= h.level { stack.removeLast() }
            let restrictions = base + stack.compactMap(\.marker) + (h.marker.map { [$0] } ?? [])
            stack.append((h.level, h.marker))
            let end = n + 1 < headings.count ? headings[n + 1].line : lines.count
            let textLines = (h.line + 1)..<end
            out.append(Located(section: KBSection(heading: h.heading, level: h.level, slug: unique(slug(h.heading)),
                                                  marker: h.marker, restrictions: restrictions,
                                                  text: lines[textLines].joined(separator: "\n")),
                               headingLine: h.line, textLines: textLines))
        }
        return out
    }

    /// The line without up to three leading spaces, or nil when it is indented four or more (indented code).
    private static func unindented(_ line: String) -> Substring? {
        var s = Substring(line)
        if s.hasSuffix("\r") { s = s.dropLast() }
        var spaces = 0
        while s.first == " " {
            spaces += 1
            s = s.dropFirst()
        }
        return spaces <= 3 ? s : nil
    }

    private static func opensFence(_ line: String) -> (char: Character, length: Int)? {
        guard let s = unindented(line), let c = s.first, c == "`" || c == "~" else { return nil }
        let run = s.prefix { $0 == c }.count
        return run >= 3 ? (c, run) : nil
    }

    private static func closesFence(_ line: String, _ fence: (char: Character, length: Int)) -> Bool {
        guard let s = unindented(line) else { return false }
        let run = s.prefix { $0 == fence.char }.count
        return run >= fence.length && s.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func atxHeading(_ line: String) -> (level: Int, text: String)? {
        guard let s = unindented(line), s.first == "#" else { return nil }
        let level = s.prefix { $0 == "#" }.count
        guard level <= 6 else { return nil }
        let rest = s.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // An optional closing sequence: spaces, then only `#`s.
        if text.allSatisfy({ $0 == "#" }) {
            text = ""
        } else if let lastSpace = text.lastIndex(where: { $0 == " " || $0 == "\t" }),
                  text[text.index(after: lastSpace)...].allSatisfy({ $0 == "#" }) {
            text = text[..<lastSpace].trimmingCharacters(in: .whitespaces)
        }
        return (level, text)
    }

    /// The heading without a trailing ` [restricted]` / ` [restricted: a, b]` marker, and the marker's roles.
    static func splitMarker(_ heading: String) -> (heading: String, marker: Restriction?) {
        let ns = heading as NSString
        guard let m = marker.firstMatch(in: heading, range: NSRange(location: 0, length: ns.length)) else { return (heading, nil) }
        let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        var roles: Restriction = []
        if m.range(at: 2).location != NSNotFound {
            for part in ns.substring(with: m.range(at: 2)).split(separator: ",") {
                let role = part.trimmingCharacters(in: .whitespaces).lowercased()
                if !role.isEmpty { roles.insert(role) }
            }
        }
        return (name, roles.isEmpty ? ["@executive"] : roles)
    }

    private static let marker = try! NSRegularExpression(pattern: #"^(.*?)(?:^|\s)\[restricted(?:\s*:\s*([^\]]*))?\]$"#,
                                                         options: [.caseInsensitive])
    private static let wikiLink = try! NSRegularExpression(pattern: #"\[\[([^\[\]\n]+?)\]\]"#)
    private static let kbLink = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])kb:([^\s\[\]<>"`|*]+)"#,
                                                         options: [.caseInsensitive])

    private static func trimTrailingPunctuation(_ s: String) -> String {
        var out = s
        while let last = out.last {
            if ".,;:!?".contains(last) {
                out.removeLast()
            } else if last == ")", out.filter({ $0 == ")" }).count > out.filter({ $0 == "(" }).count {
                out.removeLast()
            } else {
                break
            }
        }
        return out
    }
}
