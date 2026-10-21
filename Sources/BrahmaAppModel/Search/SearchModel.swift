import Foundation
import Observation
import BrahmaCore

public struct SearchHit: Equatable, Identifiable, Sendable {
    public var message: Message
    public var channelTitle: String
    /// "owner" or the agent's handle.
    public var senderHandle: String
    /// `.channel(id:)` for a channel or agent DM, `.dm(handle:)` for an owner DM.
    public var target: SidebarItem
    public var id: String

    public var isOwner: Bool { senderHandle == "owner" }
}

@MainActor @Observable
public final class SearchModel {
    public nonisolated static let limit = 50

    public var query = ""
    public private(set) var hits: [SearchHit] = []
    public private(set) var isSearching = false

    @ObservationIgnored private let store: Store
    @ObservationIgnored private var generation = 0

    public init(store: Store) { self.store = store }

    /// Searches `companyId` for the trimmed query. A blank query clears the hits without querying.
    public func run(companyId: String) async throws {
        generation += 1
        let gen = generation
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            hits = []
            isSearching = false
            return
        }
        isSearching = true
        defer { if gen == generation { isSearching = false } }
        let store = self.store
        let found = try await Task.detached { try Self.search(store: store, companyId: companyId, query: q) }.value
        guard gen == generation else { return }  // a newer run (or a clear) superseded this one
        hits = found
    }

    private nonisolated static func search(store: Store, companyId: String, query: String) throws -> [SearchHit] {
        let messages = try store.searchMessages(companyId: companyId, query: query, limit: limit)
        guard !messages.isEmpty else { return [] }
        let channels = Dictionary(try store.channels(companyId: companyId).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let agents = Dictionary(try store.agents(companyId: companyId).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return messages.compactMap { m in
            guard let channel = channels[m.channelId] else { return nil }
            let sender = m.senderId == "owner" ? "owner" : (m.senderId == "system" ? "system" : agents[m.senderId] ?? "unknown")
            return SearchHit(message: m, channelTitle: ChannelTitle.title(channel), senderHandle: sender,
                             target: target(for: channel), id: m.id)
        }
    }

    private nonisolated static func target(for channel: Channel) -> SidebarItem {
        guard channel.kind == .dm else { return .channel(id: channel.id) }
        let parts = channel.name.split(separator: ":").map(String.init)
        let handles = parts.first == "dm" ? Array(parts.dropFirst()) : parts
        if handles.contains("owner"), let other = handles.first(where: { $0 != "owner" }) { return .dm(handle: other) }
        return .channel(id: channel.id)
    }
}
