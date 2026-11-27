import Foundation
import Observation
import BrahmaCore

public enum ChatTarget: Hashable, Sendable {
    case channel(id: String)
    case dm(handle: String)
}

public struct ChatMessage: Equatable, Identifiable, Sendable {
    public var message: Message
    /// "owner" or the agent's handle.
    public var senderHandle: String
    public var isOwner: Bool
    public var id: String
    /// Plan C (C4c, Ruling 60): the concierge's answer, labelled as the concierge's and never as engine text.
    public var isConcierge = false
}

@MainActor @Observable
public final class ChatModel {
    public nonisolated static let pageSize = 200

    public let target: ChatTarget
    public private(set) var channel: Channel?
    public private(set) var messages: [ChatMessage] = []
    public private(set) var hasEarlier = false
    public private(set) var sendError: String?
    public var draft = ""
    /// True while a send is in flight; a second Return in that window is ignored instead of posting twice.
    public private(set) var isSending = false
    /// Files, folders and links dropped on this conversation's composer (an owner DM or a channel; nil where the owner can't
    /// drop). While any is pending, Send commits them with the typed text as one message (`ResourceDropModel.commit`).
    public var drops: ResourceDropModel?
    /// Plan C: the message the next send replies to (`msg:<id>` or the bare id), set by "Reply in thread".
    public var replyTo: String?
    /// Plan C: the cards of each message's attached refs (shares, quotes, inline chips), by message id, from `cardMaker`.
    public private(set) var attachments: [String: [AttachmentCard]] = [:]
    /// Plan C: builds the cards of a message off-main (set by `AppModel`; nil shows no cards).
    @ObservationIgnored public var cardMaker: (@Sendable (Message) throws -> [AttachmentCard])?

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let companyId: String
    private var agents: [Agent] = []
    private var loaded = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pins = 0
    @ObservationIgnored private var isPinned: Bool { pins > 0 }

    public init(store: Store, companyId: String, target: ChatTarget) {
        self.store = store
        self.companyId = companyId
        self.target = target
    }

    // MARK: Derived

    public var title: String {
        if let channel { return ChannelTitle.title(channel) }
        if case .dm(let h) = target { return h == "system" ? h : "@" + h }
        return "Channel"
    }

    public var placeholder: String {
        if let channel, channel.kind == .channel { return "Message #" + channel.name }
        if case .dm(let h) = target { return h == "system" ? "System notices" : "Message @" + h }
        if let channel { return "Message " + ChannelTitle.title(channel) }
        return "Message"
    }

    public var readOnlyReason: String? {
        guard loaded else { return nil }
        switch target {
        case .channel:
            guard let channel else { return "This conversation no longer exists." }
            if channel.kind == .dm, !Self.dmParts(channel.name).contains("owner") {
                return "Agents' private conversation — read only."
            }
            return nil
        case .dm(let h):
            if h.lowercased() == "system" { return "Brahma engine notices can't be replied to" }
            guard let agent = agents.first(where: { $0.name.lowercased() == h.lowercased() }) else {
                return "No agent @\(h) in this company."
            }
            return agent.state == .killed ? "@\(h) was killed — history is read only." : nil
        }
    }

    /// Non-killed agent handles, sorted.
    public var handles: [String] { agents.filter { $0.state != .killed }.map(\.name).sorted() }

    public func role(of handle: String) -> String? {
        agents.first { $0.name == handle }?.role
    }

    public var mentionSuggestions: [String] { MentionCompleter.suggestions(for: draft, handles: handles) }

    public func acceptMention(_ handle: String) { draft = MentionCompleter.complete(draft, with: handle) }

    private static func dmParts(_ name: String) -> [String] {
        let parts = name.split(separator: ":").map(String.init)
        return parts.first == "dm" ? Array(parts.dropFirst()) : parts
    }

    // MARK: Loading

    private struct Loaded: Sendable {
        var channel: Channel?
        var agents: [Agent]
        var messages: [Message]
    }

    private nonisolated static func load(store: Store, companyId: String, target: ChatTarget, limit: Int) throws -> Loaded {
        let agents = try store.agents(companyId: companyId)
        let channel: Channel?
        switch target {
        case .channel(let id):
            channel = try store.channels(companyId: companyId).first { $0.id == id }
        case .dm(let h):
            channel = try store.channel(companyId: companyId, name: "dm:" + ["owner", h.lowercased()].sorted().joined(separator: ":"))
        }
        let messages = try channel.map { try store.messages(channelId: $0.id, limit: limit) } ?? []
        return Loaded(channel: channel, agents: agents, messages: messages)
    }

