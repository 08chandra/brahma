import Foundation
import GRDB

/// One banner to post. `target` is a `SelectTarget` string (`ask:<id>` or `inbox`).
public struct PostedNotice: Equatable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var target: String
    /// Groups banners by company (the system's thread identifier); nil for a summary that spans companies.
    public var companyId: String?
    /// The asks and notices behind this banner (one for a single banner, every member for a summary): they are marked
    /// delivered only when this banner posted.
    public var askIds: [String]
    public var noticeIds: [Int64]

    public init(id: String, title: String, body: String, target: String, companyId: String? = nil, askIds: [String] = [],
                noticeIds: [Int64] = []) {
        self.id = id; self.title = title; self.body = body; self.target = target; self.companyId = companyId
        self.askIds = askIds; self.noticeIds = noticeIds
    }
}

/// What to post now and what to mark delivered. Held notices appear in neither list, so they stay due.
public struct DeliveryPlan: Equatable, Sendable {
    public var post: [PostedNotice] = []
    public var markAsks: [String] = []
    public var markNotices: [Int64] = []
    /// The `remindCount` each ask in `markAsks` was planned at: marking skips an ask whose reminder moved on since.
    public var remindCounts: [String: Int] = [:]

    public init(post: [PostedNotice] = [], markAsks: [String] = [], markNotices: [Int64] = [], remindCounts: [String: Int] = [:]) {
        self.post = post; self.markAsks = markAsks; self.markNotices = markNotices; self.remindCounts = remindCounts
    }

    /// What to mark once the posts are done: everything planned except the asks and notices behind a banner that failed
    /// (a failed summary keeps all of its members due). Asks map to their planned `remindCount`.
    public func marks(failed: [PostedNotice]) -> (asks: [String: Int], notices: [Int64]) {
        let failedAsks = Set(failed.flatMap(\.askIds)), failedNotices = Set(failed.flatMap(\.noticeIds))
        var asks: [String: Int] = [:]
        for id in markAsks where !failedAsks.contains(id) { asks[id] = remindCounts[id] ?? 0 }
        return (asks, markNotices.filter { !failedNotices.contains($0) })
    }
}

/// An ask waiting for the owner without a banner, with what the plan needs to word and rank it.
public typealias DueAsk = (ask: Ask, companyName: String, blockedCount: Int, handle: String?)

/// Pure: decides which owner notifications are shown now. Disabled marks everything delivered; urgent notices always
/// post; normal ones wait out quiet hours (nothing is marked, so they are due again), and when more than `batchAbove`
/// normal ones are due together they collapse into one summary. Urgency never comes from agent text.
public enum NoticeDelivery {
    public static let batchAbove = 3
    public static let maxAskBody = 120
    public static let maxNoticeBody = 140

    /// The desktop banners. Phone pushes are planned apart, only by `PushDispatcher` (`pushPlan`), from the `pushedAt` due
    /// set and with titles that went through the redactor: never from this plan's inputs.
    public static func plan(dueAsks: [DueAsk], notices: [OwnerNotice], prefs: OwnerPrefs, now: Date, tz: TimeZone) -> DeliveryPlan {
        desktopPlan(dueAsks: dueAsks, notices: notices, prefs: prefs, now: now, tz: tz)
    }

    // MARK: Phone pushes

    public static let maxPushTitle = 80

    /// What to push now. Urgent asks (blocked work at the threshold, and every `engineAlert`) and urgent notices go one each,
    /// at once, quiet hours or not. Everything else waits out quiet hours (it stays due), then coalesces into ONE push.
    /// Rate limits (`PushDispatcher.minInterval`, `dailyCap`) are the dispatcher's. Nothing is pushed while phone alerts are
    /// off, and `notificationsEnabled` (desktop banners) does not gate the phone.
    ///
    /// Privacy: the text is the engine's own. With `counts` no ask title, notice text or message text appears. With `titles`
    /// the only agent-controlled text is ask titles, flattened, and at most 80 characters of them in one push (several
    /// coalesced titles share the 80). The caller redacts them first and plans `counts` when it cannot.
    public static func pushPlan(dueAsks: [DueAsk], notices: [OwnerNotice], prefs: OwnerPrefs, now: Date, tz: TimeZone) -> [PushedNotice] {
        guard prefs.pushProvider != nil else { return [] }
        let titles = prefs.pushDetail == .titles
        func companyName(_ n: String) -> String { flatten(n, max: 40) }

        var urgent: [PushedNotice] = []
        var normalAsks: [DueAsk] = []
        var normalNotices: [OwnerNotice] = []
        for due in dueAsks {
            let isUrgent = due.ask.kind == .engineAlert || NoticeUrgency.of(blockedCount: due.blockedCount) == .urgent
            guard isUrgent else { normalAsks.append(due); continue }
            let line = "\(companyName(due.companyName)): \(askLabel(due.ask.kind)) waiting"
            urgent.append(PushedNotice(title: "Brahma", body: titles ? flatten(due.ask.title, max: maxPushTitle) : line, urgent: true,
                                       askIds: [due.ask.id], companyId: due.ask.companyId))
        }
        for n in notices {
            guard let id = n.id else { continue }
            if n.urgency == .urgent {
                urgent.append(PushedNotice(title: "Brahma", body: "Brahma: 1 thing needs you", urgent: true, noticeIds: [id], companyId: n.companyId))
            } else {
                normalNotices.append(n)
            }
        }
        var out = urgent
        let quiet = prefs.quietHours?.contains(now, tz: tz) ?? false
        let count = normalAsks.count + normalNotices.count
        guard !quiet, count > 0 else { return out }
        let askIds = normalAsks.map(\.ask.id), noticeIds = normalNotices.compactMap(\.id)
        let line: String
        if count == 1, let due = normalAsks.first {
            line = "\(companyName(due.companyName)): \(askLabel(due.ask.kind)) waiting"
        } else {
            line = "Brahma: \(count) \(count == 1 ? "thing needs" : "things need") you"
        }
        var body = line
        if titles, !normalAsks.isEmpty {
            // One push carries at most `maxPushTitle` characters of agent text in all, separators included.
            body = flatten(normalAsks.prefix(3).map { flatten($0.ask.title, max: maxPushTitle) }.joined(separator: " | "), max: maxPushTitle)
            if count > 3 || !normalNotices.isEmpty { body += " | +\(count - min(3, normalAsks.count)) more" }
        }
        out.append(PushedNotice(title: titles ? line : "Brahma", body: titles ? body : line, urgent: false, askIds: askIds,
                                noticeIds: noticeIds, companyId: normalAsks.first?.ask.companyId ?? normalNotices.first?.companyId))
        return out
    }

