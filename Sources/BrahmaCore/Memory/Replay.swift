import Foundation
import GRDB

/// What a replay shows: one agent's day (`yyyy-MM-dd` in the owner's time zone) or one item's whole history.
public enum ReplaySubject: Equatable, Sendable {
    case agentDay(agentId: String, day: String)
    case item(itemId: String)
}

/// The kind of a replay line.
public enum ReplayKind: String, CaseIterable, Sendable {
    case turn, toolUse, message, itemEvent, ask, handbook, memory, resource, transcript

    /// The uppercase label the CLI prints and the app's filter chips show.
    public var label: String {
        switch self {
        case .turn: "TURN"
        case .toolUse: "TOOL"
        case .message: "MESSAGE"
        case .itemEvent: "ITEM"
        case .ask: "ASK"
        case .handbook: "HANDBOOK"
        case .memory: "MEMORY"
        case .resource: "RESOURCE"
        case .transcript: "TRANSCRIPT"
        }
    }
}

/// One line of a replay. `actor` is a handle (`owner`, `system` or an agent's name), `text` one flattened line of at most
/// `Replay.maxText` characters, `ref` what the line points at (`INITE-3`, `A-2`, `kb:<path>`, `mem:<n>`, `F-<n>`,
/// `transcript:<turnId>`).
public struct ReplayEntry: Equatable, Sendable {
    public var at: Date
    public var kind: ReplayKind
    public var actor: String
    public var text: String
    public var ref: String?
    public var turnId: String?

    public init(at: Date, kind: ReplayKind, actor: String, text: String, ref: String? = nil, turnId: String? = nil) {
        self.at = at; self.kind = kind; self.actor = actor; self.text = text; self.ref = ref; self.turnId = turnId
    }
}

/// The owner's replay (Plan ML Task 9): an agent's day or an item's history, merged from the tables as they stand. It is
/// computed on every read and never stored (ruling 5: no recall, tool output or resource text is copied anywhere). Purged
/// rows show the text they were left with (`[purged F-n]`, `[purged]`); nothing is re-derived from another source.
///
/// Owner only: its callers are `brahma replay` (`requireOwnerShell()`) and the app; no agent tool reaches it.
public enum Replay {
    public static let maxEntries = 2000
    /// Agent text is flattened to one line of at most this many characters.
    public static let maxText = 300

    /// The subject's lines, oldest first (by time, then source order), at most `maxEntries`: the newest are kept.
    /// An agent or item of another company is `.forbidden("not in your company")`.
    public static func timeline(store: Store, companyId: String, subject: ReplaySubject, tz: TimeZone) throws -> [ReplayEntry] {
        try store.writer.read { db in
            let handles = try handleMap(db, companyId: companyId)
            var lines: [ReplayEntry]
            switch subject {
            case .agentDay(let agentId, let day):
                guard let range = dayInterval(day, tz: tz) else { throw WorkError.invalid("day must be yyyy-MM-dd") }
                guard let agent = try Agent.fetchOne(db, key: agentId) else { throw WorkError.notFound("no such agent") }
                guard agent.companyId == companyId else { throw WorkError.forbidden("not in your company") }
                lines = try agentDay(db, agent: agent, range: range, handles: handles)
            case .item(let itemId):
                guard let item = try WorkItem.fetchOne(db, key: itemId) else { throw WorkError.notFound("no such item") }
                guard item.companyId == companyId else { throw WorkError.forbidden("not in your company") }
                lines = try itemHistory(db, item: item, handles: handles)
            }
            // Stable: equal times keep source order.
            let ordered = lines.enumerated().sorted { a, b in
                a.element.at != b.element.at ? a.element.at < b.element.at : a.offset < b.offset
            }.map(\.element)
            return Array(ordered.suffix(maxEntries))
        }
    }

    // MARK: Transcripts a purge flagged

    /// What the transcript pane (and `brahma transcript`) says over a turn's transcript that a purge report lists. A purge
    /// lists, by turn id, the captured transcripts that read the resource through Brahma's tools and every captured turn of
    /// one of its readers while it existed (shell and mirror reads are not tracked one by one); it does not rewrite them.
    public static let purgedTranscriptNotice =
        "This transcript was captured while a since-purged resource existed; it may still contain that content."

