import Foundation

/// The body of the pull request the engine opens for an item (spec §8.5.1 step 4). Every line is the engine's: the sections
/// come in a fixed order — `Summary`, `Acceptance criteria`, `Checks`, `Review`, `Walkthrough`, `Agent notes (untrusted)` —
/// then the `Fixes #n` lines last. Absent data reads `none`; nothing is invented.
///
/// Agent text never stands on a line of its own outside the quoted block:
/// - item fields (title, criteria, check names) are flattened to one line behind an engine prefix (`- Title: `, `- [ ] `, a
///   table cell);
/// - the agent's notes (`ExternalText`) are capped at `notesCap` bytes and every line is quoted with `> `, followed by a blank
///   line so nothing after them is read as part of the quote;
/// - in all of it, `@` and `#` are followed by a word joiner (`neutralizer`, invisible), so no mention, issue reference or
///   closing keyword (`Fixes #9`) and no heading can come from agent text; `&`, `<` and `>` are HTML-escaped (no comment
///   can hide the engine's lines, no tag renders), and format characters (bidi overrides, invisible joiners) are dropped.
/// Deterministic: the same inputs give the same bytes (no clock, no ordering left to a dictionary).
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

    /// At most this many bytes (UTF-8) of the agent's notes are quoted.
    public static let notesCap = 4096
    static let maxCriteria = 50
    static let maxChecks = 30
    /// U+2060 WORD JOINER: invisible, and it breaks `@login`, `#12` and `# heading`.
    public static let neutralizer = "\u{2060}"

    public static func render(item: WorkItem, pack: String, acceptance: [String], checks: [CheckRow], verdict: ReviewVerdict?,
                              walkthroughURL: String?, agentNotes: ExternalText?, fixes: [Int]) -> String {
        var out: [String] = []
        func section(_ heading: String, _ lines: [String]) {
            out += ["## \(heading)", ""] + (lines.isEmpty ? ["none"] : lines) + [""]
        }
        section("Summary", ["- Item: \(inline(item.key, max: 64))", "- Title: \(inline(item.title, max: 200))", "- Pack: \(inline(pack, max: 64))"])

        var criteria = acceptance.prefix(maxCriteria).map { "- [ ] \(inline($0, max: 300))" }
        if acceptance.count > maxCriteria { criteria.append("- (\(acceptance.count - maxCriteria) more not shown)") }
        section("Acceptance criteria", criteria)

        var table: [String] = []
        if !checks.isEmpty {
            table = ["| Check | Status | Duration |", "| --- | --- | --- |"]
            table += checks.prefix(maxChecks).map { "| \(cell($0.name, max: 100)) | \(cell($0.status, max: 40)) | \(duration($0.duration)) |" }
            if checks.count > maxChecks { table += ["", "(\(checks.count - maxChecks) more not shown)"] }
        }
        section("Checks", table)

        var review: [String] = []
        if let verdict {
            review.append("- Verdict: \(verdict.decision == .approve ? "approved" : "changes requested")")
            review.append("- Reviewer role: \(inline(verdict.reviewerRole, max: 64))")
            if let score = verdict.rubricScore, score.isFinite { review.append("- Rubric score: \(String(format: "%.1f", score))") }
        }
        section("Review", review)

        section("Walkthrough", walkthroughURL.flatMap(safeURL).map { [$0] } ?? [])

        var notes: [String] = []
        if let agentNotes {
            let (kept, cut) = capped(agentNotes.text, bytes: notesCap)
            notes = ["Source: \(inline(agentNotes.source, max: 200))", ""] + quoted(kept)
            if cut { notes += ["", "(the notes were cut at \(notesCap / 1024) KiB of \(agentNotes.text.utf8.count) bytes)"] }
        }
        section("Agent notes (untrusted)", notes)

        let numbers = Array(Set(fixes.filter { $0 > 0 })).sorted()
        out += numbers.map { "Fixes #\($0)" }
        if numbers.isEmpty, out.last == "" { out.removeLast() }
        return out.joined(separator: "\n") + "\n"
    }

    /// The PR's title: `<KEY>: <title>`, one line, with no mention or reference in it.
    public static func title(item: WorkItem) -> String {
        neutralize(Store.flat(dropFormat("\(item.key): \(item.title)"), max: 200))
    }

    // MARK: Agent text

    /// One inert line: flattened, format characters dropped, HTML-escaped, mentions and references broken.
    static func inline(_ text: String, max: Int) -> String {
        neutralize(escapeHTML(Store.flat(dropFormat(text), max: max)))
    }

    /// `inline`, with the table's `|` escaped.
    static func cell(_ text: String, max: Int) -> String {
        inline(text, max: max).replacingOccurrences(of: "|", with: "\\|")
    }

    /// Every line quoted with `> ` (an empty one as `>`), escaped and neutralized like `inline` but keeping its line breaks.
    static func quoted(_ text: String) -> [String] {
        var lines = text.components(separatedBy: .newlines)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        if lines.isEmpty { return ["> (empty)"] }
        return lines.map { line in
            let clean = neutralize(escapeHTML(Store.stripControls(dropFormat(line), keepNewlines: false)))
            return clean.isEmpty ? ">" : "> \(clean)"
        }
    }

    /// At most `bytes` UTF-8 bytes of `text`, cut on a character boundary, and whether anything was cut.
    static func capped(_ text: String, bytes: Int) -> (String, Bool) {
        guard text.utf8.count > bytes else { return (text, false) }
        var kept = "", used = 0
        for ch in text {
            let n = String(ch).utf8.count
            if used + n > bytes { break }
            kept.append(ch)
            used += n
        }
        return (kept, true)
    }

    static func dropFormat(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.generalCategory != .format }))
    }

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func neutralize(_ text: String) -> String {
        text.replacingOccurrences(of: "@", with: "@" + neutralizer).replacingOccurrences(of: "#", with: "#" + neutralizer)
    }

    /// An `https://` link with nothing in it that markdown could read as more than a link; anything else is not shown.
    static func safeURL(_ url: String) -> String? {
        url.range(of: "^https://[A-Za-z0-9._~:/?#\\[\\]@!$&'()*+,;=%-]{1,500}$", options: .regularExpression) != nil
            && !url.contains("(") && !url.contains(")") ? url : nil
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }
}