    /// The engine's own word for what an ask is (an enum, never agent text).
    static func askLabel(_ kind: AskKind) -> String {
        switch kind {
        case .info: "question"
        case .engineAlert: "engine alert"
        default: "\(kind.title.lowercased()) approval"
        }
    }

    // MARK: Desktop banners

    static func desktopPlan(dueAsks: [DueAsk], notices: [OwnerNotice], prefs: OwnerPrefs, now: Date, tz: TimeZone) -> DeliveryPlan {
        let remindCounts = Dictionary(dueAsks.map { ($0.ask.id, $0.ask.remindCount) }, uniquingKeysWith: { a, _ in a })
        guard prefs.notificationsEnabled else {
            return DeliveryPlan(post: [], markAsks: dueAsks.map(\.ask.id), markNotices: notices.compactMap(\.id), remindCounts: remindCounts)
        }
        let quiet = prefs.quietHours?.contains(now, tz: tz) ?? false

        struct Entry { var post: PostedNotice; var urgent: Bool; var askId: String?; var noticeId: Int64? }
        var entries: [Entry] = dueAsks.map { due in
            let ask = due.ask
            let kind = ask.kind == .info ? "Question" : ask.kind == .engineAlert ? "Engine alert" : ask.kind.title
            let from = due.handle.map { "@\($0)" } ?? "Brahma"
            let post = PostedNotice(id: "ask-\(ask.id)-\(ask.remindCount)",
                                    title: flatten("\(due.companyName): \(kind) from \(from)", max: 100),
                                    body: flatten(ask.title, max: maxAskBody), target: "ask:\(ask.id)", companyId: ask.companyId,
                                    askIds: [ask.id])
            return Entry(post: post, urgent: NoticeUrgency.of(blockedCount: due.blockedCount) == .urgent, askId: ask.id, noticeId: nil)
        }
        entries += notices.compactMap { n in
            guard let id = n.id else { return nil }
            let post = PostedNotice(id: "notice-\(id)", title: flatten(n.title, max: 100), body: flatten(n.body, max: maxNoticeBody),
                                    target: "inbox", companyId: n.companyId, noticeIds: [id])
            return Entry(post: post, urgent: n.urgency == .urgent, askId: nil, noticeId: id)
        }

        var plan = DeliveryPlan()
        func mark(_ e: Entry) {
            if let a = e.askId { plan.markAsks.append(a); plan.remindCounts[a] = remindCounts[a] }
            if let n = e.noticeId { plan.markNotices.append(n) }
        }
        let urgent = entries.filter(\.urgent)
        for e in urgent { plan.post.append(e.post); mark(e) }
        guard !quiet else { return plan }
        let normal = entries.filter { !$0.urgent }
        if normal.count > batchAbove {
            let firstTitles = normal.prefix(3).map { $0.post.title + ": " + $0.post.body }.joined(separator: " | ")
            // Named by its members, so a retry of the same set replaces the banner instead of adding a second one.
            let members = normal.map(\.post.id).sorted().joined(separator: ",")
            plan.post.append(PostedNotice(id: "summary-\(StableHash.fnv1a64(members))", title: "Brahma: \(normal.count) things need you",
                                          body: flatten(firstTitles, max: maxNoticeBody), target: "inbox",
                                          askIds: normal.compactMap(\.askId), noticeIds: normal.compactMap(\.noticeId)))
        } else {
            plan.post += normal.map(\.post)
        }
        normal.forEach(mark)
        return plan
    }

