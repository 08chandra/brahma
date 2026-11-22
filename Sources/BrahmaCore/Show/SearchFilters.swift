import Foundation

/// Plan C Task C4a: what global search covers. `kind:` accepts the raw values and the aliases `msg`, `decision`, `doc`,
/// `page`, `mem` and `rel`.
public enum SearchKind: String, CaseIterable, Codable, Sendable {
    case item, event, ask, message, agent, kb, memory, file, artifact, resource, commit, release, activity, sprint, run, preview

    static let aliases: [String: SearchKind] = ["msg": .message, "decision": .ask, "doc": .kb, "page": .kb, "mem": .memory, "rel": .release]

    /// `kind:<k>`'s value (case-insensitive), or nil.
    public static func parse(_ s: String) -> SearchKind? {
        let k = s.lowercased()
        return SearchKind(rawValue: k) ?? aliases[k]
    }

    /// The Show bar group its hits land in.
    public var group: ShowGroup {
        switch self {
        case .item, .event, .run: .items
        case .ask: .asks
        case .message: .messages
        case .agent: .people
        case .kb: .handbook
        case .memory: .memory
        case .file: .files
        case .artifact, .resource: .artifactsResources
        case .commit: .commits
        case .release: .releases
        case .activity: .activity
        case .sprint: .sprints
        case .preview: .previews
        }
    }
}

/// A time filter, in the owner's time zone.
public struct TimeWindow: Equatable, Sendable, Codable {
    public var start: Date
    public var end: Date
    /// `"THIS WEEK"`.
    public var label: String

    public init(start: Date, end: Date, label: String) { self.start = start; self.end = end; self.label = label }

    public func contains(_ date: Date) -> Bool { date >= start && date <= end }
}

/// The filters typed into the Show bar (plain code, no LLM). See `parse`.
public struct SearchFilters: Equatable, Sendable, Codable {
    public var kinds: Set<SearchKind> = []
    public var window: TimeWindow?
    /// A handle or `"owner"`.
    public var actor: String?
    /// `blocked`, `failing`, `failed`, `pending`, `open`, `done` or `in review`: applies to items, asks, runs and agents.
    public var status: String?
    public var channel: String?

    public init(kinds: Set<SearchKind> = [], window: TimeWindow? = nil, actor: String? = nil, status: String? = nil, channel: String? = nil) {
        self.kinds = kinds; self.window = window; self.actor = actor; self.status = status; self.channel = channel
    }

    static let statusWords: Set<String> = ["blocked", "failing", "failed", "pending", "open", "done"]
    static let statusKinds: Set<SearchKind> = [.item, .agent, .ask, .run]
    public static let maxDays = 365

    public var isEmpty: Bool { kinds.isEmpty && window == nil && actor == nil && status == nil && channel == nil }

    /// `"BLOCKED"`, `"BY @ENG-3"`, `"THIS WEEK"`, `"KIND:COMMIT"`, `"IN #ENG"`, in that order.
    public var chips: [String] {
        var out: [String] = []
        if let status { out.append(status.uppercased()) }
        if let actor { out.append("BY @\(actor.uppercased())") }
        if let window { out.append(window.label) }
        for k in SearchKind.allCases where kinds.contains(k) { out.append("KIND:\(k.rawValue.uppercased())") }
        if let channel { out.append("IN #\(channel.uppercased())") }
        return out
    }

