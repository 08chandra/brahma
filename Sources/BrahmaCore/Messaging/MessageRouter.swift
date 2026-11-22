import Foundation
import GRDB

public enum RouterError: Error, Equatable {
    case unknownChannel(String)
    case unknownAgent(String)
    case notAMember
    /// Sender is an unknown, killed or other-company agent, or a DM to oneself.
    case invalidSender
    /// A channel occupying a DM name is not a DM between exactly the two parties.
    case invalidChannel(String)
}

public struct PostResult: Equatable, Sendable {
    public var message: Message
    /// Nil when the text carries no `@here`/`@team`.
    public var broadcastApplied: Bool?
    public var broadcastRefusal: String?
}

public struct MessageRouter: Sendable {
    public let store: Store

    public init(store: Store) { self.store = store }

    /// `replyTo` (Plan C Task C3a): a message of the same channel (`msg:<id>`, `thread:<id>` or the bare id) the post replies to;
    /// it joins that message's thread (`parentId` is always the root). Refused with `ThreadError`: `.unavailable` when the
    /// sender can't read it (or it is missing or another company's), `.notInConversation` when it is in another channel or DM.
    public func post(companyId: String, channel name: String, from: Sender, text: String, now: Date = .now,
                     replyTo: String? = nil) throws -> Message {
        try postDetailed(companyId: companyId, channel: name, from: from, text: text, now: now, replyTo: replyTo).message
    }

    public func postDetailed(companyId: String, channel name: String, from: Sender, text: String, now: Date = .now,
                             replyTo: String? = nil) throws -> PostResult {
        try store.writer.write { db in
            try post(db: db, companyId: companyId, channel: name, from: from, text: text, now: now, replyTo: replyTo)
        }
    }

    /// `replyTo` as for `post`: a message of this DM.
    public func sendDM(companyId: String, from: Sender, to handle: String, text: String, now: Date = .now,
                       replyTo: String? = nil) throws -> Message {
        try store.writer.write { db in
            try sendDM(db: db, companyId: companyId, from: from, to: handle, text: text, now: now, replyTo: replyTo)
        }
    }

    /// In-transaction `post`, for callers that already hold a write transaction.
    func post(db: Database, companyId: String, channel name: String, from: Sender, text: String, now: Date,
              replyTo: String? = nil) throws -> PostResult {
        let normalized = Store.normalizeChannelName(name)
        try validate(from, companyId: companyId, db)
        guard let channel = try Channel.filter(Column("companyId") == companyId && Column("name") == normalized).fetchOne(db)
        else { throw RouterError.unknownChannel(normalized) }
        if case .agent = from {
            let isMember = try ChannelMember.filter(Column("channelId") == channel.id && Column("member") == from.id).fetchCount(db) > 0
            guard isMember else { throw RouterError.notAMember }
        }
        let parentId = try replyTo.map {
            try Store.replyRoot(db: db, companyId: companyId, channelId: channel.id, reference: $0, sender: from, catalog: store.catalog)
        }
        return try deliver(db, channel: channel, from: from, text: text, now: now, parentId: parentId)
    }

    /// In-transaction `sendDM`.
    @discardableResult
    func sendDM(db: Database, companyId: String, from: Sender, to handle: String, text: String, now: Date,
                replyTo: String? = nil) throws -> Message {
        let target = handle.hasPrefix("@") ? String(handle.dropFirst()).lowercased() : handle.lowercased()
        try validate(from, companyId: companyId, db)
        let toMember: String
        if target == "owner" {
            toMember = "owner"
        } else {
            guard let agent = try Agent.filter(Column("companyId") == companyId && Column("name") == target).fetchOne(db)
            else { throw RouterError.unknownAgent(target) }
            toMember = agent.id
        }
        let fromHandle = try senderHandle(from, db)
        guard fromHandle != target else { throw RouterError.invalidSender }
        let channelName = "dm:" + [fromHandle, target].sorted().joined(separator: ":")
        let existingDM = try Channel.filter(Column("companyId") == companyId && Column("name") == channelName).fetchOne(db)
        // Checked before a first DM creates its channel: nothing can be in a conversation that doesn't exist yet.
        let parentId = try replyTo.map {
            try Store.replyRoot(db: db, companyId: companyId, channelId: existingDM?.id, reference: $0, sender: from, catalog: store.catalog)
        }
        let channel: Channel
        if let existing = existingDM {
            let parties = Set([from.id, toMember])
            let actual = Set(try String.fetchAll(db, sql: "SELECT member FROM channelMember WHERE channelId = ?",
                                                 arguments: [existing.id]))
            guard existing.kind == .dm, actual == parties else { throw RouterError.invalidChannel(channelName) }
            channel = existing
        } else {
            channel = try Store.insertChannel(db, companyId: companyId, name: channelName, kind: .dm,
                                              members: [from.id, toMember], now: now)
        }
        return try deliver(db, channel: channel, from: from, text: text, now: now, parentId: parentId).message
    }

