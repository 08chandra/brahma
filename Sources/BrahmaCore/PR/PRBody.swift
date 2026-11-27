import Foundation

/// The body of the pull request the engine opens for an item (spec §8.5.1 step 4). The sections come in a fixed order —
/// `Summary`, `Acceptance criteria`, `Checks`, `Review`, `Walkthrough`, `Agent notes (untrusted)` — then the `Fixes #n` lines
/// last. Absent data reads `none`; nothing is invented.
///
/// Agent text never reaches GitHub's parser (Ruling X8-22): GitHub parses no reference, mention, closing keyword, link or image
/// inside code, so
/// - the agent's notes (`ExternalText`) are one fenced code block inside a blockquote (`> `-prefixed lines), the fence longer
///   than any backtick run in the text, the whole rendered block (fence lines and `> ` prefixes included) at most `notesCap`
///   bytes, followed by a blank line;
/// - agent-influenced item fields (title, acceptance criteria, check names, the reviewer role, the notes' source) are flattened
///   to one line and rendered as inline code spans (delimiter longer than any backtick run inside), behind an engine prefix;
/// - format characters (bidi overrides, invisible joiners) and control characters are dropped from all of it.
/// The only lines outside code are the engine's (headings, prefixes, `none`, the table frame, the cut notice, `Fixes #n` from
/// the item's trusted origin). Deterministic: the same inputs give the same bytes.
public enum PRBody {
    /// One row of the `Checks` table, built by the caller from the engine's own check records.
    public struct CheckRow: Equatable, Sendable {
        public var name: String
        /// The engine's status word (`passed`, `failed`, ...).
        public var status: String
        /// Seconds; nil when not recorded.
        public var duration: TimeInterval?

        public init(name: String, status: String, duration: TimeInterval?) { self.name = name; self.status = status; self.duration = duration }
    }

    /// The review that let the item land, as the engine recorded it.
    public struct ReviewVerdict: Equatable, Sendable {
        public var decision: ReviewDecision
        /// The reviewer's role (`qa`, `engineer`, ...), or `engine` for an engine auto-approval.
        public var reviewerRole: String
        /// A rubric score, when the review recorded one.
        public var rubricScore: Double?

        public init(decision: ReviewDecision, reviewerRole: String, rubricScore: Double?) {
            self.decision = decision; self.reviewerRole = reviewerRole; self.rubricScore = rubricScore
        }
    }

    /// One line of the body. `agent`: it carries agent-influenced text (inside code); a card may cut those, never the others.
    public struct Line: Equatable, Sendable {
        public var text: String
        public var agent: Bool
    }

    /// The rendered agent-notes block (the fence lines and every `> ` prefix included) is at most this many UTF-8 bytes.
    public static let notesCap = 4096
    static let maxCriteria = 50
    static let maxChecks = 30
    static let maxFixes = 20
    /// U+2060 WORD JOINER: invisible; it breaks `@login`, `#12`, `GH-12` and `https://` in the PR title (plain text on GitHub).
    public static let neutralizer = "\u{2060}"

    public static func render(item: WorkItem, pack: String, acceptance: [String], checks: [CheckRow], verdict: ReviewVerdict?,
                              walkthroughURL: String?, agentNotes: ExternalText?, fixes: [Int]) -> String {
        lines(item: item, pack: pack, acceptance: acceptance, checks: checks, verdict: verdict, walkthroughURL: walkthroughURL,
              agentNotes: agentNotes, fixes: fixes).map(\.text).joined(separator: "\n") + "\n"
    }