    /// The filters in `stripped`, and the text left over (tokens joined by one space).
    /// - `kind:<k>` (repeatable); `is:<status>` or a bare status word (`blocked|failing|failed|pending|open|done|in review`),
    ///   the first one only; a bare status word that is the whole query also sets `kinds = [item, agent, ask, run]`;
    /// - windows, the first one only: `today`, `yesterday`, `this week` (Monday 00:00 → now), `last week`, `this month`,
    ///   `last <n> days` (1 ≤ n ≤ 365; otherwise left as text), `since <yyyy-mm-dd>`, `this sprint` (needs
    ///   `activeSprintStart`);
    /// - the actor: `by @x`, `from @x`, `@x's` (a bare `@x` is not a filter: it stays the agent "now" view);
    /// - `in:#channel`.
    public static func parse(_ stripped: String, now: Date, tz: TimeZone, activeSprintStart: Date?) -> (rest: String, filters: SearchFilters) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        cal.firstWeekday = 2
        let tokens = stripped.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var f = SearchFilters()
        var rest: [String] = []
        var bareStatus = false
        var i = 0
        func lower(_ k: Int) -> String? { k < tokens.count ? tokens[k].lowercased() : nil }
        while i < tokens.count {
            let t = tokens[i], l = t.lowercased()
            // kind:<k>
            if l.hasPrefix("kind:"), let k = SearchKind.parse(String(l.dropFirst(5))) {
                f.kinds.insert(k); i += 1; continue
            }
            // is:<status>
            if l.hasPrefix("is:"), f.status == nil, let s = statusWord(String(l.dropFirst(3))) {
                f.status = s; i += 1; continue
            }
            // in:#channel
            if l.hasPrefix("in:#"), f.channel == nil, RefGrammar.isChannelName(String(l.dropFirst(4))) {
                f.channel = String(l.dropFirst(4)); i += 1; continue
            }
            // in review / bare status words
            if f.status == nil, l == "in", lower(i + 1) == "review" {
                f.status = "in review"; bareStatus = true; i += 2; continue
            }
            if f.status == nil, statusWords.contains(l) {
                f.status = l; bareStatus = true; i += 1; continue
            }
            // windows
            if f.window == nil, let (window, used) = window(tokens, i, now: now, cal: cal, sprint: activeSprintStart) {
                f.window = window; i += used; continue
            }
            // actor
            if f.actor == nil, l == "by" || l == "from", let next = lower(i + 1), next.hasPrefix("@") {
                if let h = handle(String(next.dropFirst())) { f.actor = h; i += 2; continue }
                // `by @` still being typed: no filter yet, and no text to search.
                if next == "@" { i += 2; continue }
            }
            if f.actor == nil, l.hasPrefix("@"), let base = possessive(l), let h = handle(base) {
                f.actor = h; i += 1; continue
            }
            rest.append(t)
            i += 1
        }
        if bareStatus, rest.isEmpty, f.kinds.isEmpty, f.window == nil, f.actor == nil, f.channel == nil {
            f.kinds = statusKinds
        }
        return (rest.joined(separator: " "), f)
    }

    static func statusWord(_ s: String) -> String? {
        if statusWords.contains(s) { return s }
        return ["review", "inreview", "in-review"].contains(s) ? "in review" : nil
    }

    /// `@x's` (or `@x’s`) → `@x`.
    static func possessive(_ l: String) -> String? {
        for suffix in ["'s", "\u{2019}s"] where l.hasSuffix(suffix) {
            return String(l.dropFirst().dropLast(suffix.count))
        }
        return nil
    }

    static func handle(_ h: String) -> String? { RefGrammar.isHandle(h) ? h : nil }

    /// A window starting at `tokens[i]`, and how many tokens it used.
    static func window(_ tokens: [String], _ i: Int, now: Date, cal: Calendar, sprint: Date?) -> (TimeWindow, Int)? {
        let l = tokens[i].lowercased()
        let next = i + 1 < tokens.count ? tokens[i + 1].lowercased() : nil
        let today = cal.startOfDay(for: now)
        func days(_ n: Int, from d: Date) -> Date { cal.date(byAdding: .day, value: n, to: d) ?? d }
        var weekStart: Date {
            let weekday = cal.component(.weekday, from: now)      // 1 = Sunday
            return days(-((weekday + 5) % 7), from: today)
        }
        switch l {
        case "today": return (TimeWindow(start: today, end: now, label: "TODAY"), 1)
        case "yesterday": return (TimeWindow(start: days(-1, from: today), end: today, label: "YESTERDAY"), 1)
        case "this":
            switch next {
            case "week": return (TimeWindow(start: weekStart, end: now, label: "THIS WEEK"), 2)
            case "month":
                let start = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? today
                return (TimeWindow(start: start, end: now, label: "THIS MONTH"), 2)
            case "sprint":
                guard let sprint else { return nil }
                return (TimeWindow(start: sprint, end: now, label: "THIS SPRINT"), 2)
            default: return nil
            }
        case "last":
            if next == "week" { return (TimeWindow(start: days(-7, from: weekStart), end: weekStart, label: "LAST WEEK"), 2) }
            guard let next, let n = Int(next), next.allSatisfy(\.isASCII), (1...maxDays).contains(n), i + 2 < tokens.count,
                  ["days", "day"].contains(tokens[i + 2].lowercased()) else { return nil }
            return (TimeWindow(start: days(-n, from: now), end: now, label: "LAST \(n) DAYS"), 3)
        case "since":
            guard let next, let start = day(next, cal: cal) else { return nil }
            return (TimeWindow(start: start, end: now, label: "SINCE \(next)"), 2)
        default: return nil
        }
    }

    /// `yyyy-mm-dd` at 00:00 in the calendar's zone, or nil (a day that does not exist included).
    static func day(_ s: String, cal: Calendar) -> Date? {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              let date = cal.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
        let back = cal.dateComponents([.year, .month, .day], from: date)
        guard back.year == y, back.month == m, back.day == d else { return nil }
        return date
    }
}

/// The Show bar's query text (design §2.2 step 1).
public enum ShowQuery {
    public static let maxQuery = 300
    public static let filler = ["show me", "show", "open", "find", "search", "search for", "let me see", "can i see", "the", "a", "please",
                                "on", "for", "of"]

    /// `normalized`: NFC, control, bidi and zero-width characters stripped (a tab or newline becomes a space), whitespace
    /// collapsed, at most `maxQuery` characters. `stripped`: that without trailing `?` and without filler (whole words,
    /// case-insensitive, the longest phrase first).
    public static func normalize(_ q: String) -> (normalized: String, stripped: String) {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in q.unicodeScalars {
            let v = scalar.value
            if scalar.properties.isWhitespace || v == 0x0A || v == 0x09 || v == 0x0D { pendingSpace = true; continue }
            if RefText.isHidden(v) || scalar.properties.generalCategory == .format || v == 0x00AD { continue }
            if pendingSpace, !scalars.isEmpty { scalars.append(" ") }
            pendingSpace = false
            scalars.append(scalar)
        }
        var normalized = String(scalars).precomposedStringWithCanonicalMapping
        if normalized.count > maxQuery { normalized = String(normalized.prefix(maxQuery)) }
        normalized = normalized.trimmingCharacters(in: .whitespaces)

        var text = normalized
        while text.hasSuffix("?") || text.hasSuffix(" ") { text.removeLast() }
        let words = text.split(separator: " ").map(String.init)
        let phrases = filler.map { $0.split(separator: " ").map(String.init) }.sorted { $0.count > $1.count }
        var kept: [String] = []
        var i = 0
        outer: while i < words.count {
            for phrase in phrases where i + phrase.count <= words.count {
                if zip(phrase, words[i..<(i + phrase.count)]).allSatisfy({ $0 == $1.lowercased() }) {
                    i += phrase.count
                    continue outer
                }
            }
            kept.append(words[i])
            i += 1
        }
        return (normalized, kept.joined(separator: " "))
    }
}