    private func validate(_ sender: Sender, companyId: String, _ db: Database) throws {
        guard case .agent(let id) = sender else { return }
        guard let agent = try Agent.fetchOne(db, key: id), agent.companyId == companyId, agent.state != .killed
        else { throw RouterError.invalidSender }
    }

    private func senderHandle(_ sender: Sender, _ db: Database) throws -> String {
        switch sender {
        case .owner: return "owner"
        case .system: return "system"
        case .agent(let id):
            guard let a = try Agent.fetchOne(db, key: id) else { throw StoreError.notFound }
            return a.name
        }
    }

    /// Inserts the message, fans out inbox items (waking or not, by `WakePolicy`), wakes the waking recipients and logs the
    /// event, inside the caller's transaction. A reply (`parentId`, its thread's root) updates the thread's counters first and
    /// is woken by `WakePolicy.threadWakes`; the reply that caps its thread is followed by @system's one `ThreadPolicy.capNote`.
    private func deliver(_ db: Database, channel: Channel, from: Sender, text: String, now: Date, parentId: String? = nil,
                         kind: MessageKind = .text) throws -> PostResult {
        let text = try store.redact(text)
        // Task 10: agent text that claims to be the owner is flagged (digest prefix, activity, the app's chip); it never acts.
        let impersonates = OwnerImpersonation.flags(text: text, sender: from)
        // Plan C: every agent-authored message carries its session's taint as it stands now (ML's `currentTaint`; an agent row
        // that can't be read counts as tainted).
        var sessionTaint: String?
        if case .agent(let id) = from { sessionTaint = try Store.currentTaint(db: db, agentId: id, home: store.dataHome) }
        let message = Message(id: UUID().uuidString, companyId: channel.companyId, channelId: channel.id,
                              senderId: from.id, text: text, createdAt: now,
                              flag: impersonates ? OwnerImpersonation.flag : nil,
                              taintedOrigin: try store.writesTainted(db: db, actorId: from.id), kind: kind,
                              fromTaintedSession: sessionTaint != nil, taintSource: sessionTaint, parentId: parentId)
        try message.insert(db)

        // C3a: the thread's counters move with the reply, in this transaction, before anyone's wake is decided.
        var thread: (capped: Bool, newlyCapped: Bool, rootAuthorId: String)?
        if let parentId {
            let stat = try Store.recordThreadReply(db: db, companyId: channel.companyId, rootId: parentId, sender: from, now: now)
            let author = try String.fetchOne(db, sql: "SELECT senderId FROM message WHERE companyId = ? AND id = ?",
                                             arguments: [channel.companyId, parentId]) ?? ""
            thread = (stat.capped, stat.newlyCapped, author)
        }

        var recipientIds = try String.fetchAll(db, sql: "SELECT member FROM channelMember WHERE channelId = ? ORDER BY rowid",
                                               arguments: [channel.id]).filter { $0 != "owner" && $0 != "system" && $0 != from.id }
        var mentionedIds = Set<String>()
        for mention in Self.mentions(in: text) where mention != "owner" {
            if let a = try Agent.filter(Column("companyId") == channel.companyId && Column("name") == mention).fetchOne(db),
               a.state != .killed, a.id != from.id {
                mentionedIds.insert(a.id)
                if !recipientIds.contains(a.id) { recipientIds.append(a.id) }
            }
        }

        // A broadcast is applied only for the owner or a rate-limited manager/executive.
        var broadcast = WakePolicy.broadcast(in: text)
        var applied: Bool?
        var refusal: String?
        var senderTeam: String?
        if case .agent(let id) = from { senderTeam = try Agent.fetchOne(db, key: id)?.team }
        if let requested = broadcast {
            let label = requested == .here ? "@here" : "@team"
            var allowed = false
            // C3a: a thread reply wakes only by `threadWakes`; a broadcast in one is never applied (nor counted).
            switch from {
            case _ where thread != nil: allowed = false
            case .owner: allowed = true
            case .system: allowed = false
            case .agent(let id):
                if let agent = try Agent.fetchOne(db, key: id) {
                    let kind = store.catalog.template(role: agent.role, pack: try Company.fetchOne(db, key: agent.companyId)?.packId ?? "software").kind
                    let recent = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM broadcastLog WHERE senderId = ? AND createdAt > ?",
                                                  arguments: [id, now.addingTimeInterval(-3600)]) ?? 0
                    allowed = (kind == .manager || kind == .executive) && recent < WakePolicy.broadcastsPerHour
                }
            }
            if allowed {
                try db.execute(sql: "INSERT INTO broadcastLog (companyId, senderId, createdAt) VALUES (?, ?, ?)",
                               arguments: [channel.companyId, from.id, now])
                applied = true
            } else {
                broadcast = nil
                applied = false
                if from != .system {
                    refusal = thread != nil
                        ? "\(label) was not applied: a thread reply wakes only its root's author, @mentioned teammates and DM parties."
                        : "\(label) was not applied: only managers and executives can broadcast, \(WakePolicy.broadcastsPerHour) per hour."
                }
            }
        }

