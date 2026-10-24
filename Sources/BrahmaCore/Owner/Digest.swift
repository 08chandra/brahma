import Foundation
import GRDB

/// Escapes agent-written text for one line of the owner's markdown digest: control characters and newlines become
/// spaces, markup characters are backslash-escaped, and the result is capped. The digest is rendered by the app with
/// `SafeMarkdown`; this keeps agent text from forming links, headings, tables or emphasis in any markdown viewer.
public enum MarkdownEscape {
    public static let defaultLimit = 160
    private static let special: Set<Character> = ["\\", "`", "*", "_", "[", "]", "<", ">", "#", "|", "~", "!"]
    private static let blocked = CharacterSet.newlines.union(.controlCharacters)

    public static func inline(_ text: String, limit: Int = defaultLimit) -> String {
        let flat = String(String.UnicodeScalarView(text.unicodeScalars.map { blocked.contains($0) ? " " : $0 }))
        var collapsed = ""
        var lastSpace = false
        for ch in flat.trimmingCharacters(in: .whitespaces) {
            if ch == " " { if !lastSpace { collapsed.append(ch) }; lastSpace = true } else { collapsed.append(ch); lastSpace = false }
        }
        let capped = collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
        var out = ""
        for ch in capped {
            if special.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}

/// The owner's daily digest: what needs them, what moved, what the week cost. Built by plain code from the database,
/// never by an agent.
public struct Digest: Equatable, Sendable {
    public struct NeedsGroup: Equatable, Sendable {
        public var title: String
        /// Already escaped, one line per ask.
        public var lines: [String]
        public var count: Int
    }

    public var companyName: String
    public var date: Date
    public var timeZone: TimeZone
    public var periodStart: Date
    public var periodEnd: Date
    public var needsYou: [NeedsGroup] = []
    public var doneCount = 0
    public var doneKeys: [String] = []
    public var inProgress = 0
    public var awaitingReview = 0
    public var blocked = 0
    public var blockedReasons: [String] = []
    public var untouchedCount = 0
    public var untouchedKeys: [String] = []
    public var quietTeams: [String] = []
    /// Turns that started since `periodStart`; only used to tell an empty day from a busy one.
    public var periodTurns = 0
    /// Since Monday 00:00 in the owner's zone.
    public var weekTurns = 0
    public var weekTokens = 0
    public var weekCostUSD = 0.0
    public var sevenDayUtilization: Double?
    public var paceText: String?
    /// Share of the week's list-equivalent cost per mode, in `WorkMode.allCases` order. Nil when nothing was costed.
    public var modeSplit: [(mode: WorkMode, percent: Int)]?
    public var ultraLines: [String] = []

    public var needsYouCount: Int { needsYou.reduce(0) { $0 + $1.count } }

    public var isEmpty: Bool {
        needsYou.isEmpty && doneCount == 0 && inProgress == 0 && awaitingReview == 0 && blocked == 0 && untouchedCount == 0
            && quietTeams.isEmpty && periodTurns == 0
    }

    public var notificationBody: String {
        "\(needsYouCount) need you · \(doneCount) done · \(weekTurns) turns this week"
    }

    public static func == (a: Digest, b: Digest) -> Bool { a.markdown == b.markdown }

    private func format(_ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }

    public var markdown: String {
        var out = ["# \(MarkdownEscape.inline(companyName, limit: 80)) — \(format("EEE d MMM"))", ""]
        if needsYou.isEmpty {
            out += ["Nothing waiting on you.", ""]
        } else {
            out += ["## Needs you", ""]
            for g in needsYou {
                out.append("- **\(g.title)** (\(g.count))")
                out += g.lines.map { "  - \($0)" }
            }
            out.append("")
        }
        out += ["## Progress", ""]
        out.append("- Done: \(doneCount)" + (doneKeys.isEmpty ? "" : " (\(doneKeys.prefix(10).joined(separator: ", ")))"))
        out.append("- In progress: \(inProgress)")
        out.append("- Awaiting review: \(awaitingReview)")
        out.append("- Blocked: \(blocked)" + (blockedReasons.isEmpty ? "" : " — " + blockedReasons.prefix(3).joined(separator: "; ")))
        out.append("- Untouched 7+ active days: \(untouchedCount)"
                   + (untouchedKeys.isEmpty ? "" : " (\(untouchedKeys.prefix(5).joined(separator: ", ")))"))
        for team in quietTeams { out.append("- Team gone quiet: \(MarkdownEscape.inline(team, limit: 60))") }
        out += ["", "## This week", ""]
        out.append("- \(weekTurns) turns · \(weekTokens / 1000)k tokens · $\(String(format: "%.2f", weekCostUSD))")
        if let u = sevenDayUtilization {
            out.append("- 7-day usage \(Int((u * 100).rounded()))%" + (paceText.map { " (\($0))" } ?? ""))
        }
        if let split = modeSplit {
            out.append("- By mode: " + split.map { "\($0.mode.title) \($0.percent)%" }.joined(separator: " · "))
        }
        out += ultraLines
        return out.joined(separator: "\n") + "\n"
    }
}

public enum DigestBuilder {
    /// How long an item may see no event, and a team no work turn, before the digest says so.
    public static let untouchedActive: TimeInterval = 7 * 86_400
    public static let quietActive: TimeInterval = 86_400

    /// Monday 00:00 of the week `now` falls in, in `tz`.
    public static func weekStart(now: Date, tz: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        return cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now.addingTimeInterval(-7 * 86_400)
    }

    public static func build(store: Store, companyId: String, since: Date, now: Date, tz: TimeZone) throws -> Digest {
        guard let company = try store.company(id: companyId) else { throw WorkError.notFound("no such company") }
        let active = store.activeNow(companyId: companyId)
        let frozen = store.isFrozen(companyId: companyId)
        let week = weekStart(now: now, tz: tz)
        let share = store.weeklyShare()
        var digest = Digest(companyName: company.name, date: now, timeZone: tz, periodStart: since, periodEnd: now)

        try store.writer.read { db in
            // Needs you: asks waiting on the owner, grouped by kind.
            let asks = try Ask.filter(Column("companyId") == companyId && Column("status") == AskStatus.pendingOwner.rawValue)
                .order(Column("number")).fetchAll(db)
            var order: [String] = []
            var groups: [String: [Ask]] = [:]
            for a in asks {
                let title = a.kind.title
                if groups[title] == nil { order.append(title) }
                groups[title, default: []].append(a)
            }
            digest.needsYou = order.map { title in
                let list = groups[title] ?? []
                var lines = list.prefix(5).map { "\($0.ref) \(MarkdownEscape.inline($0.title)) (\($0.risk.rawValue) risk)" }
                if list.count > 5 { lines.append("and \(list.count - 5) more") }
                return Digest.NeedsGroup(title: title, lines: lines, count: list.count)
            }

            // Progress.
            let items = try WorkItem.filter(Column("companyId") == companyId).order(Column("number")).fetchAll(db)
            let done = items.filter { $0.status == .done && ($0.doneAt ?? .distantPast) >= since }
            digest.doneCount = done.count
            digest.doneKeys = done.prefix(10).map(\.key)
            digest.inProgress = items.filter { $0.status == .inProgress }.count
            digest.awaitingReview = items.filter { $0.status == .inReview }.count
            let blocked = items.filter { $0.status == .blocked }
            digest.blocked = blocked.count
            digest.blockedReasons = blocked.prefix(3).map {
                "\($0.key): " + ($0.blockedReason.map { MarkdownEscape.inline($0, limit: 80) } ?? "no reason given")
            }
            let lastEvent = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: """
                SELECT itemId, MAX(createdActive) AS at FROM workItemEvent WHERE companyId = ? GROUP BY itemId
                """, arguments: [companyId]).map { ($0["itemId"] as String, $0["at"] as Double) })
            let untouched = items.filter { $0.status != .done && (lastEvent[$0.id] ?? 0) <= active - untouchedActive }
            digest.untouchedCount = untouched.count
            digest.untouchedKeys = untouched.prefix(5).map(\.key)

            // Teams with active members and no work turn in the last day of active time. Turns only carry calendar
            // times, so this holds only once the company has been active that long and while it is running.
            if !frozen, active >= quietActive {
                let agents = try Agent.filter(Column("companyId") == companyId && Column("state") != AgentState.killed.rawValue).fetchAll(db)
                let cutoff = now.addingTimeInterval(-quietActive)
                let recent = try Turn.filter(Column("companyId") == companyId && Column("kind") == TurnKind.work.rawValue
                                             && Column("startedAt") >= cutoff).fetchAll(db)
                let busyAgents = Set(recent.map(\.agentId))
                var teams: [String: Bool] = [:]
                for a in agents { if let t = a.team, !t.isEmpty { teams[t] = (teams[t] ?? false) || busyAgents.contains(a.id) } }
                digest.quietTeams = teams.filter { !$0.value }.map(\.key).sorted()
            }

            // Turns, tokens and cost since Monday.
            let turns = try Turn.filter(Column("companyId") == companyId && Column("startedAt") >= min(week, since)).fetchAll(db)
            digest.periodTurns = turns.filter { $0.startedAt >= since }.count
            let weekTurns = turns.filter { $0.startedAt >= week }
            digest.weekTurns = weekTurns.count
            digest.weekTokens = weekTurns.reduce(0) { $0 + $1.countedTokens }
            digest.weekCostUSD = weekTurns.reduce(0) { $0 + ($1.costUSD ?? 0) }

            var byMode: [String: Double] = [:]
            for t in weekTurns { if let m = t.mode, let c = t.costLE, c > 0 { byMode[m, default: 0] += c } }
            let total = byMode.values.reduce(0, +)
            if total > 0 {
                digest.modeSplit = WorkMode.allCases.map { ($0, Int(((byMode[$0.rawValue] ?? 0) / total * 100).rounded())) }
            }

            // Ultra runs since the last digest: one line per item. Omitted when there are none.
            let ultra = turns.filter { $0.mode == WorkMode.ultra.rawValue && $0.startedAt >= since }
            var perItem: [String: [Turn]] = [:]
            for t in ultra { perItem[t.itemId ?? "", default: []].append(t) }
            let keys = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.key) })
            digest.ultraLines = perItem.sorted { ($0.value.map(\.startedAt).min() ?? .distantPast) < ($1.value.map(\.startedAt).min() ?? .distantPast) }
                .map { itemId, runs in
                    let le = runs.reduce(0) { $0 + ($1.costLE ?? 0) }
                    let result = runs.contains { $0.outcome == .failed || $0.outcome == .usageLimited } ? "failed"
                        : runs.contains { $0.outcome == .interrupted || $0.outcome == .inProgress } ? "interrupted" : "passed"
                    return "- Ultra: \(runs.count) run\(runs.count == 1 ? "" : "s"), $\(String(format: "%.2f", le)) LE, "
                        + "\(keys[itemId].map { MarkdownEscape.inline($0, limit: 40) } ?? "no item") (\(result))"
                }

            if let info = try Store.latestRateLimit(db: db) {
                digest.sevenDayUtilization = info.sevenDayUtilization
                digest.paceText = UsageGate.pace(info, reserve: company.ownerReserve ?? (1 - share), now: now)?.text
            }
        }
        return digest
    }
}