    /// `render`'s lines, each marked engine or agent.
    public static func lines(item: WorkItem, pack: String, acceptance: [String], checks: [CheckRow], verdict: ReviewVerdict?,
                             walkthroughURL: String?, agentNotes: ExternalText?, fixes: [Int]) -> [Line] {
        var out: [Line] = []
        func engine(_ t: String) { out.append(Line(text: t, agent: false)) }
        func agent(_ t: String) { out.append(Line(text: t, agent: true)) }
        func section(_ heading: String, _ body: () -> Bool) {
            engine("## \(heading)"); engine("")
            if !body() { engine("none") }
            engine("")
        }
        section("Summary") {
            engine("- Item: \(code(item.key, max: 64))")
            agent("- Title: \(code(item.title, max: 200))")
            engine("- Pack: \(code(pack, max: 64))")
            return true
        }
        section("Acceptance criteria") {
            for c in acceptance.prefix(maxCriteria) { agent("- [ ] \(code(c, max: 300))") }
            if acceptance.count > maxCriteria { engine("- (\(acceptance.count - maxCriteria) more not shown)") }
            return !acceptance.isEmpty
        }
        section("Checks") {
            guard !checks.isEmpty else { return false }
            engine("| Check | Status | Duration |"); engine("| --- | --- | --- |")
            for c in checks.prefix(maxChecks) { agent("| \(cell(c.name, max: 100)) | \(cell(c.status, max: 40)) | \(duration(c.duration)) |") }
            if checks.count > maxChecks { engine(""); engine("(\(checks.count - maxChecks) more not shown)") }
            return true
        }
        section("Review") {
            guard let verdict else { return false }
            engine("- Verdict: \(verdict.decision == .approve ? "approved" : "changes requested")")
            agent("- Reviewer role: \(code(verdict.reviewerRole, max: 64))")
            if let score = verdict.rubricScore, score.isFinite { engine("- Rubric score: \(String(format: "%.1f", score))") }
            return true
        }
        section("Walkthrough") {
            guard let url = walkthroughURL.flatMap(safeURL) else { return false }
            engine(url)
            return true
        }
        section("Agent notes (untrusted)") {
            guard let agentNotes else { return false }
            agent("Source: \(code(agentNotes.source, max: 200))")
            engine("")
            let (block, cut) = fencedQuote(agentNotes.text, budget: notesCap)
            for line in block { agent(line) }
            if cut {
                engine("")
                engine("(the notes were cut to \(notesCap / 1024) KiB rendered; they had \(agentNotes.text.utf8.count) bytes)")
            }
            return true
        }
        let numbers = Array(Set(fixes.filter { $0 > 0 })).sorted().prefix(maxFixes)
        for n in numbers { engine("Fixes #\(n)") }
        if numbers.isEmpty, out.last?.text == "" { out.removeLast() }
        return out
    }

    /// The PR's title: `<KEY>: <title>`, one line. A PR title is plain text on GitHub (no markdown; closing keywords there close
    /// nothing), but GitHub still links `#n`, `GH-n`, URLs and mentions in it, so those are broken with `neutralizer`.
    public static func title(item: WorkItem) -> String {
        var t = Store.flat(dropFormat("\(item.key): \(item.title)"), max: 200)
        t = t.replacingOccurrences(of: "@", with: "@" + neutralizer).replacingOccurrences(of: "#", with: "#" + neutralizer)
        t = t.replacingOccurrences(of: "://", with: ":" + neutralizer + "//")
        return t.replacingOccurrences(of: "(?i)(gh)-(?=[0-9])", with: "$1" + neutralizer + "-", options: .regularExpression)
    }

    /// What proves a PR's content is the engine's (Ruling 28): SHA-256 of the title and the body after exactly this
    /// normalization of each: `\r\n` and a lone `\r` become `\n`; trailing spaces and tabs (U+0020, U+0009 only) are removed
    /// from every line; trailing `\n`s at the end are removed. Nothing else (no leading whitespace, no Unicode spaces).
    public static func contentDigest(title: String, body: String) -> String {
        func norm(_ s: String) -> String {
            let lines = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n").map { line in
                    var l = Substring(line)
                    while l.last == " " || l.last == "\t" { l = l.dropLast() }
                    return String(l)
                }
            var joined = lines.joined(separator: "\n")
            while joined.hasSuffix("\n") { joined.removeLast() }
            return joined
        }
        return hex(SHA256.hash(Data((norm(title) + "\u{0}" + norm(body)).utf8)))
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    // MARK: Agent text