        for id in recipientIds {
            guard let agent = try Agent.fetchOne(db, key: id) else { continue }
            var blockedOnSender = false
            if agent.state == .blocked {
                switch agent.blocker {
                case .agent(let blockerId)?: blockedOnSender = from == .agent(blockerId)
                case .owner?: blockedOnSender = from == .owner
                default: break
                }
            }
            let wakes: Bool
            if let thread {
                // A reply from whoever a blocked agent waits on still wakes it (as outside a thread), unless the thread is capped.
                wakes = WakePolicy.threadWakes(sender: from, recipientId: id, rootAuthorId: thread.rootAuthorId,
                                               mentioned: mentionedIds.contains(id), isDM: channel.kind == .dm, capped: thread.capped)
                    || (blockedOnSender && !thread.capped)
            } else {
                wakes = WakePolicy.wakes(channel: channel, sender: from, recipient: agent, mentioned: mentionedIds.contains(id),
                                         broadcast: broadcast, senderTeam: senderTeam, blockedOnSender: blockedOnSender)
            }
            try InboxItem(id: nil, agentId: id, messageId: message.id, deliveredTurnId: nil, wakes: wakes).insert(db)
            guard wakes, agent.state != .killed, !agent.paused else { continue }
            // Sleeping agents wake; a blocked agent wakes only on a reply from whoever it waits on.
            if agent.state == .sleeping || (agent.state == .blocked && blockedOnSender) {
                try Store.transition(db: db, agentId: id, to: .ready, now: now)
            }
        }

        let handle = try senderHandle(from, db)
        var eventAgent: String? = nil
        if case .agent(let id) = from { eventAgent = id }
        try ActivityEvent(companyId: channel.companyId, agentId: eventAgent, turnId: nil, kind: .message,
                          text: "#\(channel.name) @\(handle): \(text.prefix(200))", createdAt: now).insert(db)
        if impersonates {
            try ActivityEvent(companyId: channel.companyId, agentId: eventAgent, turnId: nil, kind: .error,
                              text: "@\(handle)'s message in #\(channel.name) claims to be the owner; flagged unverified (it changes nothing)",
                              createdAt: now).insert(db)
        }
        if let parentId, thread?.newlyCapped == true {
            _ = try deliver(db, channel: channel, from: .system, text: ThreadPolicy.capNote, now: now, parentId: parentId, kind: .system)
        }
        return PostResult(message: message, broadcastApplied: applied, broadcastRefusal: refusal)
    }

    /// Lowercased handles from `@handle` tokens (`[a-z0-9_-]+`); an `@` glued to a preceding word (an email) is ignored.
    static func mentions(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_])@([A-Za-z0-9_-]+)") else { return [] }
        let ns = text as NSString
        var seen: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var h = ns.substring(with: m.range(at: 1)).lowercased()
            while h.hasSuffix("-") || h.hasSuffix("_") { h.removeLast() }
            if !h.isEmpty, !seen.contains(h) { seen.append(h) }
        }
        return seen
    }
}
