import Foundation
import GRDB

/// Plan C Task C4c: the lifecycle numbers of owner show requests (design §2.4; durations in company-active seconds).
public enum ShowLifecycle {
    /// The same query to the same target within this many active seconds reuses the open request.
    public static let dedupeWindow: Double = 600
    public static let maxOpenPerTarget = 2
    /// An open request expires after this many active seconds.
    public static let expiry: Double = 3600
    /// Runaway guard per owner-time-zone day (not shown unless it binds).
    public static let conciergePerDay = 60
    public static let agentPerDay = 20
}

/// The `show` tool's limits (global constraints' pinned numbers).
public enum ShowLimits {
    public static let maxRefs = 6
    public static let noteMax = 600
    public static let refNoteMax = 280
    /// What a note (or a per-ref note) holding a stored value is stored as: never part of it.
    public static let withheldNote = "(withheld: it held a stored secret)"
}

public enum ShowRequestStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case open, answered, expired, cancelled
}

/// One owner show or explain request (`showRequest`, migration `vC-show`): one property per column.
public struct ShowRequest: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "showRequest"

    public var id: String
    public var companyId: String
    /// Per company, from the monotonic allocator (`RefCounterKind.showRequest`).
    public var number: Int
    public var kind: ShowKind
    /// The owner's query, normalized (`ShowQuery`, at most 300 characters).
    public var query: String
    /// The canonical ref an "Ask to explain" was made on.
    public var attachedRef: String?
    /// `concierge` or `agent`.
    public var target: String
    public var targetAgentId: String?
    /// `owner` (an `@handle` the owner chose) or `rule` (`ShowRouting`).
    public var routedBy: String
    public var reason: String
    /// JSON array of the candidate one-liners, already filtered for the target (`ShowCandidates.lines`).
    public var candidates: String
    public var status: ShowRequestStatus
    public var answerMessageId: String?
    /// The agent's `.show` turn that took it (nil for the concierge, which has no turn row).
    public var turnId: String?
    public var costUSD: Double?
    /// Percent of the five-hour window (`costUSD` × the 5H calibration).
    public var costShare5h: Double?
    public var autoOpenedAt: Date?
    public var createdAt: Date
    public var createdActive: Double
    /// C4c fix round 1 (M3): the owner's DM that carried an agent target's request; a DM answers the request only as a reply
    /// in its thread.
    public var requestMessageId: String? = nil

    public var showTarget: ShowTarget { targetAgentId.map(ShowTarget.agent) ?? .concierge }

    /// The stored candidate lines.
    public var candidateLines: [String] { (try? JSONDecoder().decode([String].self, from: Data(candidates.utf8))) ?? [] }
}

/// The Show bar's misses: a query nothing answered, and what the owner did then (`ask` or `none`).
struct ShowMiss: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "showMiss"
    var id: String
    var companyId: String
    var query: String
    var chosen: String
    var topScore: Double?
    var createdAt: Date
}

/// An answer the app should open in the OPENED slot (once): an answered request the owner made, with its refs.
public struct AutoOpen: Equatable, Sendable {
    public var requestId: String
    public var answerMessageId: String
    public var refs: [WorkRef]
    /// `"Brahma"` or `"@<handle>"`.
    public var by: String
    /// Ruling C7a-1: the request went to Brahma's concierge (the engine's routing, never a name): only then is the answer
    /// labelled "Concierge".
    public var concierge: Bool = false
}

/// The Budget view's one "owner requests" line: what show requests cost, as shares of the windows (percent).
public struct OwnerRequestUsage: Equatable, Sendable {
    public var share5h: Double
    public var share7d: Double
}

/// What an Ask is expected to cost, in percent of the five-hour window (the ASK row's `~0.1% of 5H`).
public enum ShowCost {
    public static let defaults = (concierge: 0.1, agent: 1.0)
    static let window = 20
    /// The 5H share per dollar used before the calibration has samples (fraction of the window per dollar), so a cost
    /// can still be capped and shown. Conservative: a dollar counts as 2.5% of the window.
    public static let fallbackPerDollar5h = 0.025

    /// The mean cost of the last 20 answered requests of that target type × the 5H calibration, else the default.
    public static func estimate(_ t: ShowTarget, store: Store, companyId: String) throws -> Double {
        let type = t == .concierge ? "concierge" : "agent"
        let costs = try store.writer.read { db in
            try Double.fetchAll(db, sql: """
                SELECT costUSD FROM showRequest WHERE companyId = ? AND target = ? AND status = 'answered' AND costUSD IS NOT NULL
                ORDER BY createdAt DESC, rowid DESC LIMIT ?
                """, arguments: [companyId, type, window])
        }
        let fallback = t == .concierge ? defaults.concierge : defaults.agent
        guard !costs.isEmpty, let per = try store.usageCalibration().pctPerDollar5h else { return fallback }
        return costs.reduce(0, +) / Double(costs.count) * per * 100
    }

