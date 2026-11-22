import Foundation
import GRDB

// Plan C Task C4a defines these value types exactly as Task C4b lists them, so `ShowResult` compiles before the facts
// resolver exists. C4b answers them (`FactsResolver`); nothing in C4a builds one.

/// What a factual question asks about (C4b's one trigger per kind).
public enum FactKind: String, CaseIterable, Codable, Sendable {
    case usage, blocked, whoIsOn, shipped, pendingAsks, sprintProgress, failingChecks
}

/// One line of a fact answer.
public struct FactLine: Equatable, Sendable, Codable {
    /// Engine-composed; any agent text inside is flattened and cut to 80 characters.
    public var text: String
    /// At least one.
    public var refs: [WorkRef]

    public init(text: String, refs: [WorkRef]) { self.text = text; self.refs = refs }
}

/// An engine-composed answer to a factual question (no LLM).
public struct FactAnswer: Equatable, Sendable, Codable {
    public static let maxLines = 12

    public var kind: FactKind
    /// `"BLOCKED · 3 ITEMS, 1 AGENT"`.
    public var title: String
    /// At most `maxLines`, then `"and <n> more"`, whose ref is the matching search.
    public var lines: [FactLine]
    /// `"Nothing is blocked."`.
    public var emptyText: String?
    public var asOf: Date
    public var query: String

    public init(kind: FactKind, title: String, lines: [FactLine], emptyText: String?, asOf: Date, query: String) {
        self.kind = kind; self.title = title; self.lines = lines; self.emptyText = emptyText; self.asOf = asOf; self.query = query
    }
}

// MARK: - Plan C Task C4b: the answers

/// Plan C Task C4b: common questions answered by plain code from the Store (no LLM, no turn, nothing written). One trigger
/// per kind, matched case-insensitively on the normalized query, first match wins; a query starting with `why`, `how come`,
/// `explain`, `compare` or `walk me through` is never a fact (it is a request for Ask). Windows come from `SearchFilters`.
///
/// Every line is engine-composed: keys, handles, counts, dates and the engine's own words; any agent text inside (titles,
/// reasons, versions) is flattened, made inert (`"` → `'`, brackets → parentheses), cut to `agentTextMax` characters, quoted,
/// and gated as that final string (Rulings 53-56): a piece holding a stored value reads `(withheld)`, and the whole line is
/// gated again. No line is ever dropped for what it holds, so no count depends on the vault. Durations are company-active
/// time; dates use the owner's time zone.
///
/// Scope: for an agent, the owner-only kinds (`usage`, `pendingAsks`) are nil, and every line whose refs don't all resolve
/// `.full` for it is dropped before the counts and the title are made (no hidden totals). The owner and the concierge get
/// every line. The query is never echoed: a title names only the window, counts and engine-verified objects.
public struct FactsResolver: FactsAnswering {
    public static let agentTextMax = 80
    /// The kinds only the owner (and the concierge) are answered.
    public static let ownerOnly: Set<FactKind> = [.usage, .pendingAsks]
    static let requestOpeners = ["why", "how come", "explain", "compare", "walk me through"]