    /// The purged resources whose purge report lists `turnId`'s transcript, as `[purged F-n]` (a folder purged with its
    /// files is named once, by the folder), in number order. Only the tombstone's ref is used: never its name, URL or path.
    public static func purgesFlagging(store: Store, companyId: String, turnId: String) throws -> [String] {
        try store.writer.read { db in
            var flagged: [(id: String, parentId: String?, number: Int)] = []
            for row in try Row.fetchAll(db, sql: """
                SELECT id, parentId, number, purgeReport FROM resource
                WHERE companyId = ? AND purgedAt IS NOT NULL AND purgeReport IS NOT NULL AND instr(purgeReport, ?) > 0
                ORDER BY number
                """, arguments: [companyId, turnId]) {
                let raw: String = row["purgeReport"]
                guard let report = try? JSONDecoder().decode(PurgeReport.self, from: Data(raw.utf8)),
                      report.transcripts.contains(turnId) else { continue }
                flagged.append((row["id"], row["parentId"], row["number"]))
            }
            let ids = Set(flagged.map(\.id))
            return flagged.filter { $0.parentId.map { !ids.contains($0) } ?? true }.map { "[purged F-\($0.number)]" }
        }
    }

    /// The pane's notice for `turnId`'s transcript (`purgedTranscriptNotice` and the purges' refs), or nil when no purge
    /// report lists it.
    public static func transcriptNotice(store: Store, companyId: String, turnId: String) throws -> String? {
        let refs = try purgesFlagging(store: store, companyId: companyId, turnId: turnId)
        guard !refs.isEmpty else { return nil }
        return purgedTranscriptNotice + " (" + refs.joined(separator: ", ") + ")"
    }

    // MARK: Days

    /// The owner's calendar day `yyyy-MM-dd` as an interval (23, 24 or 25 hours long), or nil when it is not such a date.
    public static func dayInterval(_ day: String, tz: TimeZone) -> DateInterval? {
        guard day.utf8.count == 10, let start = formatter(tz).date(from: day), formatter(tz).string(from: start) == day else { return nil }
        let cal = calendar(tz)
        let begin = cal.startOfDay(for: start)
        guard let end = cal.date(byAdding: .day, value: 1, to: begin) else { return nil }
        return DateInterval(start: begin, end: end)
    }

    /// The owner's calendar day of `date`.
    public static func dayString(_ date: Date, tz: TimeZone) -> String { formatter(tz).string(from: date) }

    /// `day` moved by `delta` calendar days in the owner's time zone, or nil when `day` is not a date.
    public static func day(_ day: String, adding delta: Int, tz: TimeZone) -> String? {
        guard let range = dayInterval(day, tz: tz),
              let moved = calendar(tz).date(byAdding: .day, value: delta, to: range.start) else { return nil }
        return dayString(moved, tz: tz)
    }

    private static func calendar(_ tz: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal
    }

