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

    public init(id: String, title: String, body: String, target: String, companyId: String? = nil) {
        self.id = id; self.title = title; self.body = body; self.target = target; self.companyId = companyId
    }
}

/// What to post now and what to mark delivered. Held notices appear in neither list, so they stay due.
public struct DeliveryPlan: Equatable, Sendable {
    public var post: [PostedNotice] = []
    public var markAsks: [String] = []
    public var markNotices: [Int64] = []

    public init(post: [PostedNotice] = [], markAsks: [String] = [], markNotices: [Int64] = []) {
        self.post = post; self.markAsks = markAsks; self.markNotices = markNotices
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

    public static func plan(dueAsks: [DueAsk], notices: [OwnerNotice], prefs: OwnerPrefs, now: Date, tz: TimeZone) -> DeliveryPlan {
        guard prefs.notificationsEnabled else {
            return DeliveryPlan(post: [], markAsks: dueAsks.map(\.ask.id), markNotices: notices.compactMap(\.id))
        }
        let quiet = prefs.quietHours?.contains(now, tz: tz) ?? false

        struct Entry { var post: PostedNotice; var urgent: Bool; var askId: String?; var noticeId: Int64? }
        var entries: [Entry] = dueAsks.map { due in
            let ask = due.ask
            let kind = ask.kind == .info ? "Question" : ask.kind == .engineAlert ? "Engine alert" : ask.kind.title
            let from = due.handle.map { "@\($0)" } ?? "Brahma"
            let post = PostedNotice(id: "ask-\(ask.id)-\(ask.remindCount)",
                                    title: flatten("\(due.companyName): \(kind) from \(from)", max: 100),
                                    body: flatten(ask.title, max: maxAskBody), target: "ask:\(ask.id)", companyId: ask.companyId)
            return Entry(post: post, urgent: NoticeUrgency.of(blockedCount: due.blockedCount) == .urgent, askId: ask.id, noticeId: nil)
        }
        entries += notices.compactMap { n in
            guard let id = n.id else { return nil }
            let post = PostedNotice(id: "notice-\(id)", title: flatten(n.title, max: 100), body: flatten(n.body, max: maxNoticeBody),
                                    target: "inbox", companyId: n.companyId)
            return Entry(post: post, urgent: n.urgency == .urgent, askId: nil, noticeId: id)
        }

        var plan = DeliveryPlan()
        func mark(_ e: Entry) {
            if let a = e.askId { plan.markAsks.append(a) }
            if let n = e.noticeId { plan.markNotices.append(n) }
        }
        let urgent = entries.filter(\.urgent)
        for e in urgent { plan.post.append(e.post); mark(e) }
        guard !quiet else { return plan }
        let normal = entries.filter { !$0.urgent }
        if normal.count > batchAbove {
            let firstTitles = normal.prefix(3).map { $0.post.title + ": " + $0.post.body }.joined(separator: " | ")
            plan.post.append(PostedNotice(id: "summary-\(Int(now.timeIntervalSince1970))", title: "Brahma: \(normal.count) things need you",
                                          body: flatten(firstTitles, max: maxNoticeBody), target: "inbox"))
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

/// The most open owner requests one agent may hold at a time (`request_from_owner`, `propose_decision`; later
/// `request_secret` and `request_access`).
public enum AskQuota {
    public static let perAgent = 3
    public static let refusal = "You already have 3 open requests for the owner; wait for an answer before asking again."

    public static func check(store: Store, agentId: String) throws {
        let open = try store.writer.read { db in
            try Ask.filter(Column("requesterId") == agentId
                           && [AskStatus.pendingInternal.rawValue, AskStatus.pendingOwner.rawValue].contains(Column("status"))).fetchCount(db)
        }
        if open >= perAgent { throw WorkError.invalid(refusal) }
    }
}

extension Store {
    /// Asks waiting for the owner without a banner (including reminders), oldest first, in every company.
    /// `blockedCount` is the agents blocked on the owner and items blocked whose reason names the ask.
    public func dueAskNotices() throws -> [DueAsk] {
        try writer.read { db in
            let asks = try Ask.filter(Column("status") == AskStatus.pendingOwner.rawValue && Column("notifiedAt") == nil)
                .order(Column("createdAt"), Column.rowID).fetchAll(db)
            var names: [String: String] = [:]
            var blockedAgents: [String: [String]] = [:]
            var blockedItems: [String: [String]] = [:]
            var out: [DueAsk] = []
            for ask in asks {
                let cid = ask.companyId
                if names[cid] == nil {
                    names[cid] = try Company.fetchOne(db, key: cid)?.name ?? "Brahma"
                    blockedAgents[cid] = try Agent.filter(Column("companyId") == cid && Column("state") == AgentState.blocked.rawValue).fetchAll(db)
                        .compactMap { if case .owner(let r)? = $0.blocker { return r } else { return nil } }
                    blockedItems[cid] = try WorkItem.filter(Column("companyId") == cid && Column("status") == WorkItemStatus.blocked.rawValue)
                        .fetchAll(db).compactMap(\.blockedReason)
                }
                let count = (blockedAgents[cid] ?? []).filter { Store.mentions(ask.ref, in: $0) }.count
                    + (blockedItems[cid] ?? []).filter { Store.mentions(ask.ref, in: $0) }.count
                let handle = ask.requesterId == "system" ? nil : try Agent.fetchOne(db, key: ask.requesterId)?.name
                out.append((ask, names[cid] ?? "Brahma", count, handle))
            }
            return out
        }
    }

    /// True when `text` names `ref` ("A-3") as a whole token, so A-3 does not match A-30.
    static func mentions(_ ref: String, in text: String) -> Bool {
        let lower = text.lowercased(), r = ref.lowercased()
        var from = lower.startIndex
        while let range = lower.range(of: r, range: from..<lower.endIndex) {
            let before = range.lowerBound == lower.startIndex ? nil : lower[lower.index(before: range.lowerBound)]
            let after = range.upperBound == lower.endIndex ? nil : lower[range.upperBound]
            if !(before?.isLetter ?? false || before?.isNumber ?? false) && !(after?.isNumber ?? false) { return true }
            from = range.upperBound
        }
        return false
    }
}