    static let patterns: [(FactKind, String)] = [
        (.usage, #"\b(usage|used|spent|spend|cost|budget|burn)\b"#),
        (.blocked, #"\b(blocked|blockers?|stuck)\b"#),
        (.whoIsOn, #"\bwho('?s| is| are)? (on|working on|handling|assigned to|owns?|reviewing)\s+(?<x>.+)"#),
        (.shipped, #"\bwhat('?s| has| was)? (shipped|released|got done|been done|merged|landed)\b|\bchangelog\b"#),
        (.pendingAsks, #"\b(pending|open|waiting|outstanding) (asks?|decisions?|approvals?|questions?)\b|\bwhat needs (me|my attention|approval)\b|\bmy inbox\b"#),
        (.sprintProgress, #"\bsprint\b.*\b(progress|status|going|burndown|left)\b|\bhow('?s| is) the sprint\b"#),
        (.failingChecks, #"\b(failing|failed|red|broken) (checks?|tests?|runs?|builds?|ci)\b|\bis main (red|green|broken)\b|\bci status\b"#),
    ]
    static let triggers: [(FactKind, NSRegularExpression)] = patterns.map {
        ($0.0, try! NSRegularExpression(pattern: $0.1, options: [.caseInsensitive]))
    }

    let store: Store

    public init(store: Store) { self.store = store }

    /// The query as the triggers read it: the normalized text, with the typographic apostrophe as `'`.
    static func triggerText(_ query: String) -> String {
        ShowQuery.normalize(query).normalized.replacingOccurrences(of: "\u{2019}", with: "'")
    }

    /// The kind `query` asks about, or nil (no trigger, or a request opener).
    public static func kind(of query: String) -> FactKind? { match(query)?.kind }

    static func match(_ query: String) -> (kind: FactKind, subject: String?)? {
        let text = triggerText(query)
        let lower = text.lowercased()
        for opener in requestOpeners where lower == opener || lower.hasPrefix(opener + " ") || lower.hasPrefix(opener + ",") {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        for (kind, regex) in triggers {
            guard let m = regex.firstMatch(in: text, range: range) else { continue }
            var subject: String?
            if kind == .whoIsOn, let r = Range(m.range(withName: "x"), in: text) { subject = String(text[r]) }
            return (kind, subject)
        }
        return nil
    }

    public func answer(_ query: String, filters: SearchFilters, companyId: String, reader: Reader, now: Date,
                       gate: GlobalSearch.TextGate) throws -> FactAnswer? {
        guard let (kind, subject) = Self.match(query) else { return nil }
        if case .agent = reader, Self.ownerOnly.contains(kind) { return nil }
        _ = try ReaderContext.load(store: store, companyId: companyId, reader: reader)
        guard try store.company(id: companyId) != nil else { return nil }
        let ctx = Context(store: store, companyId: companyId, reader: reader, now: now, gate: gate,
                          query: ShowQuery.normalize(query).normalized, tz: store.ownerTimeZone())
        switch kind {
        case .usage: return try ctx.usage(filters)
        case .blocked: return try ctx.blocked()
        case .whoIsOn: return try ctx.whoIsOn(subject ?? "")
        case .shipped: return try ctx.shipped(filters)
        case .pendingAsks: return try ctx.pendingAsks()
        case .sprintProgress: return try ctx.sprintProgress(number: nil)
        case .failingChecks: return try ctx.failingChecks()
        }
    }

    /// The live answer a ref opens (C6's OPENED slot, `open_ref`): `fact:<query>` re-evaluates the query now, `sprint:<n>`
    /// is that sprint's progress. Nil for any other kind, for a reader the ref doesn't resolve `.full` for, and for a query
    /// that is no fact.
    public func answer(for ref: WorkRef, companyId: String, reader: Reader, now: Date, gate: GlobalSearch.TextGate) throws -> FactAnswer? {
        guard ref.kind == .fact || ref.kind == .sprint,
              (try? store.resolveRef(ref, for: reader, companyId: companyId))?.visibility == .full else { return nil }
        if ref.kind == .sprint {
            guard let n = Int(ref.id) else { return nil }
            let ctx = Context(store: store, companyId: companyId, reader: reader, now: now, gate: gate, query: ref.canonical,
                              tz: store.ownerTimeZone())
            return try ctx.sprintProgress(number: n)
        }
        let (normalized, stripped) = ShowQuery.normalize(ref.id)
        let sprintStart = try store.writer.read { db in
            try Date.fetchOne(db, sql: """
                SELECT COALESCE(startedAt, createdAt) FROM sprint WHERE companyId = ? AND status = 'active' ORDER BY number DESC LIMIT 1
                """, arguments: [companyId])
        }
        let filters = SearchFilters.parse(stripped, now: now, tz: store.ownerTimeZone(), activeSprintStart: sprintStart).filters
        return try answer(normalized, filters: filters, companyId: companyId, reader: reader, now: now, gate: gate)
    }

    /// The text of an answer, one line each (the `search` tool's answer block and the body `open_ref` reads): the header
    /// (`<title>, as of HH:mm`), then `- <text> [<ref>] …` per line, or `- <emptyText>`. Every ref chip goes through the
    /// display pipeline with the inert mapping, and every printed line is gated as printed (one holding a value reads
    /// `- (withheld)`, so the count of lines never depends on the vault).
    public static func lines(_ a: FactAnswer, tz: TimeZone, gate: GlobalSearch.TextGate) -> (header: String, lines: [String]) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "HH:mm"
        let title = gate.final(a.title, max: SafeTitle.max, inert: true) ?? a.kind.rawValue.uppercased()
        var out: [String] = []
        for line in a.lines {
            var s = "- " + (gate.final(line.text, max: 400, inert: false) ?? "(withheld)")
            for ref in line.refs {
                if let chip = gate.final(ref.canonical, max: RefGrammar.maxLength, inert: true) { s += " [\(chip)]" }
            }
            out.append(gate.holdsSecret(s) ? "- (withheld)" : s)
        }
        if a.lines.isEmpty, let empty = a.emptyText { out.append("- " + empty) }
        return ("\(title), as of \(f.string(from: a.asOf))", out)
    }
}

extension FactsResolver {
    /// One answer's reads and composition.
    struct Context {
        let store: Store
        let companyId: String
        let reader: Reader
        let now: Date
        let gate: GlobalSearch.TextGate
        let query: String
        let tz: TimeZone

        var isAgent: Bool { if case .agent = reader { true } else { false } }

        /// The ref of the answer itself (`fact:<query>`, the owner's): what an "and <n> more" line and an object-less owner
        /// line point at.
        var factRef: WorkRef {
            var id = query.trimmingCharacters(in: .whitespaces)
            if id.count > RefGrammar.maxFactLength { id = String(id.prefix(RefGrammar.maxFactLength)).trimmingCharacters(in: .whitespaces) }
            return WorkRef(kind: .fact, id: id.isEmpty ? "fact" : id)
        }

        // MARK: Text

        /// Agent text as a line shows it: the display pipeline with the inert mapping, cut to `agentTextMax`, quoted; a
        /// piece holding a stored value is `(withheld)`.
        func agentText(_ raw: String?, empty: String = "(none)") -> String {
            guard let raw, !GlobalSearch.TextGate.display(raw, inert: true).isEmpty else { return empty }
            guard let shown = gate.final(raw, max: FactsResolver.agentTextMax, inert: true) else { return "(withheld)" }
            let quoted = "\"" + shown + "\""
            return gate.holdsSecret(quoted) ? "(withheld)" : quoted
        }

        /// A line, gated as composed: one whose text holds a value (only possible through an engine part) keeps its refs and
        /// reads `(withheld)`.
        func line(_ text: String, _ refs: [WorkRef]) -> FactLine {
            FactLine(text: gate.holdsSecret(text) ? "(withheld)" : text, refs: refs)
        }

        func money(_ x: Double) -> String { String(format: "$%.2f", x) }
        func percent(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

        func format(_ d: Date, _ pattern: String) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = tz
            f.dateFormat = pattern
            return f.string(from: d)
        }

        /// `HH:mm` today, else `yyyy-MM-dd`.
        func stamp(_ d: Date) -> String {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            return format(d, cal.isDate(d, inSameDayAs: now) ? "HH:mm" : "yyyy-MM-dd")
        }

        func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

        func item(_ key: String) -> WorkRef { WorkRef(kind: .item, id: key) }
        func agent(_ handle: String) -> WorkRef { WorkRef(kind: .agent, id: handle) }

        /// Monday 00:00 (owner time zone) → now.
        var thisWeek: TimeWindow {
            SearchFilters.parse("this week", now: now, tz: tz, activeSprintStart: nil).filters.window
                ?? TimeWindow(start: DigestBuilder.weekStart(now: now, tz: tz), end: now, label: "THIS WEEK")
        }

        // MARK: Scope

        /// For an agent: the lines whose refs all resolve `.full` for it (a ref resolved once). The owner and the concierge:
        /// every line.
        func scoped(_ lines: [FactLine]) -> [FactLine] {
            guard isAgent else { return lines }
            var memo: [String: Bool] = [:]
            func full(_ ref: WorkRef) -> Bool {
                if let known = memo[ref.canonical] { return known }
                let ok = (try? store.resolveRef(ref, for: reader, companyId: companyId))?.visibility == .full
                memo[ref.canonical] = ok
                return ok
            }
            return lines.filter { !$0.refs.isEmpty && $0.refs.allSatisfy(full) }
        }

        func readable(_ ref: WorkRef) -> Bool {
            !isAgent || (try? store.resolveRef(ref, for: reader, companyId: companyId))?.visibility == .full
        }

        /// At most `FactAnswer.maxLines`: past that, the first `maxLines - 1` and `and <n> more`, whose ref is the matching
        /// search (`fact:<query>`; for an agent, which can't open a fact, the first line left out).
        func capped(_ lines: [FactLine]) -> [FactLine] {
            guard lines.count > FactAnswer.maxLines else { return lines }
            let kept = Array(lines.prefix(FactAnswer.maxLines - 1))
            let rest = lines.dropFirst(FactAnswer.maxLines - 1)
            let refs = isAgent ? (rest.first?.refs ?? []) : [factRef]
            return kept + [FactLine(text: "and \(rest.count) more", refs: refs)]
        }

        func answer(_ kind: FactKind, title: String, lines: [FactLine], empty: String?) -> FactAnswer {
            FactAnswer(kind: kind, title: gate.holdsSecret(title) ? kind.rawValue.uppercased() : title, lines: capped(lines),
                       emptyText: empty, asOf: now, query: query)
        }

        func handles(_ db: Database) throws -> [String: String] {
            Dictionary(try Row.fetchAll(db, sql: "SELECT id, name FROM agent WHERE companyId = ?", arguments: [companyId])
                .map { ($0["id"] as String, $0["name"] as String) }, uniquingKeysWith: { a, _ in a })
        }

        // MARK: usage (owner only)

        func usage(_ filters: SearchFilters) throws -> FactAnswer {
            let window = filters.window ?? thisWeek
            struct Read { var info: RateLimitInfo?; var share = 0.7; var reserve: Double?; var total = 0.0
                          var top: [(String, Double)] = []; var sprints: [(Int, Double)] = [] }
            let r = try store.writer.read { db -> Read in
                var r = Read()
                r.info = try Store.latestRateLimit(db: db)
                r.share = try Double.fetchOne(db, sql: "SELECT weeklyShare FROM ownerSettings WHERE id = 1") ?? 0.7
                r.reserve = try Company.fetchOne(db, key: companyId)?.ownerReserve
                r.total = try Double.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(costLE), 0) FROM turn WHERE companyId = ? AND startedAt >= ? AND startedAt <= ?
                    """, arguments: [companyId, window.start, window.end]) ?? 0
                r.top = try Row.fetchAll(db, sql: """
                    SELECT a.name AS name, SUM(t.costLE) AS le FROM turn t JOIN agent a ON a.id = t.agentId AND a.companyId = t.companyId
                    WHERE t.companyId = ? AND t.startedAt >= ? AND t.startedAt <= ? AND t.costLE > 0
                    GROUP BY t.agentId ORDER BY le DESC, a.name LIMIT 3
                    """, arguments: [companyId, window.start, window.end]).map { ($0["name"] as String, $0["le"] as Double) }
                for sprint in try Sprint.filter(Column("companyId") == companyId && Column("status") == SprintStatus.active.rawValue)
                    .order(Column("number")).fetchAll(db) {
                    guard let started = sprint.startedAt else { r.sprints.append((sprint.number, 0)); continue }
                    var sql = """
                        SELECT COALESCE(SUM(t.costLE), 0) FROM turn t JOIN agent a ON a.id = t.agentId AND a.companyId = t.companyId
                        WHERE t.companyId = ? AND t.startedAt >= ?
                        """
                    var args: [DatabaseValueConvertible] = [companyId, started]
                    if let team = sprint.team { sql += " AND a.team = ?"; args.append(team) }
                    r.sprints.append((sprint.number, try Double.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0))
                }
                return r
            }
            var lines: [FactLine] = []
            if let info = r.info {
                var s = "5H " + (info.fiveHourUtilization.map(percent) ?? "not reported")
                if let reset = info.fiveHourResetsAt, reset > now { s += " · resets \(stamp(reset))" }
                s += " · 7D " + (info.sevenDayUtilization.map(percent) ?? "not reported")
                lines.append(line(s, [factRef]))
                let share = r.reserve.map { 1 - $0 } ?? r.share
                if let seven = info.sevenDayUtilization, share > 0 {
                    lines.append(line("7D \(percent(seven)) is \(percent(seven / share)) of this company's \(percent(share)) weekly share", [factRef]))
                }
            } else {
                lines.append(line("5H and 7D usage not reported yet", [factRef]))
            }
            lines.append(line("\(money(r.total)) LE · \(window.label)", [factRef]))
            for (name, le) in r.top { lines.append(line("@\(name) \(money(le)) LE", [agent(name)])) }
            for (n, le) in r.sprints { lines.append(line("Sprint \(n) \(money(le)) LE since it started", [WorkRef(kind: .sprint, id: String(n))])) }
            return answer(.usage, title: "USAGE · \(window.label) · \(money(r.total)) LE", lines: lines, empty: nil)
        }

        // MARK: blocked

        func blocked() throws -> FactAnswer {
            let (items, agents, names, keys, active) = try store.writer.read { db in
                (try WorkItem.fetchAll(db, sql: """
                    SELECT * FROM workItem WHERE companyId = ? AND status = 'blocked'
                    ORDER BY blockedSinceActive IS NULL, blockedSinceActive, number
                    """, arguments: [companyId]),
                 try Agent.fetchAll(db, sql: "SELECT * FROM agent WHERE companyId = ? AND state = 'blocked' ORDER BY name", arguments: [companyId]),
                 try handles(db),
                 Dictionary(try Row.fetchAll(db, sql: "SELECT id, key FROM workItem WHERE companyId = ?", arguments: [companyId])
                    .map { ($0["id"] as String, $0["key"] as String) }, uniquingKeysWith: { a, _ in a }),
                 try Store.activeNow(db: db, companyId: companyId))
            }
            var itemLines: [FactLine] = []
            for i in items {
                var s = "\(i.key) " + (i.taintedOrigin ? "(untrusted)" : agentText(i.title)) + " · blocked"
                if let since = i.blockedSinceActive { s += " \(StallExplainer.age(max(0, active - since)))" }
                s += " · " + (i.taintedOrigin ? "(untrusted)" : agentText(i.blockedReason, empty: "no reason given"))
                itemLines.append(line(s, [item(i.key)]))
            }
            var agentLines: [FactLine] = []
            for a in agents {
                var refs = [agent(a.name)]
                let why: String
                switch a.blocker {
                case .agent(let id)?:
                    if let h = names[id] { why = "waiting on @\(h)"; refs.append(agent(h)) } else { why = "waiting on another agent" }
                case .owner(let reason, _)?:
                    // The reason is the agent's own text about the owner: the owner's (and the concierge's) to read.
                    why = isAgent ? "waiting on the owner" : "waiting on the owner: " + agentText(reason, empty: "no reason given")
                case .usageLimit(let until)?: why = "usage limit until \(stamp(until))"
                case .turnBudget(let until)?: why = "turn budget until \(stamp(until))"
                case .retry(let until, let failures)?: why = "retrying at \(stamp(until)) after \(plural(failures, "failure", "failures"))"
                case .workItem(let id, _)?:
                    if let key = keys[id] { why = "waiting on \(key)"; refs.append(item(key)) } else { why = "waiting on an item" }
                case nil: why = "no reason recorded"
                }
                agentLines.append(line("@\(a.name) blocked · \(why)", refs))
            }
            let shownItems = scoped(itemLines), shownAgents = scoped(agentLines)
            return answer(.blocked, title: "BLOCKED · \(plural(shownItems.count, "ITEM", "ITEMS")), \(plural(shownAgents.count, "AGENT", "AGENTS"))",
                          lines: shownItems + shownAgents, empty: "Nothing is blocked.")
        }

        // MARK: who is on

        func whoIsOn(_ raw: String) throws -> FactAnswer {
            var x = raw.trimmingCharacters(in: .whitespaces)
            while let last = x.last, "?!.,;:".contains(last) { x.removeLast() }
            x = x.trimmingCharacters(in: .whitespaces)
            var lines: [FactLine] = []
            let oneToken = !x.isEmpty && !x.contains(where: { $0.isWhitespace })
            if oneToken, x.hasPrefix("#") {
                lines = try channelMembers(String(x.dropFirst()).lowercased())
            } else if oneToken, let key = ShowPhrases.itemKey(x) {
                lines = try onItem(key)
            } else if oneToken, x.contains("/") || x.contains("."), RefGrammar.isPath(x) {
                lines = try onPath(x)
            } else {
                var team = x.lowercased()
                if team.hasPrefix("the ") { team.removeFirst(4) }
                if team.hasSuffix(" team") { team.removeLast(5) }
                lines = try teamMembers(team.trimmingCharacters(in: .whitespaces))
            }
            let shown = scoped(lines)
            let people = Set(shown.flatMap(\.refs).filter { $0.kind == .agent }.map(\.id)).count
            return answer(.whoIsOn, title: "WHO'S ON · \(plural(people, "PERSON", "PEOPLE"))", lines: shown, empty: "Nobody is on that.")
        }

        /// A key: its lease holder (with the item's title and status), its assignee when another agent, its reviewer.
        func onItem(_ key: String) throws -> [FactLine] {
            try store.writer.read { db in
                guard let i = try RefAccess.item(db, companyId, key) else { return [] }
                let names = try handles(db)
                let holder = try Store.leaseHolderId(db: db, itemId: i.id).flatMap { names[$0] }
                var out: [FactLine] = []
                let head = "\(i.key) " + (i.taintedOrigin ? "(untrusted)" : agentText(i.title)) + " · \(i.status.rawValue)"
                if let holder {
                    out.append(line(head + " · held by @\(holder)", [item(i.key), agent(holder)]))
                } else {
                    out.append(line(head + " · not leased", [item(i.key)]))
                }
                if let owner = i.ownerId.flatMap({ names[$0] }), owner != holder {
                    out.append(line("\(i.key) assignee @\(owner)", [item(i.key), agent(owner)]))
                }
                if let reviewer = i.reviewerId.flatMap({ names[$0] }) {
                    out.append(line("\(i.key) reviewer @\(reviewer)", [item(i.key), agent(reviewer)]))
                }
                return out
            }
        }

        /// A path: the open items whose touch paths cover it (matched on what the reader sees of them, Ruling 56), and the
        /// newest commit on `main` touching it with the author the engine recorded (C4b), if the reader may read the path.
        func onPath(_ path: String) throws -> [FactLine] {
            let allowed = try store.writer.read { db in
                try RefAccess.canRead(reader, WorkRef(kind: .file, id: path), companyId: companyId, db: db, catalog: store.catalog)
            }
            guard case .allowed = allowed else { return [] }
            var out: [FactLine] = try store.writer.read { db in
                let names = try handles(db)
                var lines: [FactLine] = []
                for i in try WorkItem.fetchAll(db, sql: "SELECT * FROM workItem WHERE companyId = ? AND status != 'done' ORDER BY number",
                                               arguments: [companyId]) {
                    let paths = i.touchPaths.map { gate.matchText($0) }.filter { !$0.isEmpty }
                    guard paths.contains(where: { PathOverlap.overlaps(path: $0, path) }) else { continue }
                    let holder = try Store.leaseHolderId(db: db, itemId: i.id).flatMap { names[$0] }
                    let s = "\(i.key) " + (i.taintedOrigin ? "(untrusted)" : agentText(i.title)) + " · \(i.status.rawValue)"
                        + (holder.map { " · held by @\($0)" } ?? " · not leased")
                    lines.append(line(s, [item(i.key)] + (holder.map { [agent($0)] } ?? [])))
                }
                return lines
            }
            if let company = try store.company(id: companyId),
               let git = try? store.refGit(URL(fileURLWithPath: company.workspacePath, isDirectory: true)),
               let main = try? git.head("main"), let sha = (try? git.logShas(range: main, path: path))?.first {
                let author = try store.recordedCommitAuthors(companyId: companyId, shas: [sha])[sha]
                let commit = WorkRef(kind: .commit, id: sha)
                if let author {
                    out.append(line("last commit \(sha.prefix(7)) by @\(author)", [commit, agent(author)]))
                } else {
                    out.append(line("last commit \(sha.prefix(7)) · unverified author", [commit]))
                }
            }
            return out
        }

        /// Members with the items they hold now.
        func memberLines(_ db: Database, _ members: [Agent], extra: [WorkRef]) throws -> [FactLine] {
            var out: [FactLine] = []
            for a in members where a.state != .killed {
                let keys = try String.fetchAll(db, sql: """
                    SELECT w.key FROM workLease l JOIN workItem w ON w.id = l.itemId AND w.companyId = l.companyId
                    WHERE l.companyId = ? AND l.agentId = ? ORDER BY w.number
                    """, arguments: [companyId, a.id])
                let s = "@\(a.name) · " + (keys.isEmpty ? "no current item" : keys.joined(separator: ", "))
                out.append(line(s, [agent(a.name)] + extra + keys.map(item)))
            }
            return out
        }

        func channelMembers(_ name: String) throws -> [FactLine] {
            try store.writer.read { db in
                guard RefGrammar.isChannelName(name),
                      let channel = try Channel.fetchOne(db, sql: "SELECT * FROM channel WHERE companyId = ? AND name = ? AND kind = 'channel'",
                                                         arguments: [companyId, name]) else { return [] }
                let members = try Agent.fetchAll(db, sql: """
                    SELECT a.* FROM channelMember m JOIN agent a ON a.id = m.member AND a.companyId = ?
                    WHERE m.channelId = ? ORDER BY a.name
                    """, arguments: [companyId, channel.id])
                return try memberLines(db, members, extra: [WorkRef(kind: .channel, id: channel.name)])
            }
        }

        /// A team: matched on the team name as the reader sees it (Ruling 56: the display form, stored values blanked).
        func teamMembers(_ team: String) throws -> [FactLine] {
            guard !team.isEmpty else { return [] }
            return try store.writer.read { db in
                let members = try Agent.fetchAll(db, sql: "SELECT * FROM agent WHERE companyId = ? AND team IS NOT NULL ORDER BY name",
                                                 arguments: [companyId])
                    .filter { gate.matchText($0.team ?? "").lowercased() == team }
                return try memberLines(db, members, extra: [])
            }
        }

        // MARK: shipped

        func shipped(_ filters: SearchFilters) throws -> FactAnswer {
            let latest = try store.writer.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT number, deployedAt FROM release WHERE companyId = ? AND status = 'deployed' AND deployedAt IS NOT NULL
                    ORDER BY deployedAt DESC, number DESC LIMIT 1
                    """, arguments: [companyId])
            }
            let window: TimeWindow
            if let w = filters.window {
                window = w
            } else if let latest, let at: Date = latest["deployedAt"] {
                window = TimeWindow(start: at, end: now, label: "SINCE REL:\(latest["number"] as Int)")
            } else {
                window = thisWeek
            }
            let (releases, done, merged) = try store.writer.read { db in
                (try Row.fetchAll(db, sql: """
                    SELECT number, version, deployedAt FROM release WHERE companyId = ? AND status = 'deployed'
                      AND deployedAt >= ? AND deployedAt <= ? ORDER BY deployedAt DESC, number DESC
                    """, arguments: [companyId, window.start, window.end]),
                 try WorkItem.fetchAll(db, sql: """
                    SELECT * FROM workItem WHERE companyId = ? AND status = 'done' AND doneAt >= ? AND doneAt <= ?
                    ORDER BY doneAt DESC, number DESC
                    """, arguments: [companyId, window.start, window.end]),
                 try String.fetchAll(db, sql: """
                    SELECT w.key FROM mergeRequest m JOIN workItem w ON w.id = m.itemId AND w.companyId = m.companyId
                    WHERE m.companyId = ? AND m.status = 'merged' AND m.finishedAt >= ? AND m.finishedAt <= ?
                    ORDER BY m.finishedAt DESC, m.number DESC
                    """, arguments: [companyId, window.start, window.end]))
            }
            let releaseLines = scoped(releases.map { row in
                let n: Int = row["number"]
                let at: Date = row["deployedAt"]
                return line("Release \(agentText(row["version"] as String)) deployed \(format(at, "yyyy-MM-dd"))", [WorkRef(kind: .release, id: String(n))])
            })
            let itemLines = scoped(done.map { i in
                line("\(i.key) " + (i.taintedOrigin ? "(untrusted)" : agentText(i.title)) + " done " + format(i.doneAt ?? now, "yyyy-MM-dd"), [item(i.key)])
            })
            // Merges are counted over the items the reader can read.
            let merges = merged.filter { readable(item($0)) }
            var mergeLines: [FactLine] = []
            if !merges.isEmpty {
                var distinct: [String] = []
                for k in merges where !distinct.contains(k) { distinct.append(k) }
                mergeLines = [line("\(plural(merges.count, "merge", "merges")) to main", Array(distinct.prefix(6)).map(item))]
            }
            let title = "SHIPPED · \(window.label) · \(plural(releaseLines.count, "RELEASE", "RELEASES")), "
                + "\(plural(itemLines.count, "ITEM", "ITEMS")), \(plural(merges.count, "MERGE", "MERGES"))"
            return answer(.shipped, title: title, lines: releaseLines + mergeLines + itemLines, empty: "Nothing shipped in that window.")
        }

        // MARK: pending asks (owner only)

        func pendingAsks() throws -> FactAnswer {
            let (asks, active) = try store.writer.read { db in
                (try Ask.fetchAll(db, sql: """
                    SELECT * FROM ask WHERE companyId = ? AND status = 'pendingOwner' ORDER BY statusSinceActive, number
                    """, arguments: [companyId]),
                 try Store.activeNow(db: db, companyId: companyId))
            }
            let lines = scoped(asks.map { a in
                line("\(a.ref) \(agentText(a.title)) · \(a.kind.title) · waiting \(StallExplainer.age(max(0, active - a.statusSinceActive)))",
                     [WorkRef(kind: .ask, id: String(a.number))])
            })
            return answer(.pendingAsks, title: "PENDING ASKS · \(lines.count)", lines: lines, empty: "Nothing is waiting on you.")
        }

        // MARK: sprint progress

        /// Every active sprint (`number` nil), or that sprint: done/total items and points, blocked items, the active days left
        /// of its timebox and the team turns used of its budget.
        func sprintProgress(number: Int?) throws -> FactAnswer {
            let rows = try store.writer.read { db -> [(Sprint, [WorkItem], Int, Double)] in
                let sprints: [Sprint]
                if let number {
                    sprints = try Sprint.fetchAll(db, sql: "SELECT * FROM sprint WHERE companyId = ? AND number = ?", arguments: [companyId, number])
                } else {
                    sprints = try Sprint.fetchAll(db, sql: "SELECT * FROM sprint WHERE companyId = ? AND status = 'active' ORDER BY number",
                                                  arguments: [companyId])
                }
                let active = try Store.activeNow(db: db, companyId: companyId)
                return try sprints.map { s in
                    (s, try WorkItem.fetchAll(db, sql: "SELECT * FROM workItem WHERE companyId = ? AND sprintId = ? ORDER BY number",
                                              arguments: [companyId, s.id]),
                     try Store.sprintTeamTurns(db, s), active)
                }
            }
            var lines: [FactLine] = []
            for (s, items, turns, active) in rows {
                let done = items.filter { $0.status == .done }
                let blocked = items.filter { $0.status == .blocked }
                let points = items.reduce(0) { $0 + ($1.points ?? 0) }, donePoints = done.reduce(0) { $0 + ($1.points ?? 0) }
                var text = "Sprint \(s.number)" + (s.team.map { " · team " + agentText($0) } ?? "")
                text += " · \(done.count)/\(items.count) items · \(donePoints)/\(points) points · \(blocked.count) blocked"
                if s.status == .active {
                    let used = max(0, active - (s.startedActive ?? active))
                    let left = max(0, Double(s.timeboxDays) * Sprint.day - used) / Sprint.day
                    text += " · " + String(format: "%.1f", left) + " active days left"
                } else {
                    text += " · \(s.status.rawValue)"
                }
                text += " · \(turns)/\(s.timeboxTurns) team turns"
                lines.append(line(text, [WorkRef(kind: .sprint, id: String(s.number))] + blocked.map { item($0.key) }))
            }
            let shown = scoped(lines)
            let title = number.map { n in "SPRINT \(n)" + (rows.first.map { " · \($0.0.status.rawValue.uppercased())" } ?? "") }
                ?? "SPRINT · \(shown.count) ACTIVE"
            return answer(.sprintProgress, title: title, lines: shown, empty: "No sprint is active.")
        }

        // MARK: failing checks

        func failingChecks() throws -> FactAnswer {
            struct Read { var runs: [(VerificationRun, WorkItem)] = []; var smoke: MainSmokeRun?; var bug: String?
                          var hold: String?; var queued: [String] = [] }
            let r = try store.writer.read { db -> Read in
                var r = Read()
                let runs = try VerificationRun.fetchAll(db, sql: """
                    SELECT v.* FROM verificationRun v WHERE v.companyId = ?
                      AND v.rowid = (SELECT v2.rowid FROM verificationRun v2 WHERE v2.companyId = v.companyId AND v2.itemId = v.itemId
                                     ORDER BY v2.createdAt DESC, v2.rowid DESC LIMIT 1)
                      AND v.status IN ('failed', 'timedOut', 'error')
                    ORDER BY v.createdAt DESC, v.rowid DESC
                    """, arguments: [companyId])
                for run in runs {
                    if let i = try WorkItem.fetchOne(db, sql: "SELECT * FROM workItem WHERE companyId = ? AND id = ?", arguments: [companyId, run.itemId]) {
                        r.runs.append((run, i))
                    }
                }
                r.smoke = try MainSmokeRun.fetchOne(db, sql: """
                    SELECT * FROM mainSmokeRun WHERE companyId = ? AND status IN ('passed', 'failed') ORDER BY createdAt DESC, rowid DESC LIMIT 1
                    """, arguments: [companyId])
                let company = try Company.fetchOne(db, key: companyId)
                if let bugId = company?.redBugItemId {
                    r.bug = try String.fetchOne(db, sql: "SELECT key FROM workItem WHERE companyId = ? AND id = ?", arguments: [companyId, bugId])
                }
                r.hold = company?.mergeHold
                r.queued = try String.fetchAll(db, sql: """
                    SELECT w.key FROM mergeRequest m JOIN workItem w ON w.id = m.itemId AND w.companyId = m.companyId
                    WHERE m.companyId = ? AND m.status IN ('queued', 'running', 'landing') ORDER BY m.number LIMIT 6
                    """, arguments: [companyId])
                return r
            }
            let runLines = scoped(r.runs.map { run, i in
                let exit = run.exitCode.map { " (exit \($0))" } ?? ""
                return line("\(i.key) " + (i.taintedOrigin ? "(untrusted)" : agentText(i.title)) + " · run \(run.status.rawValue)\(exit) · \(stamp(run.createdAt))",
                            [WorkRef(kind: .run, id: run.id), item(i.key)])
            })
            var redLines: [FactLine] = []
            if let smoke = r.smoke, smoke.status == .failed {
                let refs = r.bug.map { [item($0)] } ?? [WorkRef(kind: .commit, id: smoke.commit)]
                redLines = scoped([line("main is red at \(smoke.sha7) (\(smoke.failure))" + (r.bug.map { " · bug \($0)" } ?? ""), refs)])
            }
            var holdLines: [FactLine] = []
            if let hold = r.hold {
                let refs = r.bug.map { [item($0)] } ?? (r.queued.isEmpty ? [factRef] : r.queued.map(item))
                let reason = gate.final(hold, max: FactsResolver.agentTextMax, inert: true) ?? "(withheld)"
                holdLines = scoped([line("merge queue held: \(reason)", refs)])
            }
            var title = "FAILING · \(plural(runLines.count, "RUN", "RUNS"))"
            if !redLines.isEmpty { title += ", MAIN RED" }
            if !holdLines.isEmpty { title += ", MERGE QUEUE HELD" }
            return answer(.failingChecks, title: title, lines: runLines + redLines + holdLines, empty: "Nothing is failing.")
        }
    }
}