    private static func formatter(_ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar(tz)
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    // MARK: Text

    /// One line: every run of whitespace, newlines and control characters becomes a single space; at most `maxText`
    /// characters (an ellipsis marks a cut).
    public static func flatten(_ text: String, limit: Int = maxText) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for s in text.unicodeScalars {
            if s.properties.isWhitespace || s.value < 0x20 || (0x7F...0x9F).contains(s.value) || s == "\u{2028}" || s == "\u{2029}" {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(s)
        }
        let flat = String(out)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }

    // MARK: Sources

    private static func handleMap(_ db: Database, companyId: String) throws -> [String: String] {
        var map: [String: String] = ["owner": "owner", "system": "system"]
        for row in try Row.fetchAll(db, sql: "SELECT id, name FROM agent WHERE companyId = ?", arguments: [companyId]) {
            map[row["id"] as String] = row["name"] as String
        }
        return map
    }

    private static func handle(_ id: String?, _ handles: [String: String]) -> String {
        guard let id else { return "system" }
        return handles[id] ?? String(id.prefix(8))
    }

    /// The newest `maxEntries` rows of a query ordered newest first, returned oldest first.
    private static func newest(_ db: Database, _ sql: String, _ arguments: StatementArguments) throws -> [Row] {
        Array(try Row.fetchAll(db, sql: sql + " LIMIT \(maxEntries)", arguments: arguments).reversed())
    }

    private static func agentDay(_ db: Database, agent: Agent, range: DateInterval, handles: [String: String]) throws -> [ReplayEntry] {
        let (c, a, from, to) = (agent.companyId, agent.id, range.start, range.end)
        var out: [ReplayEntry] = []
        let me = agent.name

        // Turns started that day: a start line, and an end line once it ended.
        for row in try newest(db, """
            SELECT * FROM turn WHERE companyId = ? AND agentId = ? AND startedAt >= ? AND startedAt < ?
            ORDER BY startedAt DESC, rowid DESC
            """, [c, a, from, to]) {
            out += turnLines(try Turn(row: row), actor: me)
        }
        // Its tool calls (`@handle tool`: the activity line names the tool only).
        for row in try newest(db, """
            SELECT turnId, text, createdAt FROM activityEvent
            WHERE companyId = ? AND agentId = ? AND kind = 'toolUse' AND createdAt >= ? AND createdAt < ?
            ORDER BY createdAt DESC, id DESC
            """, [c, a, from, to]) {
            out.append(ReplayEntry(at: row["createdAt"], kind: .toolUse, actor: me, text: flatten(row["text"]), turnId: row["turnId"]))
        }
        // Messages it sent, DMs to it, and messages that @mention it.
        let dmChannels = Set(try String.fetchAll(db, sql: """
            SELECT c.id FROM channel c JOIN channelMember m ON m.channelId = c.id
            WHERE c.companyId = ? AND c.kind = 'dm' AND m.member = ?
            """, arguments: [c, a]))
        let mention = "%@" + escapeLike(me) + "%"
        for row in try newest(db, """
            SELECT m.id, m.channelId, m.senderId, m.text, m.createdAt, ch.name AS channelName, ch.kind AS channelKind
            FROM message m JOIN channel ch ON ch.id = m.channelId
            WHERE m.companyId = ? AND m.createdAt >= ? AND m.createdAt < ?
              AND (m.senderId = ? OR (ch.kind = 'dm' AND ch.id IN (SELECT channelId FROM channelMember WHERE member = ?))
                   OR m.text LIKE ? ESCAPE '\\')
            ORDER BY m.createdAt DESC, m.rowid DESC
            """, [c, from, to, a, a, mention]) {
            let sender: String = row["senderId"], channelId: String = row["channelId"], text: String = row["text"]
            if sender != a, !dmChannels.contains(channelId), !MessageRouter.mentions(in: text).contains(me.lowercased()) { continue }
            out.append(messageLine(row, handles: handles))
        }
        // Item events it was the actor of.
        for row in try newest(db, """
            SELECT e.kind, e.text, e.createdAt, i.key FROM workItemEvent e JOIN workItem i ON i.id = e.itemId
            WHERE e.companyId = ? AND e.actorId = ? AND e.createdAt >= ? AND e.createdAt < ?
            ORDER BY e.createdAt DESC, e.id DESC
            """, [c, a, from, to]) {
            let key: String = row["key"]
            out.append(ReplayEntry(at: row["createdAt"], kind: .itemEvent, actor: me,
                                   text: flatten("\(key) \(row["kind"] as String)" + eventText(row["text"])), ref: key))
        }
        // Asks it requested.
        for row in try newest(db, """
            SELECT number, kind, title, status, createdAt FROM ask
            WHERE companyId = ? AND requesterId = ? AND createdAt >= ? AND createdAt < ?
            ORDER BY createdAt DESC, number DESC
            """, [c, a, from, to]) {
            out.append(askLine(row, actor: me))
        }
        // Handbook revisions it wrote.
        for row in try newest(db, """
            SELECT p.path, r.number, r.summary, r.diffSummary, r.createdAt FROM kbRevision r JOIN kbPage p ON p.id = r.pageId
            WHERE r.companyId = ? AND r.authorId = ? AND r.createdAt >= ? AND r.createdAt < ?
            ORDER BY r.createdAt DESC, r.id DESC
            """, [c, a, from, to]) {
            out.append(kbLine(row, actor: me))
        }
        // Memory entries it wrote (as they stand: a purged one shows its purged text).
        for row in try newest(db, """
            SELECT number, type, fact, createdAt, turnId, removedAt FROM memoryEntry
            WHERE companyId = ? AND authorId = ? AND createdAt >= ? AND createdAt < ?
            ORDER BY createdAt DESC, number DESC
            """, [c, a, from, to]) {
            let number: Int = row["number"]
            let removed = (row["removedAt"] as Date?) != nil ? " (deleted)" : ""
            out.append(ReplayEntry(at: row["createdAt"], kind: .memory, actor: me,
                                   text: flatten("mem:\(number) \(row["type"] as String)\(removed): \(row["fact"] as String)"),
                                   ref: "mem:\(number)", turnId: row["turnId"]))
        }
        // Resources announced to it: the announcement reached its inbox, or answered its question.
        for row in try newest(db, """
            SELECT number, kind, displayName, purgedAt, removedAt, createdAt FROM resource r
            WHERE r.companyId = ? AND r.parentId IS NULL AND r.createdAt >= ? AND r.createdAt < ?
              AND (r.messageId IN (SELECT messageId FROM inboxItem WHERE agentId = ?)
                   OR r.askId IN (SELECT id FROM ask WHERE companyId = ? AND requesterId = ?))
            ORDER BY r.createdAt DESC, r.number DESC
            """, [c, from, to, a, c, a]) {
            out.append(resourceLine(row))
        }
        // Captured transcripts: their size only, never their content.
        for row in try newest(db, """
            SELECT turnId, byteStart, byteEnd, capturedAt FROM turnTranscript
            WHERE companyId = ? AND agentId = ? AND capturedAt >= ? AND capturedAt < ?
            ORDER BY capturedAt DESC, rowid DESC
            """, [c, a, from, to]) {
            let turnId: String = row["turnId"]
            let bytes = (row["byteEnd"] as Int64) - (row["byteStart"] as Int64)
            out.append(ReplayEntry(at: row["capturedAt"], kind: .transcript, actor: me,
                                   text: "transcript captured (\(ResourceText.size(bytes)))", ref: "transcript:\(turnId)", turnId: turnId))
        }
        return out
    }

    private static func itemHistory(_ db: Database, item: WorkItem, handles: [String: String]) throws -> [ReplayEntry] {
        let (c, i) = (item.companyId, item.id)
        var out: [ReplayEntry] = []
        for row in try newest(db, """
            SELECT actorId, kind, text, createdAt FROM workItemEvent WHERE companyId = ? AND itemId = ?
            ORDER BY createdAt DESC, id DESC
            """, [c, i]) {
            out.append(ReplayEntry(at: row["createdAt"], kind: .itemEvent, actor: handle(row["actorId"], handles),
                                   text: flatten((row["kind"] as String) + eventText(row["text"])), ref: item.key))
        }
        for row in try newest(db, "SELECT * FROM turn WHERE companyId = ? AND itemId = ? ORDER BY startedAt DESC, rowid DESC", [c, i]) {
            let turn = try Turn(row: row)
            out += turnLines(turn, actor: handle(turn.agentId, handles))
        }
        for row in try newest(db, """
            SELECT purpose, status, attempt, exitCode, requestedBy, "commit", createdAt, startedAt, finishedAt FROM verificationRun
            WHERE companyId = ? AND itemId = ? ORDER BY createdAt DESC, rowid DESC
            """, [c, i]) {
            let status: String = row["status"], purpose: String = row["purpose"], commit: String = row["commit"]
            var text = "check \(purpose) \(status)"
            if let code = row["exitCode"] as Int? { text += " (exit \(code))" }
            let attempt: Int = row["attempt"]
            if attempt > 1 { text += " · attempt \(attempt)" }
            if !commit.isEmpty { text += " · \(commit.prefix(8))" }
            let at = (row["finishedAt"] as Date?) ?? (row["startedAt"] as Date?) ?? (row["createdAt"] as Date)
            out.append(ReplayEntry(at: at, kind: .itemEvent, actor: handle((row["requestedBy"] as String?) ?? "system", handles),
                                   text: flatten(text), ref: item.key))
        }
        for row in try newest(db, """
            SELECT number, kind, title, status, createdAt, requesterId FROM ask WHERE companyId = ? AND itemId = ?
            ORDER BY createdAt DESC, number DESC
            """, [c, i]) {
            out.append(askLine(row, actor: handle(row["requesterId"], handles)))
        }
        for row in try newest(db, """
            SELECT p.path, r.number, r.summary, r.diffSummary, r.createdAt, r.authorId FROM kbRevision r JOIN kbPage p ON p.id = r.pageId
            WHERE r.companyId = ? AND r.itemId = ? ORDER BY r.createdAt DESC, r.id DESC
            """, [c, i]) {
            out.append(kbLine(row, actor: handle(row["authorId"], handles)))
        }
        for row in try newest(db, """
            SELECT authorId, toAgentId, path, auto, createdAt FROM handoff WHERE companyId = ? AND itemId = ?
            ORDER BY createdAt DESC, rowid DESC
            """, [c, i]) {
            var text = (row["auto"] as Bool) ? "hand-off (engine)" : "hand-off"
            if let to = row["toAgentId"] as String? { text += " to @\(handle(to, handles))" }
            text += ": \(row["path"] as String)"
            out.append(ReplayEntry(at: row["createdAt"], kind: .itemEvent, actor: handle(row["authorId"], handles), text: flatten(text),
                                   ref: item.key))
        }
        // Messages naming the key; a longer key (`INITE-3` in `INITE-31`) is another item.
        for row in try newest(db, """
            SELECT m.id, m.channelId, m.senderId, m.text, m.createdAt, ch.name AS channelName, ch.kind AS channelKind
            FROM message m JOIN channel ch ON ch.id = m.channelId
            WHERE m.companyId = ? AND m.text LIKE ? ESCAPE '\\' ORDER BY m.createdAt DESC, m.rowid DESC
            """, [c, "%" + escapeLike(item.key) + "%"]) {
            guard names(row["text"], key: item.key) else { continue }
            out.append(messageLine(row, handles: handles))
        }
        return out
    }

    // MARK: Lines

    private static func turnLines(_ t: Turn, actor: String) -> [ReplayEntry] {
        var lines = [ReplayEntry(at: t.startedAt, kind: .turn, actor: actor, text: "turn \(t.kind.rawValue) started", turnId: t.id)]
        if let end = t.endedAt {
            let cost = String(format: "%.2f", t.costLE ?? t.costUSD ?? 0)
            var text = "turn \(t.kind.rawValue) · \(t.mode ?? "—") · \(t.outcome.rawValue) · \(t.countedTokens / 1000)k tok · $\(cost)"
            if let summary = t.summary, !flatten(summary).isEmpty { text += " — " + summary }
            lines.append(ReplayEntry(at: end, kind: .turn, actor: actor, text: flatten(text), turnId: t.id))
        }
        return lines
    }

    private static func messageLine(_ row: Row, handles: [String: String]) -> ReplayEntry {
        let name: String = row["channelName"], kind: String = row["channelKind"], sender: String = row["senderId"]
        let senderHandle = handle(sender, handles)
        let place: String
        if kind == "dm" {
            let others = name.split(separator: ":").dropFirst().map(String.init).filter { $0 != senderHandle }
            place = "DM" + (others.isEmpty ? "" : " to " + others.map { "@" + $0 }.joined(separator: ", "))
        } else {
            place = "#" + name
        }
        return ReplayEntry(at: row["createdAt"], kind: .message, actor: senderHandle, text: flatten("\(place): \(row["text"] as String)"))
    }

    private static func askLine(_ row: Row, actor: String) -> ReplayEntry {
        let number: Int = row["number"]
        return ReplayEntry(at: row["createdAt"], kind: .ask, actor: actor,
                           text: flatten("A-\(number) \(row["kind"] as String) (\(row["status"] as String)): \(row["title"] as String)"),
                           ref: "A-\(number)")
    }

    private static func kbLine(_ row: Row, actor: String) -> ReplayEntry {
        let path: String = row["path"], number: Int = row["number"]
        let what = (row["summary"] as String?).flatMap { $0.isEmpty ? nil : $0 } ?? (row["diffSummary"] as String)
        return ReplayEntry(at: row["createdAt"], kind: .handbook, actor: actor, text: flatten("kb:\(path) rev \(number): \(what)"),
                           ref: "kb:\(path)")
    }

    /// A resource row as it stands: a purged one by its ref only, a link by its ref only (its address is its content).
    private static func resourceLine(_ row: Row) -> ReplayEntry {
        let number: Int = row["number"], kind: String = row["kind"]
        let text: String
        if (row["purgedAt"] as Date?) != nil {
            text = "[purged F-\(number)]"
        } else if kind == ResourceKind.link.rawValue {
            text = "F-\(number) link"
        } else {
            text = "F-\(number) \(kind) \(row["displayName"] as String)" + ((row["removedAt"] as Date?) != nil ? " (removed)" : "")
        }
        return ReplayEntry(at: row["createdAt"], kind: .resource, actor: "owner", text: flatten(text), ref: "F-\(number)")
    }

    private static func eventText(_ text: String) -> String { text.isEmpty ? "" : ": " + text }

    private static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    /// Whether `text` names `key` as a whole key: not preceded by a key character, not followed by a digit.
    static func names(_ text: String, key: String) -> Bool {
        let hay = text.uppercased(), needle = key.uppercased()
        var start = hay.startIndex
        while let r = hay.range(of: needle, range: start..<hay.endIndex) {
            let before = r.lowerBound == hay.startIndex ? nil : hay[hay.index(before: r.lowerBound)]
            let after = r.upperBound == hay.endIndex ? nil : hay[r.upperBound]
            let okBefore = before.map { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } ?? true
            let okAfter = after.map { !$0.isNumber } ?? true
            if okBefore && okAfter { return true }
            start = r.upperBound
        }
        return false
    }
}