    /// Percent of the five-hour window `usd` is (the calibration, else `fallbackPerDollar5h`).
    public static func share5h(_ usd: Double, calibration: UsageCalibration) -> Double {
        usd * (calibration.pctPerDollar5h ?? fallbackPerDollar5h) * 100
    }
}

/// The waiting chip's text for an agent target (design §2.3).
public enum ShowETA {
    /// The moving average of the agent's last `window` turn durations.
    public static let window = 10

    /// `"held: usage limit until 14:30"` while the gate binds; `"queued: after @eng-3's current turn (~6 min)"` while the
    /// agent runs (the average of its recent turn durations, in seconds); else `"next up"`.
    public static func text(agent: Agent, running: Turn?, recentDurations: [Double], gate: UsageGate.Status, now: Date,
                            tz: TimeZone) -> String {
        if case .closed(let until) = gate, until > now {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = tz
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            f.dateFormat = cal.isDate(until, inSameDayAs: now) ? "HH:mm" : "yyyy-MM-dd HH:mm"
            return "held: usage limit until \(f.string(from: until))"
        }
        guard running != nil || agent.state == .running else { return "next up" }
        let recent = recentDurations.suffix(window).filter { $0.isFinite && $0 >= 0 }
        guard !recent.isEmpty else { return "queued: after @\(agent.name)'s current turn" }
        let minutes = max(1, Int((recent.reduce(0, +) / Double(recent.count) / 60).rounded()))
        return "queued: after @\(agent.name)'s current turn (~\(minutes) min)"
    }
}

extension UsageGate {
    /// The gate as the waiting chip reads it.
    public typealias Status = UsageDecision
}

extension Store {
    // MARK: Requests

