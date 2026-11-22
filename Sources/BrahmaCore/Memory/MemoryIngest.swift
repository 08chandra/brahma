import Foundation
import GRDB

/// Auto-ingest (Plan ML): the tick step that indexes a company's messages, items, asks, decisions, hand-offs and retros.
///
/// Each source reads from its `memoryCursor` row, upserts its docs and advances the cursor in one write transaction per batch
/// of `batch` rows. Cursors are restore-safe: an INTEGER autoincrement id (`VACUUM` keeps it), or `"<ISO-8601 ms>|<id>"`
/// read as `(ts, id) > cursor`, never the rowid of a TEXT-keyed table. A pair source re-reads an `overlap` window before its
/// cursor on each run (rows whose timestamp committed late), which `ingest`'s equality skip makes cheap. An empty or
/// unreadable cursor is a full re-scan, idempotent; the restore hook (`resetCursors`) sets every cursor to `""`.
///
/// The mapping (refs, engine-built titles, access and sensitivity) is the plan's table. Agent-written text is only ever body
/// text. A message, comment, submit summary or hand-off (and an ask or decision) written by an agent whose session was
/// tainted then (`Store.taintAt`), or carrying a tainted-origin mark, is indexed `tainted`.
public enum MemoryIngest {
    public static let batch = 500
    public static let overlap: TimeInterval = 60
    /// At most this many batches per source per run, so a full re-scan never holds a tick; the rest follows next tick.
    static let maxBatchesPerRun = 20
    /// The most of a hand-off file that is indexed, in bytes.
    public static let maxHandoffBytes = 65_536
    /// An item's body holds its newest this-many comments.
    public static let itemComments = 50

    /// The `memoryCursor.source` of each cursor.
    enum Cursor: String, CaseIterable {
        case message, item, itemEvent, ask, decision, handoff, retro
    }