    /// One line of agent text as an inline code span: flattened, format characters dropped, delimited by more backticks than
    /// any run inside (padded with a space when it starts or ends with one).
    static func code(_ text: String, max: Int) -> String {
        let t = Store.flat(dropFormat(text), max: max)
        if t.isEmpty { return "`(empty)`" }
        let delimiter = String(repeating: "`", count: longestBacktickRun(t) + 1)
        let pad = t.hasPrefix("`") || t.hasSuffix("`") ? " " : ""
        return delimiter + pad + t + pad + delimiter
    }

    /// `code`, with the table's `|` escaped (GFM splits cells on `|` even inside a code span).
    static func cell(_ text: String, max: Int) -> String {
        code(text, max: max).replacingOccurrences(of: "|", with: "\\|")
    }

    /// The agent's text as one fenced code block inside a blockquote, at most `budget` UTF-8 bytes rendered (every line counted
    /// with its `> ` prefix and newline), cut on a character boundary; and whether anything was cut.
    ///
    /// The fence is the shortest one (at least three backticks) that outlasts every backtick run in the text it keeps: the kept
    /// text shrinks as the fence grows (two fence lines take room), so its longest run never grows — the smallest valid fence is
    /// found by bisection, and a fence of `budget / 2 - 3` keeps nothing, so one always exists within the budget.
    static func fencedQuote(_ text: String, budget: Int) -> (lines: [String], cut: Bool) {
        let clean = normalized(text)
        func kept(_ fence: Int) -> (String, Bool) { prefix(clean, bytes: budget - 2 * (2 + fence + 1)) }
        func fits(_ fence: Int) -> Bool { longestBacktickRun(kept(fence).0) < fence }
        var low = 3, high = max(3, budget / 2 - 3)
        if !fits(low) {
            while high - low > 1 {
                let mid = (low + high) / 2
                if fits(mid) { high = mid } else { low = mid }
            }
            low = high
        }
        let (text, cut) = kept(low)
        let f = String(repeating: "`", count: max(3, longestBacktickRun(text) + 1))
        var body = text.isEmpty ? [] : text.components(separatedBy: "\n")
        while body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeLast() }
        return (["> " + f] + body.map { $0.isEmpty ? ">" : "> " + $0 } + ["> " + f], cut)
    }

    /// The longest prefix of `text` whose lines, each rendered as `> <line>\n`, take at most `bytes` bytes.
    static func prefix(_ text: String, bytes: Int) -> (String, Bool) {
        var kept = "", used = 0, lineStart = true
        for ch in text {
            let cost = ch == "\n" ? (lineStart ? 3 : 0) : (lineStart ? 3 : 0) + String(ch).utf8.count
            if used + cost > bytes { return (kept, true) }
            used += cost
            lineStart = ch == "\n"
            kept.append(ch)
        }
        return (kept, false)
    }

    /// Line breaks as `\n`; format and control characters (but `\n` and tabs) dropped.
    static func normalized(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\r\n", with: "\n")
        for sep in ["\r", "\u{2028}", "\u{2029}", "\u{0085}", "\u{000B}", "\u{000C}"] { t = t.replacingOccurrences(of: sep, with: "\n") }
        return Store.stripControls(dropFormat(t), keepNewlines: true)
    }

    static func longestBacktickRun(_ text: String) -> Int {
        var longest = 0, run = 0
        for ch in text {
            if ch == "`" { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        return longest
    }

    static func dropFormat(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.generalCategory != .format }))
    }

    /// An `https://` link with nothing in it that markdown could read as more than a link; anything else is not shown.
    static func safeURL(_ url: String) -> String? {
        url.range(of: "^https://[A-Za-z0-9._~:/?#\\[\\]@!$&'*+,;=%-]{1,500}$", options: .regularExpression) != nil ? url : nil
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }
}
