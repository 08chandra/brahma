import Foundation
import GRDB

public enum RouterError: Error, Equatable {
    case unknownChannel(String)
    case unknownAgent(String)
    case notAMember
    /// Sender is an unknown, killed or other-company agent, or a DM to oneself.
    case invalidSender
}

public struct MessageRouter: Sendable {
    public let store: Store

    public init(store: Store) { self.store = store }

    public func post(companyId: String, channel name: String, from: Sender, text: String, now: Date = .now) throws -> Message {
        let normalized = Store.normalizeChannelName(name)
        return try store.writer.write { db in
            try validate(from, companyId: companyId, db)
            guard let channel = try Channel.filter(Column("companyId") == companyId && Column("name") == normalized).fetchOne(db)
            else { throw RouterError.unknownChannel(normalized) }
            if from != .owner {
                let isMember = try ChannelMember.filter(Column("channelId") == channel.id && Column("member") == from.id).fetchCount(db) > 0
                guard isMember else { throw RouterError.notAMember }
            }
            return try deliver(db, channel: channel, from: from, text: text, now: now)
        }
    }

    public func sendDM(companyId: String, from: Sender, to handle: String, text: String, now: Date = .now) throws -> Message {
        let target = handle.hasPrefix("@") ? String(handle.dropFirst()).lowercased() : handle.lowercased()
        return try store.writer.write { db in
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
            let channel: Channel
            if let existing = try Channel.filter(Column("companyId") == companyId && Column("name") == channelName).fetchOne(db) {
                channel = existing
            } else {
                channel = try Store.insertChannel(db, companyId: companyId, name: channelName, kind: .dm,
                                                  members: [from.id, toMember], now: now)
            }
            return try deliver(db, channel: channel, from: from, text: text, now: now)
        }
    }

    private func validate(_ sender: Sender, companyId: String, _ db: Database) throws {
        guard case .agent(let id) = sender else { return }
        guard let agent = try Agent.fetchOne(db, key: id), agent.companyId == companyId, agent.state != .killed
        else { throw RouterError.invalidSender }
    }

    private func senderHandle(_ sender: Sender, _ db: Database) throws -> String {
        switch sender {
        case .owner: return "owner"
        case .agent(let id):
            guard let a = try Agent.fetchOne(db, key: id) else { throw StoreError.notFound }
            return a.name
        }
    }

    /// Inserts the message, fans out inbox items, wakes recipients and logs the event, inside the caller's transaction.
    private func deliver(_ db: Database, channel: Channel, from: Sender, text: String, now: Date) throws -> Message {
        let message = Message(id: UUID().uuidString, companyId: channel.companyId, channelId: channel.id,
                              senderId: from.id, text: text, createdAt: now)
        try message.insert(db)

        var recipientIds = try String.fetchAll(db, sql: "SELECT member FROM channelMember WHERE channelId = ? ORDER BY rowid",
                                               arguments: [channel.id]).filter { $0 != "owner" && $0 != from.id }
        for mention in Self.mentions(in: text) where mention != "owner" {
            if let a = try Agent.filter(Column("companyId") == channel.companyId && Column("name") == mention).fetchOne(db),
               a.state != .killed, a.id != from.id, !recipientIds.contains(a.id) {
                recipientIds.append(a.id)
            }
        }

        for id in recipientIds {
            guard let agent = try Agent.fetchOne(db, key: id) else { continue }
            try InboxItem(id: nil, agentId: id, messageId: message.id, deliveredTurnId: nil).insert(db)
            guard agent.state != .killed, !agent.paused else { continue }
            let wake: Bool
            switch (agent.state, agent.blocker) {
            case (.sleeping, _): wake = true
            case (.blocked, .agent(let blockerId)?): wake = from == .agent(blockerId)
            case (.blocked, .owner?): wake = from == .owner
            default: wake = false
            }
            if wake { try Store.transition(db: db, agentId: id, to: .ready, now: now) }
        }

        let handle = try senderHandle(from, db)
        var eventAgent: String? = nil
        if case .agent(let id) = from { eventAgent = id }
        try ActivityEvent(companyId: channel.companyId, agentId: eventAgent, turnId: nil, kind: .message,
                          text: "#\(channel.name) @\(handle): \(text.prefix(200))", createdAt: now).insert(db)
        return message
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