    /// Indexes everything new in the company since its cursors. Every source is tried; the first error is rethrown after the
    /// others ran (a source that failed keeps its cursor and is retried next tick). Returns how many docs were upserted
    /// (unchanged ones included).
    @discardableResult
    public static func run(store: Store, companyId: String, paths: BrahmaPaths, now: Date) throws -> Int {
        var total = 0
        var failure: (any Error)?
        let steps: [(Store, String, Date) throws -> Int] = [messages, items, itemEvents, asks, decisions, handoffs, retros]
        for step in steps {
            do { total += try step(store, companyId, now) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
        return total
    }

    /// After a restore (`RestoreHooks.afterRestore`): every `memoryCursor` row, of every company, back to `""`, a full
    /// idempotent re-scan. A restore swaps the whole database, so no company's cursor is kept.
    public static func resetCursors(store: Store) throws {
        try store.writer.write { db in try db.execute(sql: "UPDATE memoryCursor SET position = ''") }
    }

    /// The stored cursor, `""` when none.
    static func position(db: Database, companyId: String, _ cursor: Cursor) throws -> String {
        try String.fetchOne(db, sql: "SELECT position FROM memoryCursor WHERE companyId = ? AND source = ?",
                            arguments: [companyId, cursor.rawValue]) ?? ""
    }

    static func setPosition(db: Database, companyId: String, _ cursor: Cursor, _ position: String) throws {
        try db.execute(sql: """
            INSERT INTO memoryCursor (companyId, source, position) VALUES (?, ?, ?)
            ON CONFLICT(companyId, source) DO UPDATE SET position = excluded.position
            """, arguments: [companyId, cursor.rawValue, position])
    }

    // MARK: Cursor forms

    /// `"<ISO-8601 ms>|<id>"` from a stored timestamp (GRDB's `yyyy-MM-dd HH:mm:ss.SSS`, UTC) and an id.
    static func pair(storedTs: String, id: String) -> String {
        "\(storedTs.replacingOccurrences(of: " ", with: "T"))Z|\(id)"
    }

    /// A pair cursor back as the stored timestamp text and the id; nil for `""` or anything unreadable (a full re-scan).
    static func parsePair(_ position: String) -> (ts: String, id: String)? {
        guard let bar = position.firstIndex(of: "|") else { return nil }
        var iso = String(position[..<bar])
        guard iso.hasSuffix("Z"), iso.contains("T") else { return nil }
        iso.removeLast()
        let ts = iso.replacingOccurrences(of: "T", with: " ")
        guard storedDate(ts) != nil else { return nil }
        return (ts, String(position[position.index(after: bar)...]))
    }

    /// A stored timestamp as a date (GRDB's own decoding), or nil.
    static func storedDate(_ ts: String) -> Date? { Date.fromDatabaseValue(ts.databaseValue) }

    // MARK: Drivers

    /// A `(ts, id)` source. `select` names its rows' `cursorTs` and `cursorId` and ends in a `WHERE` with `companyId = ?` as
    /// its only argument; `ts`/`id` are the column expressions behind them. The first batch of a run starts `overlap` before
    /// the cursor; later ones strictly after it.
    ///
    /// An idle source opens no write transaction. The check is a read: work is due when the cursor is empty or unreadable
    /// (and the source has rows), when a row is strictly after the cursor, or while the overlap window is still open on the
    /// engine's clock (`now < cursorTs + overlap`: a row stamped up to `overlap` before the cursor may still commit late).
    /// Once the window has closed and nothing is newer, the tick costs one indexed read.
    static func pairSource(store: Store, companyId: String, cursor: Cursor, select: String, ts: String, id: String,
                           now: Date, process: (Batch, [Row]) throws -> Int) throws -> Int {
        func fetch(_ db: Database, overlapped: Bool, limit: Int) throws -> [Row] {
            let stored = try position(db: db, companyId: companyId, cursor)
            guard let at = parsePair(stored) else {
                return try Row.fetchAll(db, sql: "\(select) ORDER BY \(ts), \(id) LIMIT ?", arguments: [companyId, limit])
            }
            if overlapped, let date = storedDate(at.ts) {
                return try Row.fetchAll(db, sql: "\(select) AND \(ts) >= ? ORDER BY \(ts), \(id) LIMIT ?",
                                        arguments: [companyId, date.addingTimeInterval(-overlap), limit])
            }
            return try Row.fetchAll(db, sql: "\(select) AND (\(ts) > ? OR (\(ts) = ? AND \(id) > ?)) ORDER BY \(ts), \(id) LIMIT ?",
                                    arguments: [companyId, at.ts, at.ts, at.id, limit])
        }
        func workDue(_ db: Database) throws -> Bool {
            if let at = parsePair(try position(db: db, companyId: companyId, cursor)), let date = storedDate(at.ts),
               now < date.addingTimeInterval(overlap) {
                return true
            }
            // Strictly after the cursor (every row, for an empty or unreadable one).
            return try !fetch(db, overlapped: false, limit: 1).isEmpty
        }
        // Nothing new and the overlap window closed: no write transaction.
        guard try store.writer.read({ db in try workDue(db) }) else { return 0 }
        var total = 0
        for n in 0..<maxBatchesPerRun {
            let (count, done) = try store.writer.write { db -> (Int, Bool) in
                let rows = try fetch(db, overlapped: n == 0, limit: batch)
                let upserted = try process(Batch(db: db, store: store, companyId: companyId, now: now), rows)
                let old = parsePair(try position(db: db, companyId: companyId, cursor))
                var newest = old
                for row in rows {
                    let rowTs: String = row["cursorTs"], rowId: String = row["cursorId"]
                    if let current = newest, (current.ts, current.id) >= (rowTs, rowId) { continue }
                    newest = (rowTs, rowId)
                }
                if let newest, old.map({ $0 != newest }) ?? true {
                    try setPosition(db: db, companyId: companyId, cursor, pair(storedTs: newest.ts, id: newest.id))
                }
                return (upserted, rows.count < batch)
            }
            total += count
            if done { break }
        }
        return total
    }

    /// An INTEGER-id source: rows with `id > cursor`, up to the table's newest id when the read began (so a filtered source
    /// never rescans the rows it skipped). `select` ends in a `WHERE` with `companyId = ?` as its only argument.
    ///
    /// An idle source opens no write transaction. The check is a read: work is due when a row of the company's selection is
    /// after the cursor, or when the table has moved `batch` ids past it (other companies' rows, filtered-out rows), which
    /// moves the cursor up so the read's range stays short. Otherwise the cursor stays put and the tick costs one read.
    static func idSource(store: Store, companyId: String, cursor: Cursor, table: String, select: String, now: Date,
                         process: (Batch, [Row]) throws -> Int) throws -> Int {
        func bounds(_ db: Database) throws -> (after: Int64, upTo: Int64) {
            let after = Int64(try position(db: db, companyId: companyId, cursor)) ?? 0
            // The table's newest id (its primary key: no scan); the range read below is bound to the company.
            let upTo = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM \(table)") ?? 0
            return (after, upTo)
        }
        let due = try store.writer.read { db -> Bool in
            let b = try bounds(db)
            guard b.upTo > b.after else { return false }
            if b.upTo - b.after >= Int64(batch) { return true }
            return try Row.fetchOne(db, sql: "\(select) AND id > ? AND id <= ? LIMIT 1", arguments: [companyId, b.after, b.upTo]) != nil
        }
        guard due else { return 0 }
        var total = 0
        for _ in 0..<maxBatchesPerRun {
            let (count, done) = try store.writer.write { db -> (Int, Bool) in
                let b = try bounds(db)
                guard b.upTo > b.after else { return (0, true) }
                let rows = try Row.fetchAll(db, sql: "\(select) AND id > ? AND id <= ? ORDER BY id LIMIT ?",
                                            arguments: [companyId, b.after, b.upTo, batch])
                let upserted = try process(Batch(db: db, store: store, companyId: companyId, now: now), rows)
                let full = rows.count == batch
                let next: Int64 = full ? rows.last?["id"] ?? b.upTo : b.upTo
                try setPosition(db: db, companyId: companyId, cursor, String(next))
                return (upserted, !full)
            }
            total += count
            if done { break }
        }
        return total
    }

    // MARK: Sources

    static func messages(store: Store, companyId: String, now: Date) throws -> Int {
        try pairSource(store: store, companyId: companyId, cursor: .message, select: """
            SELECT m.createdAt AS cursorTs, m.id AS cursorId, m.*, c.name AS channelName, c.kind AS channelKind
            FROM message m JOIN channel c ON c.id = m.channelId WHERE m.companyId = ?
            """, ts: "m.createdAt", id: "m.id", now: now) { batch, rows in
            for row in rows {
                let message = try Message(row: row)
                let channelName: String = row["channelName"], dm = (row["channelKind"] as String) == ChannelKind.dm.rawValue
                let time = stamp(message.createdAt, zone: batch.zone)
                let title: String
                if dm {
                    let parties = channelName.split(separator: ":").dropFirst().map { "@\($0)" }.joined(separator: " · ")
                    title = "DM \(parties) \(time)"
                } else {
                    title = "#\(channelName) @\(try batch.handle(message.senderId)) \(time)"
                }
                // C3b: the session's own stamp (`fromTaintedSession`) taints it too, OR-ed with ML's `taintAt`.
                let taint = try batch.taint(author: message.senderId, at: message.createdAt, marked: message.taintedOrigin,
                                            session: message.fromTaintedSession ? message.taintSource ?? "outside content" : nil)
                // C3b: the most sensitive of the refs it carries (written in its post's transaction), never below normal.
                let carried = try refSensitivity(batch.db, companyId: companyId, messageId: message.id)
                try batch.ingest(MemoryIngestDoc(
                    companyId: companyId, source: .message, sourceId: message.id, ref: "msg:\(message.id)", title: title,
                    body: message.text, access: dm ? .dm(message.channelId) : .channel(message.channelId),
                    sensitivity: carried.sensitivity, restrictions: carried.restrictions,
                    provenance: batch.provenance(message.senderId), tainted: taint != nil, taintReason: taint,
                    authorId: message.senderId, createdAt: message.createdAt))
            }
            return rows.count
        }
    }

    /// Plan C Task C3b: the sensitivity a message takes from its `messageRef` rows: the maximum of theirs (never below
    /// `normal`), and when that is `restricted`, the restrictions of every restricted row, each kept (every one must be
    /// satisfied). A row whose sensitivity or restrictions can't be read makes the message `secret` (owner only; fail closed).
    static func refSensitivity(_ db: Database, companyId: String, messageId: String) throws -> (sensitivity: Sensitivity, restrictions: [Restriction]) {
        let rows = try Row.fetchAll(db, sql: "SELECT sensitivity, restrictions FROM messageRef WHERE companyId = ? AND messageId = ?",
                                    arguments: [companyId, messageId])
        var max = Sensitivity.normal
        var parsed: [(Sensitivity, [Restriction])] = []
        for row in rows {
            guard let s = Sensitivity(rawValue: row["sensitivity"]),
                  let r = try? JSONDecoder().decode([[String]].self, from: Data((row["restrictions"] as String).utf8)) else {
                return (.secret, [])
            }
            parsed.append((s, r.map(Set.init)))
            if s > max { max = s }
        }
        guard max == .restricted else { return (max, []) }
        var restrictions: [Restriction] = []
        for (s, r) in parsed where s == .restricted {
            for one in r where !restrictions.contains(one) { restrictions.append(one) }
        }
        return (max, restrictions)
    }

    static func items(store: Store, companyId: String, now: Date) throws -> Int {
        try pairSource(store: store, companyId: companyId, cursor: .item, select: """
            SELECT w.createdAt AS cursorTs, w.id AS cursorId FROM workItem w WHERE w.companyId = ?
            """, ts: "w.createdAt", id: "w.id", now: now) { batch, rows in
            for row in rows { try ingestItem(batch, itemId: row["cursorId"]) }
            return rows.count
        }
    }

    /// Every new item event re-ingests its item (once per batch).
    static func itemEvents(store: Store, companyId: String, now: Date) throws -> Int {
        try idSource(store: store, companyId: companyId, cursor: .itemEvent, table: "workItemEvent",
                     select: "SELECT id, itemId FROM workItemEvent WHERE companyId = ?", now: now) { batch, rows in
            var seen = Set<String>()
            for row in rows {
                let itemId: String = row["itemId"]
                guard seen.insert(itemId).inserted else { continue }
                try ingestItem(batch, itemId: itemId)
            }
            return seen.count
        }
    }

    /// One item: `<KEY> <title>`, its description, acceptance criteria, submit summary and newest `itemComments` comments.
    static func ingestItem(_ batch: Batch, itemId: String) throws {
        let db = batch.db
        guard let item = try WorkItem.fetchOne(db, key: itemId), item.companyId == batch.companyId else { return }
        let events = try WorkItemEvent.filter(Column("itemId") == item.id).order(Column("id")).fetchAll(db)
        let comments = events.filter { $0.kind == .commented }.suffix(itemComments)
        var parts: [String] = []
        if !item.description.isEmpty { parts.append(item.description) }
        if !item.acceptanceCriteria.isEmpty { parts.append("Acceptance criteria:\n" + item.acceptanceCriteria) }
        if let s = item.submitSummary, !s.isEmpty { parts.append(s) }
        parts += comments.map(\.text)

        // The first tainted writer found names the reason.
        var taint = try batch.taint(author: item.authorId, at: item.createdAt, marked: false)
        if taint == nil, item.submitSummary?.isEmpty == false, let submit = events.last(where: { $0.kind == .submitted }) {
            taint = try batch.taint(author: submit.actorId, at: submit.createdAt, marked: submit.taintedOrigin)
        }
        for comment in comments where taint == nil {
            taint = try batch.taint(author: comment.actorId, at: comment.createdAt, marked: comment.taintedOrigin)
        }
        if taint == nil, item.taintedOrigin { taint = Batch.reason("outside content") }

        try batch.ingest(MemoryIngestDoc(
            companyId: batch.companyId, source: .item, sourceId: item.id, ref: MemoryRefs.canonicalItemRef(item.key),
            title: "\(item.key) \(item.title)", body: parts.joined(separator: "\n\n"), access: .company,
            provenance: batch.provenance(item.authorId), tainted: taint != nil, taintReason: taint, authorId: item.authorId,
            itemId: item.id, createdAt: item.createdAt))
    }

    /// Each ask is two docs: the requester's party (an engine ask is the owner's alone) and the owner's own part.
    static func asks(store: Store, companyId: String, now: Date) throws -> Int {
        try pairSource(store: store, companyId: companyId, cursor: .ask, select: """
            SELECT a.updatedAt AS cursorTs, a.id AS cursorId, a.* FROM ask a WHERE a.companyId = ?
            """, ts: "a.updatedAt", id: "a.id", now: now) { batch, rows in
            var count = 0
            for row in rows {
                let ask = try Ask(row: row)
                var lines: [String] = []
                func add(_ s: String?) { if let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.append(s) } }
                add(ask.summary)
                add(ask.payload?.question)
                add(ask.payload?.proposal)
                for o in ask.payload?.options ?? [] { add("\(o.label): \(o.pros) / \(o.cons)") }
                add(ask.payload?.recommendation)
                add(ask.decidedBy.map { "\(ask.status.rawValue) by \($0)" } ?? ask.status.rawValue)
                add(ask.internalNote)

                let system = ask.requesterId == "system"
                let scope = try askScope(ask) { try batch.agentId(handle: $0) }
                let taint = system ? nil : try batch.taint(author: ask.requesterId, at: ask.createdAt, marked: false)
                try batch.ingest(MemoryIngestDoc(
                    companyId: companyId, source: .ask, sourceId: ask.id, ref: ask.ref,
                    title: "\(ask.ref) \(ask.kind.title): \(ask.title)", body: lines.joined(separator: "\n"),
                    access: scope.access, readerSet: scope.readerSet,
                    sensitivity: scope.sensitivity, restrictions: scope.restrictions, provenance: batch.provenance(ask.requesterId),
                    tainted: taint != nil, taintReason: taint, authorId: ask.requesterId, itemId: ask.itemId, createdAt: ask.createdAt))
                count += 1

                // The owner's answer and note: the owner's alone (the requester has the answer as its DM, indexed as a dm).
                let owner = [ask.ownerAnswer, ask.ownerNote].compactMap { $0 }
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if !owner.isEmpty {
                    try batch.ingest(MemoryIngestDoc(
                        companyId: companyId, source: .ask, sourceId: "\(ask.id)#owner", ref: ask.ref,
                        title: "\(ask.ref) owner note", body: owner.joined(separator: "\n"), access: .ownerOnly,
                        provenance: .owner, authorId: "owner", itemId: ask.itemId, createdAt: ask.ownerDecidedAt ?? ask.updatedAt))
                    count += 1
                }
            }
            return count
        }
    }

    /// Who may read an ask: an engine-raised ask is the owner's alone; any other is its requester's, read by the reader set of
    /// requester, internal approver and the agent that decided it (`@<handle>`, resolved by `agentId`). `termination` is
    /// `hr-perf`, `exec-staffing` restricted to executives. The handbook's Decisions log applies the same scope (Task 5).
    struct AskScope: Equatable {
        var access: AccessClass
        var readerSet: Set<String>?
        var sensitivity: Sensitivity
        var restrictions: [Restriction]
    }

    static func askScope(_ ask: Ask, agentId: (String) throws -> String?) rethrows -> AskScope {
        let system = ask.requesterId == "system"
        var readers: Set<String> = [ask.requesterId]
        if let approver = ask.internalApproverId { readers.insert(approver) }
        if let decided = ask.decidedBy, decided.hasPrefix("@"), let id = try agentId(String(decided.dropFirst())) {
            readers.insert(id)
        }
        var sensitivity = Sensitivity.normal
        var restrictions: [Restriction] = []
        switch ask.category {
        case "termination"?: sensitivity = .hrPerf
        case "exec-staffing"?: sensitivity = .restricted; restrictions = [["@executive"]]
        default: break
        }
        return AskScope(access: system ? .ownerOnly : .agent(ask.requesterId), readerSet: system ? nil : readers,
                        sensitivity: sensitivity, restrictions: restrictions)
    }

    /// Mechanical decisions: the `approval` activity lines `Recorded: …`.
    ///
    /// The author (and so the provenance) is the requester `Store.recordMechanicalDecision` wrote: the line's `agentId` when
    /// an agent recorded it. Without one, the engine-built `Recorded: <kind> by @<handle>: ` head names the requester, read
    /// before the agent-written title: `@owner` is the owner (`.owner`), anything else the engine (`system`, `.engine`).
    /// Today only `Sender.system` writes a line without an agent (the owner files no asks), so that is `.engine`.
    static func decisions(store: Store, companyId: String, now: Date) throws -> Int {
        let prefix = "Recorded: "
        return try idSource(store: store, companyId: companyId, cursor: .decision, table: "activityEvent", select: """
            SELECT id, agentId, text, createdAt FROM activityEvent
            WHERE companyId = ? AND kind = 'approval' AND substr(text, 1, \(prefix.count)) = '\(prefix)'
            """, now: now) { batch, rows in
            for row in rows {
                let id: Int64 = row["id"], text: String = row["text"], createdAt: Date = row["createdAt"]
                let agentId: String? = row["agentId"]
                let author = agentId ?? decisionAuthor(text: text, prefix: prefix)
                let taint = try batch.taint(author: author, at: createdAt, marked: false)
                try batch.ingest(MemoryIngestDoc(
                    companyId: companyId, source: .decision, sourceId: String(id), ref: "decision:\(id)",
                    title: "Recorded decision \(stamp(createdAt, zone: batch.zone, format: "yyyy-MM-dd"))",
                    body: String(text.dropFirst(prefix.count)), access: .company, provenance: batch.provenance(author),
                    tainted: taint != nil, taintReason: taint, authorId: author, createdAt: createdAt))
            }
            return rows.count
        }
    }

    /// The requester of an agent-less `Recorded: <kind> by @<handle>: <title>` line: `owner` or `system`.
    static func decisionAuthor(text: String, prefix: String) -> String {
        let head = text.dropFirst(prefix.count)
        guard let by = head.range(of: " by @"), let colon = head[by.upperBound...].firstIndex(of: ":") else { return "system" }
        return head[by.upperBound..<colon] == "owner" ? "owner" : "system"
    }

    /// Hand-off files, read only through `EngineFiles.readNoFollow` under `<ws>/.brahma/handoffs`: a link, a hard link, a file
    /// that is not regular or a swapped directory is skipped with one activity line.
    static func handoffs(store: Store, companyId: String, now: Date) throws -> Int {
        try pairSource(store: store, companyId: companyId, cursor: .handoff, select: """
            SELECT h.createdAt AS cursorTs, h.id AS cursorId, h.*, w.key AS itemKey
            FROM handoff h JOIN workItem w ON w.id = h.itemId WHERE h.companyId = ?
            """, ts: "h.createdAt", id: "h.id", now: now) { batch, rows in
            guard !rows.isEmpty, let company = try Company.fetchOne(batch.db, key: companyId) else { return 0 }
            let root = URL(fileURLWithPath: company.workspacePath, isDirectory: true).appending(path: ".brahma/handoffs", directoryHint: .isDirectory)
            var count = 0
            for row in rows {
                let handoff = try Handoff(row: row)
                let key: String = row["itemKey"]
                let url = URL(fileURLWithPath: handoff.path)
                guard let data = EngineFiles.readNoFollow(url, under: root, limit: maxHandoffBytes) else {
                    try batch.noteOnce("skipped hand-off \(handoff.path): not a regular single-link file inside .brahma/handoffs")
                    continue
                }
                let taint = try batch.taint(author: handoff.authorId, at: handoff.createdAt, marked: handoff.taintedOrigin)
                try batch.ingest(MemoryIngestDoc(
                    companyId: companyId, source: .handoff, sourceId: handoff.id, ref: "handoff:\(key)/\(url.lastPathComponent)",
                    title: "Hand-off \(key) from @\(try batch.handle(handoff.authorId)) \(stamp(handoff.createdAt, zone: batch.zone, format: "yyyy-MM-dd"))",
                    body: String(decoding: data, as: UTF8.self), access: .company,
                    provenance: handoff.auto ? .engine : batch.provenance(handoff.authorId), tainted: taint != nil,
                    taintReason: taint, authorId: handoff.authorId, itemId: handoff.itemId, createdAt: handoff.createdAt))
                count += 1
            }
            return count
        }
    }

    /// Closed sprints' summaries.
    static func retros(store: Store, companyId: String, now: Date) throws -> Int {
        try pairSource(store: store, companyId: companyId, cursor: .retro, select: """
            SELECT s.closedAt AS cursorTs, s.id AS cursorId, s.* FROM sprint s
            WHERE s.companyId = ? AND s.status = 'closed' AND s.closedAt IS NOT NULL
            """, ts: "s.closedAt", id: "s.id", now: now) { batch, rows in
            var count = 0
            for row in rows {
                let sprint = try Sprint(row: row)
                guard let summary = sprint.summary, !summary.isEmpty, let closedAt = sprint.closedAt else { continue }
                let taint = try retroTaint(sprint, closedAt: closedAt) { try batch.taint(author: $0, at: closedAt, marked: false) }
                try batch.ingest(MemoryIngestDoc(
                    companyId: companyId, source: .retro, sourceId: sprint.id, ref: "sprint:\(sprint.number)",
                    title: "\(sprint.name) retro", body: summary, access: .company,
                    provenance: sprint.closedById.map(batch.provenance) ?? sprint.leadId.map { .agent($0) } ?? .engine,
                    tainted: taint != nil, taintReason: taint, authorId: sprint.closedById ?? sprint.leadId, createdAt: closedAt))
                count += 1
            }
            return count
        }
    }

    /// The reason a sprint's summary is untrusted, or nil: its closer (who wrote it) was in a tainted session at `closedAt`
    /// (`taint`); a sprint closed before the closer was recorded has an unknown author, which is untrusted.
    static func retroTaint(_ sprint: Sprint, closedAt: Date, taint: (String) throws -> String?) rethrows -> String? {
        guard let closer = sprint.closedById else { return unknownRetroAuthor }
        // The owner and the engine are never tainted.
        guard closer != "owner", closer != "system", !closer.isEmpty else { return nil }
        return try taint(closer)
    }

    static let unknownRetroAuthor = "written by an author the engine did not record"

    // MARK: Helpers

    /// What one batch's transaction looks up more than once: handles, the owner's time zone and each author's taint history.
    final class Batch {
        let db: Database
        let store: Store
        let companyId: String
        let now: Date
        private var handles: [String: String]?
        private var histories: [String: TaintHistory] = [:]
        private(set) lazy var zone: TimeZone = MemoryIngest.ownerZone(db: db)

        init(db: Database, store: Store, companyId: String, now: Date) {
            self.db = db; self.store = store; self.companyId = companyId; self.now = now
        }

        func ingest(_ doc: MemoryIngestDoc) throws { try store.ingest(db: db, doc, now: now) }

        private func agentHandles() throws -> [String: String] {
            if let handles { return handles }
            var map: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, name FROM agent WHERE companyId = ?", arguments: [companyId]) {
                map[row["id"]] = row["name"]
            }
            handles = map
            return map
        }

        /// `owner`, `system`, an agent's handle, or `unknown`.
        func handle(_ id: String) throws -> String {
            if id == "owner" || id == "system" { return id }
            return try agentHandles()[id] ?? "unknown"
        }

        func agentId(handle: String) throws -> String? {
            try agentHandles().first { $0.value == handle }?.key
        }

        func provenance(_ id: String) -> Provenance {
            switch id {
            case "owner": .owner
            case "system", "": .engine
            default: .agent(id)
            }
        }

        static func reason(_ source: String) -> String { "written by a session that read \(source)" }

        /// The taint reason for text `author` wrote at `at`, or nil. The owner and the engine are never tainted; a text that
        /// carries a tainted-origin mark (`marked`) is, whatever its author's turns say.
        /// `session` (C3b): the source the text's own stamp names (a message's `fromTaintedSession`), used when the history
        /// has none.
        func taint(author: String, at: Date, marked: Bool, session: String? = nil) throws -> String? {
            var source: String?
            if author != "owner", author != "system", !author.isEmpty {
                if histories[author] == nil { histories[author] = try TaintHistory.load(db: db, agentId: author) }
                source = histories[author]?.taint(at: at)
            }
            if source == nil, let session { source = session }
            if source == nil, marked { source = "outside content" }
            return source.map(Self.reason)
        }

        /// One activity line per distinct text in the company: a skipped file stays skipped on every re-read.
        func noteOnce(_ text: String) throws {
            let text = String(text.prefix(500))
            guard try !Bool(exists: db, sql: "SELECT 1 FROM activityEvent WHERE companyId = ? AND text = ? LIMIT 1",
                            arguments: [companyId, text]) else { return }
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .error, text: text, createdAt: now).insert(db)
        }
    }

    /// The owner's time zone, read in the caller's transaction (`Store.ownerTimeZone()` opens its own).
    static func ownerZone(db: Database) -> TimeZone {
        let id = try? String.fetchOne(db, sql: "SELECT timeZone FROM ownerSettings WHERE id = 1")
        return id.flatMap { TimeZone(identifier: $0) } ?? .current
    }

    /// Calendar text in the owner's zone (`yyyy-MM-dd HH:mm` by default).
    static func stamp(_ date: Date, zone: TimeZone, format: String = "yyyy-MM-dd HH:mm") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = zone
        f.dateFormat = format
        return f.string(from: date)
    }
}

private extension Bool {
    init(exists db: Database, sql: String, arguments: StatementArguments) throws {
        self = try Row.fetchOne(db, sql: sql, arguments: arguments) != nil
    }
}