    /// One line, no control characters, trimmed to a banner's size.
    static func flatten(_ text: String, max: Int) -> String {
        let spaced = String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
        }))
        let collapsed = spaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count <= max ? collapsed : String(collapsed.prefix(max - 1)) + "…"
    }
}

/// The most open owner requests one agent may hold at a time. Every ask whose requester is an agent counts and is checked
/// in the write that inserts it, inside `Store.propose` / `requestFromOwner`, so a new agent path is limited by default.
/// Engine (`system`) asks are exempt, and the owner files none. The only opt-out is `Exemption.devHook`.
public enum AskQuota {
    /// A named, deliberate opt-out. Only the dev hook (`brahma dev ...`, refused outside a dev build) uses it.
    public enum Exemption: Sendable { case devHook }

    public static let perAgent = 3
    public static let refusal = "You already have 3 open requests for the owner; wait for an answer before asking again."

    public static func check(store: Store, agentId: String) throws {
        try store.writer.read { db in try check(db: db, agentId: agentId) }
    }

    /// The same check inside the caller's transaction: the store runs it in the write that inserts the ask, so two
    /// concurrent calls cannot both pass.
    static func check(db: Database, agentId: String) throws {
        let open = try Ask.filter(Column("requesterId") == agentId
                                  && [AskStatus.pendingInternal.rawValue, AskStatus.pendingOwner.rawValue].contains(Column("status"))).fetchCount(db)
        if open >= perAgent { throw WorkError.invalid(refusal) }
    }
}

extension Store {
    /// Asks waiting for the owner without a banner (including reminders), oldest first, in every company, with their
    /// `blockedCount` (see `linkedBlockers`).
    /// `forPush` asks for the ones without a phone push (`pushedAt`) instead of without a banner (`notifiedAt`).
    public func dueAskNotices(forPush: Bool = false) throws -> [DueAsk] {
        try writer.read { db in
            let asks = try Ask.filter(Column("status") == AskStatus.pendingOwner.rawValue && Column(forPush ? "pushedAt" : "notifiedAt") == nil)
                .order(Column("createdAt"), Column.rowID).fetchAll(db)
            var names: [String: String] = [:]
            var links: [String: LinkedBlockers] = [:]
            var out: [DueAsk] = []
            for ask in asks {
                let cid = ask.companyId
                if names[cid] == nil {
                    names[cid] = try Company.fetchOne(db, key: cid)?.name ?? "Brahma"
                    links[cid] = try LinkedBlockers(db: db, companyId: cid)
                }
                let count = links[cid]?.count(for: ask) ?? 0
                let handle = ask.requesterId == "system" ? nil : try Agent.fetchOne(db, key: ask.requesterId)?.name
                out.append((ask, names[cid] ?? "Brahma", count, handle))
            }
            return out
        }
    }
}

/// Who is blocked on an ask through the engine-set link, never through text: agents whose `Blocker.owner` carries the ask
/// id, and blocked items whose `blockedAskId` is it (attributed to the agent that linked them).
///
/// The count is the number of distinct agents other than the requester, plus at most 1 for the requester's own side (its
/// whole reporting line and the items it or its line linked), so no agent can raise its own ask to urgent.
struct LinkedBlockers {
    /// Blocked agent id → linked ask id.
    var agents: [(agentId: String, askId: String)] = []
    /// Linked ask id and the agent that linked a blocked item.
    var items: [(askId: String, linkedBy: String)] = []
    /// Agent id → manager id.
    var managers: [String: String] = [:]

    init(db: Database, companyId: String) throws {
        let all = try Agent.filter(Column("companyId") == companyId).fetchAll(db)
        for a in all {
            if let m = a.managerId { managers[a.id] = m }
            if a.state == .blocked, case .owner(_, let askId?)? = a.blocker { agents.append((a.id, askId)) }
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT blockedAskId, blockedAskBy FROM workItem
            WHERE companyId = ? AND status = ? AND blockedAskId IS NOT NULL AND blockedAskBy IS NOT NULL
            """, arguments: [companyId, WorkItemStatus.blocked.rawValue])
        items = rows.map { ($0["blockedAskId"], $0["blockedAskBy"]) }
    }

    /// True when `agentId` is `requester` or reports to it, directly or further down.
    func inLine(_ agentId: String, of requester: String) -> Bool {
        var current: String? = agentId
        var seen: Set<String> = []
        while let id = current, seen.insert(id).inserted {
            if id == requester { return true }
            current = managers[id]
        }
        return false
    }

    func count(for ask: Ask) -> Int {
        var others: Set<String> = []
        var ownSide = false
        for a in agents where a.askId == ask.id && a.agentId != ask.requesterId {
            if inLine(a.agentId, of: ask.requesterId) { ownSide = true } else { others.insert(a.agentId) }
        }
        for i in items where i.askId == ask.id {
            if inLine(i.linkedBy, of: ask.requesterId) { ownSide = true } else { others.insert(i.linkedBy) }
        }
        return others.count + (ownSide ? 1 : 0)
    }
}