    private func decorate(_ list: [Message]) -> [ChatMessage] {
        let byId = Dictionary(agents.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return list.map { m in
            let owner = m.senderId == "owner"
            if m.senderId == ConciergeCaps.agentId {
                return ChatMessage(message: m, senderHandle: "Brahma (concierge)", isOwner: false, id: m.id, isConcierge: true)
            }
            return ChatMessage(message: m, senderHandle: owner ? "owner" : (m.senderId == "system" ? "system" : byId[m.senderId] ?? "unknown"), isOwner: owner, id: m.id)
        }
    }

    /// Re-resolves the channel and refetches the newest `max(pageSize, loaded count)` messages.
    public func refresh() async {
        guard !isPinned else { return }
        generation += 1
        let gen = generation
        let n = max(Self.pageSize, messages.count)
        let (store, companyId, target) = (self.store, self.companyId, self.target)
        do {
            // One extra row tells whether anything older exists.
            let result = try await Task.detached { try Self.load(store: store, companyId: companyId, target: target, limit: n + 1) }.value
            guard gen == generation else { return }
            agents = result.agents
            channel = result.channel
            hasEarlier = result.messages.count > n
            messages = decorate(hasEarlier ? Array(result.messages.dropFirst()) : result.messages)
            loaded = true
            await loadAttachments(generation: gen)
        } catch {
            if gen == generation { sendError = "Couldn't load messages: \(error)" }
        }
    }

    public func loadEarlier() async {
        guard let channel, let first = messages.first else { return }
        generation += 1
        let gen = generation
        let store = self.store
        let before = first.message.createdAt
        do {
            let page = try await Task.detached { try store.messages(channelId: channel.id, limit: Self.pageSize, before: before) }.value
            guard gen == generation else { return }
            let known = Set(messages.map(\.id))
            messages = decorate(page.filter { !known.contains($0.id) }) + messages
            hasEarlier = page.count == Self.pageSize
        } catch {
            if gen == generation { sendError = "Couldn't load messages: \(error)" }
        }
    }

    /// Pages earlier until the message is loaded or nothing older remains. Holds off `refresh` meanwhile.
    public func ensureLoaded(messageId: String) async {
        pins += 1
        defer { pins -= 1 }
        generation += 1
        let gen = generation
        let (store, companyId, target) = (self.store, self.companyId, self.target)
        do {
            var list = messages.map(\.message)
            var older = hasEarlier
            var ch = channel
            var ags = agents
            if !loaded {
                let r = try await Task.detached { try Self.load(store: store, companyId: companyId, target: target, limit: Self.pageSize) }.value
                guard gen == generation else { return }
                list = r.messages
                ch = r.channel
                ags = r.agents
                older = r.messages.count == Self.pageSize
            }
            while !list.contains(where: { $0.id == messageId }), older, let channel = ch, let first = list.first {
                let before = first.createdAt
                let page = try await Task.detached { try store.messages(channelId: channel.id, limit: Self.pageSize, before: before) }.value
                guard gen == generation else { return }
                list = page + list
                older = page.count == Self.pageSize
            }
            guard gen == generation else { return }
            agents = ags
            channel = ch
            loaded = true
            hasEarlier = older
            messages = decorate(list)
        } catch {
            if gen == generation { sendError = "Couldn't load messages: \(error)" }
        }
    }

    // MARK: Actions

    @discardableResult
    public func send() async -> Bool {
        guard readOnlyReason == nil, !isSending else { return false }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let drops, !drops.pending.isEmpty { return await sendDrops(drops, text: text) }
        guard !text.isEmpty else { return false }
        let (store, companyId, target) = (self.store, self.companyId, self.target)
        let channelName = channel?.name
        let replyTo = self.replyTo
        // Before the first load a channel target has no name yet: nothing to post to, and nothing gone either.
        if case .channel = target, channelName == nil { return false }
        isSending = true
        defer { isSending = false }
        var refusal: String?
        do {
            refusal = try await Task.detached { () -> String? in
                let router = MessageRouter(store: store)
                switch target {
                case .channel:
                    guard let channelName else { throw RouterError.unknownChannel("") }
                    // Plan C (C3a): a thread reply never broadcasts; the router's refusal of `@here`/`@team` is shown to the owner.
                    return try router.postDetailed(companyId: companyId, channel: channelName, from: .owner, text: text, replyTo: replyTo).broadcastRefusal
                case .dm(let h):
                    _ = try router.sendDM(companyId: companyId, from: .owner, to: h, text: text, replyTo: replyTo)
                    return nil
                }
            }.value
        } catch {
            sendError = Self.describe(error)
            return false
        }
        // Keep anything typed while the send was in flight.
        if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
        self.replyTo = nil
        sendError = refusal
        await refresh()
        await markRead()
        return true
    }

    /// The pending drops and the typed text, as one message the engine composes and posts (`Store.addResources`); a refusal
    /// is shown by the drop model (`AppModel.errorMessage`) and leaves the draft and the drops as they were.
    private func sendDrops(_ drops: ResourceDropModel, text: String) async -> Bool {
        isSending = true
        defer { isSending = false }
        guard await drops.commit(message: text) else { return false }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
        sendError = nil
        await refresh()
        await markRead()
        return true
    }

    private static func describe(_ error: Error) -> String {
        switch error as? RouterError {
        case .unknownChannel(let n)?: return "#\(n) no longer exists."
        case .unknownAgent(let h)?: return "No agent @\(h) in this company."
        default: return "Couldn't send: \(error)"
        }
    }

    /// Plan C: the cards of the loaded messages that carry refs (shares, answers, attachments, inline chips), built off-main by
    /// `cardMaker`; a message's cards are kept once built. Dropped when a newer load superseded this one.
    func loadAttachments(generation gen: Int) async {
        guard let maker = cardMaker else { return }
        let wanted = messages.map(\.message).filter { attachments[$0.id] == nil }
        guard !wanted.isEmpty else { return }
        let built: [(String, [AttachmentCard])] = await Task.detached {
            wanted.compactMap { m in (try? maker(m)).map { (m.id, $0) } }
        }.value
        guard gen == generation else { return }
        for (id, cards) in built { attachments[id] = cards }
    }

    /// Marks everything up to the newest loaded message as read.
    public func markRead() async {
        guard let channel, let newest = messages.last?.message.createdAt else { return }
        let store = self.store
        do {
            try await Task.detached { try store.markRead(channelId: channel.id, upTo: newest) }.value
        } catch {
            sendError = "Couldn't mark as read: \(error)"
        }
    }
}
