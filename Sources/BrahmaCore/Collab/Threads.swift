import Foundation
import GRDB

/// Plan C Task C3a: thread limits (design §5). `read_channel {thread}` shows the root and at most `readLimit` of the latest
/// replies; a thread with `capReplies` agent-only replies within `capWindow` company-active seconds stops waking anyone, and
/// @system replies `capNote` once, until the owner replies in it.
public enum ThreadPolicy {
    public static let readLimit = 30
    public static let capReplies = 8
    public static let capWindow: Double = 3600
    public static let capNote = "This thread is long; record the outcome in an item comment or a hand-off."
}

/// One thread's counters (`threadStat`, keyed by its root): every reply, the agent-only replies of the current cap window (a
/// tumbling window that starts at its first agent reply, in company-active seconds) and when the thread capped.
public struct ThreadStat: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "threadStat"

    public var rootId: String
    public var companyId: String
    public var replies: Int = 0
    public var agentRepliesWindow: Int = 0
    public var windowStartActive: Double? = nil
    public var cappedAt: Date? = nil
}

/// A refused `reply_to` or thread read. A message that is missing, another company's or unreadable to the caller is the one
/// generic answer (`Store.refUnavailable`); only a readable message in another conversation says so.
public enum ThreadError: Error, Equatable, Sendable {
    case unavailable
    case notInConversation(String)

    public var message: String {
        switch self {
        case .unavailable: Store.refUnavailable
        case .notInConversation(let id): "msg:\(id) isn't in this conversation"
        }
    }
}

extension Store {
    /// The root and the latest `ThreadPolicy.readLimit` replies (oldest first) of the thread `rootId` is in (a reply's id reads
    /// its root's thread), and how many earlier replies are left out. `rootId` may be written `msg:<id>` or `thread:<id>`.
    /// Throws `ThreadError.unavailable` unless the message is this company's and `reader` can read it in full.
    public func thread(companyId: String, rootId: String, reader: Reader) throws -> (root: Message, replies: [Message], earlier: Int) {
        try writer.read { db in try Store.thread(db: db, companyId: companyId, rootId: rootId, reader: reader, catalog: catalog) }
    }

    static func thread(db: Database, companyId: String, rootId: String, reader: Reader,
                       catalog: PackCatalog) throws -> (root: Message, replies: [Message], earlier: Int) {
        let target = try readableMessage(db: db, companyId: companyId, reference: rootId, reader: reader, catalog: catalog)
        let root = try target.parentId.map {
            try readableMessage(db: db, companyId: companyId, reference: $0, reader: reader, catalog: catalog)
        } ?? target
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE companyId = ? AND parentId = ?",
                                     arguments: [companyId, root.id]) ?? 0
        let replies = try Message.fetchAll(db, sql: """
            SELECT * FROM message WHERE companyId = ? AND parentId = ? ORDER BY createdAt DESC, rowid DESC LIMIT ?
            """, arguments: [companyId, root.id, ThreadPolicy.readLimit]).reversed()
        return (root, Array(replies), max(0, total - replies.count))
    }

    /// The thread counters of a root, if it has had a reply.
    public func threadStat(companyId: String, rootId: String) throws -> ThreadStat? {
        try writer.read { db in
            try ThreadStat.fetchOne(db, sql: "SELECT * FROM threadStat WHERE companyId = ? AND rootId = ?", arguments: [companyId, rootId])
        }
    }

    /// The roots of the thread replies among `items` that the agent can read in full, by root id: the digest's thread label
    /// shows only these (a mentioned non-member sees the reply, never the root's text).
    public func threadRoots(agentId: String, companyId: String, items: [(InboxItem, Message, Channel)]) throws -> [String: Message] {
        let ids = Set(items.compactMap { $0.1.parentId })
        guard !ids.isEmpty else { return [:] }
        return try writer.read { db in
            var out: [String: Message] = [:]
            for id in ids {
                do {
                    out[id] = try Store.readableMessage(db: db, companyId: companyId, reference: id, reader: .agent(agentId), catalog: catalog)
                } catch ThreadError.unavailable {
                    continue
                }
            }
            return out
        }
    }

    /// The message id an agent names: `msg:<id>`, `thread:<id>` or the bare id; nil when it is not a record id at all.
    static func threadMessageId(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        for prefix in ["msg:", "thread:"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
        return RefGrammar.isRecordId(s) ? s : nil
    }

    /// The message `reference` names in this company that `reader` can read in full (`RefAccess`, the message's channel or DM);
    /// `reader` nil is the engine, which reads every message of the company. Anything else is `ThreadError.unavailable`.
    static func readableMessage(db: Database, companyId: String, reference: String, reader: Reader?,
                                catalog: PackCatalog) throws -> Message {
        guard let id = threadMessageId(reference),
              let message = try Message.fetchOne(db, sql: "SELECT * FROM message WHERE companyId = ? AND id = ?",
                                                 arguments: [companyId, id])
        else { throw ThreadError.unavailable }
        if let reader {
            let decision = try RefAccess.canRead(reader, WorkRef(kind: .message, id: message.id), companyId: companyId, db: db,
                                                 catalog: catalog)
            guard case .allowed = decision else { throw ThreadError.unavailable }
        }
        return message
    }

    /// The root a reply to `reference` joins in the channel `channelId` (a reply to a reply joins its root). The sender must be
    /// able to read the target, and the target must be in the same channel or DM (`channelId` nil: a DM not yet created, which
    /// holds nothing).
    static func replyRoot(db: Database, companyId: String, channelId: String?, reference: String, sender: Sender,
                          catalog: PackCatalog) throws -> String {
        let reader: Reader?
        switch sender {
        case .owner: reader = .owner
        case .agent(let id): reader = .agent(id)
        case .system: reader = nil
        }
        let target = try readableMessage(db: db, companyId: companyId, reference: reference, reader: reader, catalog: catalog)
        guard target.channelId == channelId else { throw ThreadError.notInConversation(target.id) }
        return target.parentId ?? target.id
    }

    /// `threadStat` upkeep for one reply, in the post's transaction: the owner's reply un-caps the thread and resets its window;
    /// an agent's reply counts in the current window (a new one starts when the last started more than `capWindow` active
    /// seconds ago) and caps the thread at `capReplies`; the engine's replies count only as replies. Returns whether the thread
    /// is capped with this reply, and whether this reply capped it.
    static func recordThreadReply(db: Database, companyId: String, rootId: String, sender: Sender,
                                  now: Date) throws -> (capped: Bool, newlyCapped: Bool) {
        var stat = try ThreadStat.fetchOne(db, sql: "SELECT * FROM threadStat WHERE companyId = ? AND rootId = ?",
                                           arguments: [companyId, rootId])
            ?? ThreadStat(rootId: rootId, companyId: companyId)
        stat.replies += 1
        var newlyCapped = false
        switch sender {
        case .owner:
            stat.cappedAt = nil
            stat.agentRepliesWindow = 0
            stat.windowStartActive = nil
        case .system:
            break
        case .agent:
            let active = try Store.activeNow(db: db, companyId: companyId)
            if let start = stat.windowStartActive, active - start <= ThreadPolicy.capWindow {
                stat.agentRepliesWindow += 1
            } else {
                stat.windowStartActive = active
                stat.agentRepliesWindow = 1
            }
            if stat.cappedAt == nil, stat.agentRepliesWindow >= ThreadPolicy.capReplies {
                stat.cappedAt = now
                newlyCapped = true
            }
        }
        try stat.save(db)
        return (stat.cappedAt != nil, newlyCapped)
    }
}