    /// Records an owner request routed to `routed` (`ShowRouting.target`) with its candidates already filtered for that target
    /// (`ShowCandidates.lines`). Within one write transaction: the same query to the same target within
    /// `ShowLifecycle.dedupeWindow` active seconds returns the open request; a target with `maxOpenPerTarget` open requests is
    /// refused (`"@<h> already has 2 open requests; wait or cancel one"`); the runaway guard refuses past the day's limit
    /// (`"Brahma has answered 60 requests today; try again tomorrow"`, `"agents have answered 20 requests today; try again
    /// tomorrow"`). An agent target also gets the owner's DM (`kind = showRequest`), which wakes it as any owner DM does.
    @discardableResult
    public func createShowRequest(companyId: String, kind: ShowKind, query: String, attachedRef: String?, routed: RoutedTarget,
                                  candidates: [String], now: Date) throws -> ShowRequest {
        let normalized = ShowQuery.normalize(query).normalized
        let encoded = String(decoding: try JSONEncoder().encode(candidates), as: UTF8.self)
        let tz = ownerTimeZone()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let dayStart = cal.startOfDay(for: now)
        let router = MessageRouter(store: self)
        return try writer.write { db in
            guard try Company.fetchOne(db, key: companyId) != nil else { throw WorkError.notFound("no such company") }
            let active = try Store.activeNow(db: db, companyId: companyId)
            let type: String, agentId: String?, who: String
            switch routed.target {
            case .concierge:
                (type, agentId, who) = ("concierge", nil, "Brahma")
            case .agent(let id):
                guard let a = try Agent.fetchOne(db, sql: "SELECT * FROM agent WHERE companyId = ? AND id = ?", arguments: [companyId, id]),
                      a.state != .killed else { throw WorkError.notFound("that agent isn't in the company") }
                (type, agentId, who) = ("agent", a.id, "@" + a.name)
            }
            let open = try ShowRequest.fetchAll(db, sql: """
                SELECT * FROM showRequest WHERE companyId = ? AND status = 'open' AND target = ? AND targetAgentId IS ?
                ORDER BY createdAt, rowid
                """, arguments: [companyId, type, agentId])
            if let same = open.first(where: { $0.query.lowercased() == normalized.lowercased() && $0.attachedRef == attachedRef
                                                && $0.kind == kind && active - $0.createdActive < ShowLifecycle.dedupeWindow }) {
                return same
            }
            guard open.count < ShowLifecycle.maxOpenPerTarget else {
                throw WorkError.conflict("\(who) already has \(ShowLifecycle.maxOpenPerTarget) open requests; wait or cancel one")
            }
            let today = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM showRequest WHERE companyId = ? AND target = ? AND createdAt >= ?",
                                         arguments: [companyId, type, dayStart]) ?? 0
            if type == "concierge", today >= ShowLifecycle.conciergePerDay {
                throw WorkError.conflict("Brahma has answered \(ShowLifecycle.conciergePerDay) requests today; try again tomorrow")
            }
            if type == "agent", today >= ShowLifecycle.agentPerDay {
                throw WorkError.conflict("agents have answered \(ShowLifecycle.agentPerDay) requests today; try again tomorrow")
            }
            let number = try Store.nextRefNumber(db: db, companyId: companyId, kind: .showRequest, floor: 0)
            let request = ShowRequest(
                id: UUID().uuidString, companyId: companyId, number: number, kind: kind, query: normalized, attachedRef: attachedRef,
                target: type, targetAgentId: agentId, routedBy: ShowRouting.isOwnerRouted(routed) ? "owner" : "rule",
                reason: routed.reason, candidates: encoded, status: .open, answerMessageId: nil, turnId: nil, costUSD: nil,
                costShare5h: nil, autoOpenedAt: nil, createdAt: now, createdActive: active)
            var stored = request
            if let agentId, let handle = try String.fetchOne(db, sql: "SELECT name FROM agent WHERE id = ?", arguments: [agentId]) {
                let dm = try router.sendDM(db: db, companyId: companyId, from: .owner, to: handle, text: "Show request: " + normalized,
                                           now: now, kind: .showRequest)
                stored.requestMessageId = dm.id
            }
            try stored.insert(db)
            try ActivityEvent(companyId: companyId, agentId: agentId, turnId: nil, kind: .show,
                              text: "show request \(number) to \(who) (\(routed.reason))", createdAt: now).insert(db)
            return stored
        }
    }

    public func showRequest(companyId: String, id: String) throws -> ShowRequest? {
        try writer.read { db in
            try ShowRequest.fetchOne(db, sql: "SELECT * FROM showRequest WHERE companyId = ? AND id = ?", arguments: [companyId, id])
        }
    }

    /// The owner cancels an open request from its waiting chip.
    public func cancelShowRequest(companyId: String, id: String, now: Date) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE showRequest SET status = 'cancelled' WHERE companyId = ? AND id = ? AND status = 'open'",
                           arguments: [companyId, id])
            guard db.changesCount > 0 else { throw WorkError.notFound("that request isn't open") }
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .show, text: "show request cancelled by the owner",
                              createdAt: now).insert(db)
        }
    }

    /// The tick: open requests past `ShowLifecycle.expiry` active seconds expire. Returns how many.
    @discardableResult
    public func sweepShowRequests(companyId: String, now: Date) throws -> Int {
        try writer.write { db in
            let active = try Store.activeNow(db: db, companyId: companyId)
            let due = try ShowRequest.fetchAll(db, sql: """
                SELECT * FROM showRequest WHERE companyId = ? AND status = 'open' AND createdActive <= ?
                """, arguments: [companyId, active - ShowLifecycle.expiry])
            for r in due {
                try Store.expireShowRequest(db: db, r, reason: "nobody answered within an active hour", now: now)
            }
            return due.count
        }
    }

    static func expireShowRequest(db: Database, _ r: ShowRequest, reason: String, now: Date) throws {
        try db.execute(sql: "UPDATE showRequest SET status = 'expired' WHERE companyId = ? AND id = ? AND status = 'open'",
                       arguments: [r.companyId, r.id])
        guard db.changesCount > 0 else { return }
        try ActivityEvent(companyId: r.companyId, agentId: r.targetAgentId, turnId: nil, kind: .show,
                          text: "show request \(r.number) expired: \(reason)", createdAt: now).insert(db)
    }

    /// A Show bar query nothing answered (`chosen`: `ask` when the owner asked anyway, `none` when they left it).
    public func logShowMiss(companyId: String, query: String, chosen: String, topScore: Double, now: Date) throws {
        guard chosen == "ask" || chosen == "none" else { throw WorkError.invalid("chosen is ask or none") }
        let normalized = ShowQuery.normalize(query).normalized
        try writer.write { db in
            try ShowMiss(id: UUID().uuidString, companyId: companyId, query: normalized, chosen: chosen,
                         topScore: topScore.isFinite ? topScore : nil, createdAt: now).insert(db)
        }
    }

    // MARK: Answers

    /// The `show` tool's body (design §2.4) for `caller` (an agent, or `.concierge`): 1–`ShowLimits.maxRefs` refs, each
    /// resolved `.full` for the caller or refused with the generic `"ref <n> isn't available to you"` (missing and unreadable
    /// alike: no existence oracle); `notes` (one per ref, ≤ 280 each) and `note` (≤ 600). The answer is a `kind = showAnswer`
    /// message in the owner's DM with the agent, or, for the concierge, from `Sender.system` in the owner's system DM ("Brahma",
    /// created on first use). The note is stored as written, unless it (or a per-ref note) holds a stored value: then it is
    /// stored as `ShowLimits.withheldNote` (Rulings 53–55: gated as the final string, never cut around a value).
    /// `answerVerified` is `CitationCheck.verify`'s verdict. When `request` names an open request of this caller, it becomes
    /// `answered` with the message; the reply then says it opened in the owner's preview. Otherwise the answer is posted only
    /// (it never opens the preview).
    public func answerShow(companyId: String, caller: Reader, request: String?, refs: [String], notes: [String]?, note: String,
                           knownValues: [(name: String, value: String)], now: Date) throws -> String {
        guard (1...ShowLimits.maxRefs).contains(refs.count) else { throw WorkError.invalid("show takes 1 to \(ShowLimits.maxRefs) refs") }
        guard note.count <= ShowLimits.noteMax else { throw WorkError.invalid("the note is at most \(ShowLimits.noteMax) characters") }
        if let notes {
            guard notes.count <= refs.count else { throw WorkError.invalid("notes takes at most one note per ref") }
            guard notes.allSatisfy({ $0.count <= ShowLimits.refNoteMax }) else {
                throw WorkError.invalid("each of notes is at most \(ShowLimits.refNoteMax) characters")
            }
        }
        let sender: Sender
        switch caller {
        case .agent(let id): sender = .agent(id)
        case .concierge: sender = .system
        case .owner: throw WorkError.invalid("the owner opens refs directly")
        }
        guard let company = try company(id: companyId) else { throw WorkError.notFound(Self.refUnavailable) }
        var context = RefContext(companyId: companyId, keyPrefixes: [Self.keyPrefix(slug: company.slug)])
        if case .agent(let id) = caller { context.actingAgentId = id }

        // Each ref, resolved for the caller; anything but `.full` (or any failure) is the generic text for its position.
        var rows: [MessageRef] = []
        for (i, raw) in refs.enumerated() {
            let unavailable = WorkError.notFound("ref \(i + 1) isn't available to you")
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let ref = WorkRef.parse(PasteableRef.decode(text) ?? text, context: context), ref.kind != .fact else { throw unavailable }
            let r: Resolution
            do { r = try resolveDetailed(ref, reader: caller, companyId: companyId, messageRefId: nil) } catch { throw unavailable }
            guard r.resolved.visibility == .full, let subject = r.subject, r.resolved.state != .purged else { throw unavailable }
            var row = try Self.refRow(id: Self.shareRowId(now: now), companyId: companyId, pinned: r.pinned, subject: subject,
                                      resolved: r.resolved, inline: false, now: now)
            row.position = i
            rows.append(row)
        }

        // Rulings 53–55: the note and every per-ref note are gated as the final strings they are stored as.
        let gate = GlobalSearch.TextGate(knownValues: knownValues)
        let storedNote = gate.holdsSecret(note) ? ShowLimits.withheldNote : note
        if let notes {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            for (i, n) in notes.enumerated() where i < rows.count && !n.isEmpty {
                var params = (try? JSONDecoder().decode([String: String].self, from: Data(rows[i].params.utf8))) ?? [:]
                params["note"] = gate.holdsSecret(n) ? ShowLimits.withheldNote : n
                rows[i].params = String(decoding: try encoder.encode(params), as: UTF8.self)
            }
        }
        // Plan C Task C5b: a live diff opens live; the answer keeps the patch hash it was shown at (`params["at"]`), so the card
        // can say "changed since shown". Computed for the caller (its access was checked above); a failure leaves no `at`.
        for i in rows.indices {
            guard let live = rows[i].workRef, live.kind == .diff, live.isWorktree, live.params["snapshot"] == nil, !live.id.isEmpty,
                  let compare = CompareMode(ref: live),
                  let snapshot = try? changesSnapshot(companyId: companyId, key: live.id, compare: compare, reader: caller,
                                                      knownValues: knownValues, now: now) else { continue }
            var params = (try? JSONDecoder().decode([String: String].self, from: Data(rows[i].params.utf8))) ?? [:]
            params["at"] = snapshot.patchHash
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            rows[i].params = String(decoding: try encoder.encode(params), as: UTF8.self)
        }
        let verified = CitationCheck.verify(note: storedNote, refCount: rows.count).verified
        let router = MessageRouter(store: self)
        let opened = try writer.write { db -> Bool in
            var open: ShowRequest?
            if let request {
                let r = try ShowRequest.fetchOne(db, sql: "SELECT * FROM showRequest WHERE companyId = ? AND id = ?", arguments: [companyId, request])
                if let r, r.status == .open, Self.matches(r, caller) { open = r }
            }
            let message = try router.sendDM(db: db, companyId: companyId, from: sender, to: "owner", text: storedNote, now: now, kind: .showAnswer)
            try db.execute(sql: "UPDATE message SET answerVerified = ? WHERE id = ?", arguments: [verified ? 1 : 0, message.id])
            if caller == .concierge {
                try Self.markConciergeAnswer(db: db, companyId: companyId, messageId: message.id, requestId: request, text: storedNote, now: now)
            }
            for var row in rows {
                row.messageId = message.id
                try row.insert(db)
            }
            if let open {
                try db.execute(sql: "UPDATE showRequest SET status = 'answered', answerMessageId = ? WHERE companyId = ? AND id = ?",
                               arguments: [message.id, companyId, open.id])
            }
            let who = try Self.callerName(db, caller)
            var actor: String?
            if case .agent(let id) = caller { actor = id }
            try ActivityEvent(companyId: companyId, agentId: actor, turnId: nil,
                              kind: .show, text: "\(who) showed the owner \(rows.map(\.canonical).joined(separator: ", "))"
                                + (open.map { " (request \($0.number))" } ?? "") + (verified ? "" : " · unverified"),
                              createdAt: now).insert(db)
            return open != nil
        }
        return opened ? "Showed the owner \(rows.count) step\(rows.count == 1 ? "" : "s"). It opened in their preview." : "Posted to the owner's DM."
    }

    /// The answer card's engine-derived title (design §2.4): `"<the first ref's engine title> · answered"`, resolved for the
    /// owner and gated as that final string (the ref's canonical, then `"answered"` as fallbacks). Nil for a message without refs.
    public func showAnswerTitle(companyId: String, messageId: String, gate: GlobalSearch.TextGate) throws -> String? {
        guard let first = try messageRefs(companyId: companyId, messageId: messageId).first, let ref = first.workRef else { return nil }
        let resolved = try resolveRef(ref, for: .owner, companyId: companyId)
        let title = resolved.visibility == .full ? gate.final(resolved.title, max: SafeTitle.max) : nil
        for candidate in [title, gate.final(ref.canonical, max: RefGrammar.maxLength)].compactMap({ $0 }) where !candidate.isEmpty {
            let full = candidate + " · answered"
            if !gate.holdsSecret(full) { return full }
        }
        return "answered"
    }

    /// The concierge's identity on its answers (C4c fix round 1, Ruling 60 (1)). The message travels in the owner's Brahma
    /// thread (`dm:owner:system`) but is never engine text: its sender is `ConciergeCaps.agentId` (agent-derived, rendered as
    /// "Brahma (concierge)"), it carries the taint of every source its run read (`conciergeRun.taintSource`: the untrusted chip
    /// and the relay rules apply), and a claim to be the owner is flagged as for any agent (`OwnerImpersonation`). Without a
    /// run row (a run that can't be read), the answer counts as tainted (fail closed).
    static func markConciergeAnswer(db: Database, companyId: String, messageId: String, requestId: String?, text: String, now: Date) throws {
        let run = try requestId.flatMap {
            try Row.fetchOne(db, sql: "SELECT taintSource FROM conciergeRun WHERE requestId = ? AND companyId = ?", arguments: [$0, companyId])
        }
        let source: String? = run == nil ? "an unrecorded concierge run" : run?["taintSource"]
        let impersonates = OwnerImpersonation.flags(text: text, sender: .agent(ConciergeCaps.agentId))
        try db.execute(sql: """
            UPDATE message SET senderId = ?, flag = ?, taintedOrigin = ?, fromTaintedSession = ?, taintSource = ? WHERE id = ? AND companyId = ?
            """, arguments: [ConciergeCaps.agentId, impersonates ? OwnerImpersonation.flag : nil, source != nil, source != nil,
                             source.map { "concierge read \($0)" }, messageId, companyId])
        if impersonates {
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .error,
                              text: "Brahma (concierge)'s answer claims to be the owner; flagged unverified (it changes nothing)",
                              createdAt: now).insert(db)
        }
    }

    /// Records that the concierge's run of `requestId` read tainted content (`source`); the first source is kept. Throws when
    /// it can't be recorded, so the read is refused (fail closed).
    public func markConciergeTainted(companyId: String, requestId: String, source: String) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE conciergeRun SET taintSource = COALESCE(taintSource, ?) WHERE requestId = ? AND companyId = ? AND endedAt IS NULL
                """, arguments: [Store.flat(source, max: 300), requestId, companyId])
            guard db.changesCount > 0 else { throw WorkError.invalid("the concierge's run is over") }
        }
    }

    static func matches(_ r: ShowRequest, _ caller: Reader) -> Bool {
        switch caller {
        case .concierge: return r.target == "concierge"
        case .agent(let id): return r.target == "agent" && r.targetAgentId == id
        case .owner: return false
        }
    }

    static func callerName(_ db: Database, _ caller: Reader) throws -> String {
        switch caller {
        case .concierge: return "Brahma"
        case .owner: return "the owner"
        case .agent(let id): return "@" + (try String.fetchOne(db, sql: "SELECT name FROM agent WHERE id = ?", arguments: [id]) ?? "unknown")
        }
    }

    /// A concierge run that ended with text and no `show` call: the text (flattened, at most 600 characters, gated as that
    /// final string) as a `showAnswer` from Brahma with no refs, `answerVerified = false`; the request becomes `answered`.
    @discardableResult
    func answerShowWithText(_ request: ShowRequest, text: String, knownValues: [(name: String, value: String)], now: Date) throws -> Bool {
        let gate = GlobalSearch.TextGate(knownValues: knownValues)
        let final = gate.final(text, max: ShowLimits.noteMax) ?? ShowLimits.withheldNote
        guard !final.isEmpty else { return false }
        let router = MessageRouter(store: self)
        return try writer.write { db in
            guard let r = try ShowRequest.fetchOne(db, sql: "SELECT * FROM showRequest WHERE companyId = ? AND id = ?",
                                                   arguments: [request.companyId, request.id]), r.status == .open else { return false }
            let message = try router.sendDM(db: db, companyId: r.companyId, from: .system, to: "owner", text: final, now: now, kind: .showAnswer)
            try db.execute(sql: "UPDATE message SET answerVerified = 0 WHERE id = ?", arguments: [message.id])
            try Self.markConciergeAnswer(db: db, companyId: r.companyId, messageId: message.id, requestId: r.id, text: final, now: now)
            try db.execute(sql: "UPDATE showRequest SET status = 'answered', answerMessageId = ? WHERE companyId = ? AND id = ?",
                           arguments: [message.id, r.companyId, r.id])
            try ActivityEvent(companyId: r.companyId, agentId: nil, turnId: nil, kind: .show,
                              text: "Brahma answered request \(r.number) without sources · unverified", createdAt: now).insert(db)
            return true
        }
    }

    /// What a request cost (its turn or concierge run), as dollars and as percent of the five-hour window.
    func recordShowCost(companyId: String, requestIds: [String], costUSD: Double, now: Date) throws {
        guard costUSD.isFinite, costUSD >= 0, !requestIds.isEmpty else { return }
        let share = ShowCost.share5h(costUSD, calibration: try usageCalibration())
        let each = costUSD / Double(requestIds.count), eachShare = share / Double(requestIds.count)
        try writer.write { db in
            for id in requestIds {
                try db.execute(sql: """
                    UPDATE showRequest SET costUSD = COALESCE(costUSD, 0) + ?, costShare5h = COALESCE(costShare5h, 0) + ?
                    WHERE companyId = ? AND id = ?
                    """, arguments: [each, eachShare, companyId, id])
            }
        }
    }

    // MARK: Auto-open

    /// Answered requests whose answer (with refs) hasn't been opened yet. A `show` with no request is never here.
    public func pendingAutoOpens(companyId: String) throws -> [AutoOpen] {
        try writer.read { db in
            var out: [AutoOpen] = []
            for r in try ShowRequest.fetchAll(db, sql: """
                SELECT r.* FROM showRequest r JOIN message m ON m.id = r.answerMessageId AND m.companyId = r.companyId
                WHERE r.companyId = ? AND r.status = 'answered' AND r.autoOpenedAt IS NULL AND m.kind = 'showAnswer'
                ORDER BY r.createdAt, r.rowid
                """, arguments: [companyId]) {
                guard let messageId = r.answerMessageId else { continue }
                // Fix round 1 (I-3, Ruling 60 (3)): only the refs `show` itself checked, never a message's inline chips.
                let refs = try MessageRef.fetchAll(db, sql: """
                    SELECT * FROM messageRef WHERE companyId = ? AND messageId = ? AND inline = 0 ORDER BY position, rowid
                    """, arguments: [companyId, messageId]).compactMap(\.workRef)
                guard !refs.isEmpty else { continue }
                let by = try r.targetAgentId.flatMap { try String.fetchOne(db, sql: "SELECT name FROM agent WHERE id = ?", arguments: [$0]) }
                    .map { "@" + $0 } ?? "Brahma"
                out.append(AutoOpen(requestId: r.id, answerMessageId: messageId, refs: refs, by: by, concierge: r.showTarget == .concierge))
            }
            return out
        }
    }

    public func markAutoOpened(companyId: String, id: String, now: Date) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE showRequest SET autoOpenedAt = ? WHERE companyId = ? AND id = ? AND autoOpenedAt IS NULL",
                           arguments: [now, companyId, id])
        }
    }

    // MARK: Usage

    /// The "owner requests" line: the 5H share summed from the requests of the last five hours (`costShare5h`), and the 7D
    /// share of the last seven days' request spend through the weekly calibration (0 before it has samples).
    public func ownerRequestUsage(companyId: String, now: Date) throws -> OwnerRequestUsage {
        let cal = try usageCalibration()
        return try writer.read { db in
            let five = try Double.fetchOne(db, sql: """
                SELECT COALESCE(SUM(costShare5h), 0) FROM showRequest WHERE companyId = ? AND createdAt >= ?
                """, arguments: [companyId, now.addingTimeInterval(-5 * 3600)]) ?? 0
            let week = try Double.fetchOne(db, sql: """
                SELECT COALESCE(SUM(costUSD), 0) FROM showRequest WHERE companyId = ? AND createdAt >= ?
                """, arguments: [companyId, now.addingTimeInterval(-7 * 86_400)]) ?? 0
            return OwnerRequestUsage(share5h: five, share7d: week * (cal.pctPerDollar ?? 0) * 100)
        }
    }

    /// The agent's last `ShowETA.window` finished turns' durations in seconds, newest last.
    public func recentTurnDurations(agentId: String) throws -> [Double] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT startedAt, endedAt FROM turn WHERE agentId = ? AND endedAt IS NOT NULL ORDER BY startedAt DESC, rowid DESC LIMIT ?
                """, arguments: [agentId, ShowETA.window])
            return rows.compactMap { row -> Double? in
                guard let s: Date = row["startedAt"], let e: Date = row["endedAt"] else { return nil }
                return max(0, e.timeIntervalSince(s))
            }.reversed()
        }
    }

    // MARK: Show turns (agents)

    /// The open requests routed to `agentId` that no `.show` turn has taken yet, oldest first.
    public func showRequestsAwaitingTurn(agentId: String) throws -> [ShowRequest] {
        try writer.read { db in
            try ShowRequest.fetchAll(db, sql: """
                SELECT r.* FROM showRequest r JOIN agent a ON a.id = r.targetAgentId AND a.companyId = r.companyId
                WHERE r.targetAgentId = ? AND r.target = 'agent' AND r.status = 'open' AND r.turnId IS NULL
                ORDER BY r.createdAt, r.rowid
                """, arguments: [agentId])
        }
    }

    /// The open request the agent's running `.show` turn took (oldest first); nil outside such a turn.
    public func boundShowRequest(agentId: String, turnId: String?) throws -> String? {
        guard let turnId else { return nil }
        return try writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT id FROM showRequest WHERE targetAgentId = ? AND turnId = ? AND status = 'open' ORDER BY createdAt, rowid LIMIT 1
                """, arguments: [agentId, turnId])
        }
    }

    /// Agents with an owner request waiting for its turn (the scheduler puts them first).
    public func ownerRequestAgentIds() throws -> Set<String> {
        try writer.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT DISTINCT targetAgentId FROM showRequest WHERE target = 'agent' AND status = 'open' AND turnId IS NULL
                  AND targetAgentId IS NOT NULL
                """))
        }
    }

    /// A `.show` turn takes its requests, and delivers their DMs (the request itself; every other inbox item stays pending).
    func bindShowTurn(turnId: String, agentId: String, requestIds: [String]) throws {
        try writer.write { db in
            for id in requestIds {
                try db.execute(sql: "UPDATE showRequest SET turnId = ? WHERE id = ? AND targetAgentId = ? AND turnId IS NULL",
                               arguments: [turnId, id, agentId])
            }
            try db.execute(sql: """
                UPDATE inboxItem SET deliveredTurnId = ? WHERE agentId = ? AND deliveredTurnId IS NULL AND messageId IN (
                    SELECT m.id FROM message m WHERE m.kind = 'showRequest' AND m.senderId = 'owner')
                """, arguments: [turnId, agentId])
        }
    }

    /// A turn by id (bound to nothing: engine use only).
    func turn(id: String) throws -> Turn? { try writer.read { db in try Turn.fetchOne(db, key: id) } }

    /// The largest total an earlier turn of the session recorded (`total_cost_usd` is cumulative over `--resume`).
    func sessionCostBefore(sessionId: String, turnId: String) -> Double {
        (try? writer.read { db in
            try Double.fetchOne(db, sql: """
                SELECT MAX(sessionTotalUSD) FROM turn WHERE sessionId = ? AND id <> ? AND sessionTotalUSD IS NOT NULL
                """, arguments: [sessionId, turnId])
        }) ?? 0
    }

    /// A show turn stopped by its soft cap: its open requests expire with the reason.
    func expireShowTurn(turnId: String, agentId: String, reason: String, now: Date) throws {
        try writer.write { db in
            for r in try ShowRequest.fetchAll(db, sql: "SELECT * FROM showRequest WHERE turnId = ? AND targetAgentId = ? AND status = 'open'",
                                              arguments: [turnId, agentId]) {
                try Store.expireShowRequest(db: db, r, reason: reason, now: now)
            }
        }
    }

    /// Whether every engine candidate of `r` is a ref the owner typed in the query or attached (the show turn then runs on
    /// Haiku). A request with no candidate, or one with a count line (`<n> more the owner can see`), is not.
    public func showCandidatesAreDirect(_ r: ShowRequest, company: Company) -> Bool {
        let context = RefContext(companyId: company.id, keyPrefixes: [Self.keyPrefix(slug: company.slug)])
        var typed = Set<String>()
        for token in r.query.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,;:!?()"))
            if let ref = WorkRef.parse(trimmed, context: context) { typed.insert(ref.canonical) }
        }
        if let attached = r.attachedRef, let ref = WorkRef.parse(attached, context: context) { typed.insert(ref.canonical) }
        let lines = r.candidateLines
        guard !lines.isEmpty, !typed.isEmpty else { return false }
        return lines.allSatisfy { line in
            guard let first = line.split(separator: " ").first.map(String.init),
                  let ref = WorkRef.parse(first, context: context) else { return false }
            return typed.contains(ref.canonical)
        }
    }

    /// The end of a `.show` turn: its cost lands on its requests; one still open is answered by the agent's DM reply in the
    /// request's thread made during the turn (it never opens the preview), else it expires (`"@<h>'s turn ended without an
    /// answer"`).
    func finishShowTurn(turnId: String, agentId: String, startedAt: Date, costUSD: Double?, now: Date) throws {
        let requests = try writer.read { db in
            try ShowRequest.fetchAll(db, sql: "SELECT * FROM showRequest WHERE turnId = ? AND targetAgentId = ?", arguments: [turnId, agentId])
        }
        guard let companyId = requests.first?.companyId else { return }
        if let costUSD { try recordShowCost(companyId: companyId, requestIds: requests.map(\.id), costUSD: costUSD, now: now) }
        try writer.write { db in
            let handle = try String.fetchOne(db, sql: "SELECT name FROM agent WHERE id = ?", arguments: [agentId]) ?? "agent"
            for r in requests where r.status == .open {
                guard try ShowRequest.fetchOne(db, key: r.id)?.status == .open else { continue }
                // Fix round 1 (M3): only a reply in the request's own thread answers it (never an unrelated DM). It carries the
                // agent's session taint as every agent message does, and it never auto-opens (`pendingAutoOpens`).
                let reply = try r.requestMessageId.flatMap { root in
                    try String.fetchOne(db, sql: """
                        SELECT m.id FROM message m JOIN channel c ON c.id = m.channelId
                        WHERE m.companyId = ? AND m.senderId = ? AND c.kind = 'dm' AND c.name = ? AND m.createdAt >= ? AND m.parentId = ?
                        ORDER BY m.createdAt DESC, m.rowid DESC LIMIT 1
                        """, arguments: [companyId, agentId, "dm:" + ["owner", handle].sorted().joined(separator: ":"), startedAt, root])
                }
                if let reply {
                    try db.execute(sql: "UPDATE showRequest SET status = 'answered', answerMessageId = ? WHERE id = ? AND status = 'open'",
                                   arguments: [reply, r.id])
                } else {
                    try Store.expireShowRequest(db: db, r, reason: "@\(handle)'s turn ended without an answer", now: now)
                }
            }
        }
    }
}
