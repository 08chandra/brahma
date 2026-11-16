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

/// One group of memory-wide results (Plan ML): `ITEMS`, `ASKS`, `HANDBOOK`, `RESOURCES` or `MEMORY`, at most
/// `SearchModel.groupLimit` hits, already filtered by the access engine at owner scope. Hits live in memory only.
public struct SearchGroup: Equatable, Identifiable, Sendable {
    public var title: String
    public var hits: [MemoryHit]
    public var id: String { title }
}

@MainActor @Observable
public final class SearchModel {
    public nonisolated static let limit = 50
    /// Hits per memory group.
    public nonisolated static let groupLimit = 5
    /// The memory groups beside MESSAGES, in display order, with the sources each searches. Messages have their own group
    /// (`hits`); hand-offs and sprint retros are recorded memory, so they sit under MEMORY.
    public nonisolated static let groupSources: [(title: String, sources: Set<MemorySource>)] = [
        ("ITEMS", [.item]),
        ("ASKS", [.ask, .decision]),
        ("HANDBOOK", [.kb]),
        ("RESOURCES", [.resource]),
        ("MEMORY", [.memory, .handoff, .retro]),
    ]
    public nonisolated static var groupOrder: [String] { groupSources.map(\.title) }

    public var query = ""
    public private(set) var hits: [SearchHit] = []
    /// The non-empty memory groups, in `groupOrder`.
    public private(set) var groups: [SearchGroup] = []
    public private(set) var isSearching = false

    @ObservationIgnored private let store: Store
    @ObservationIgnored private var generation = 0
    /// Test seam: runs off-main with the query before a run searches (holds a run to prove stale results are dropped).
    @ObservationIgnored var beforeSearch: (@Sendable (String) async -> Void)?

    public init(store: Store) { self.store = store }

    /// Searches `companyId` for the trimmed query. A blank query clears the hits without querying.
    public func run(companyId: String) async throws {
        generation += 1
        let gen = generation
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            hits = []
            groups = []
            isSearching = false
            return
        }
        isSearching = true
        defer { if gen == generation { isSearching = false } }
        let (store, hook) = (self.store, beforeSearch)
        let (found, groups) = try await Task.detached {
            await hook?(q)
            return (try Self.search(store: store, companyId: companyId, query: q),
                    try Self.searchMemory(store: store, companyId: companyId, query: q))
        }.value
        guard gen == generation else { return }  // a newer run (or a clear) superseded this one (R-243)
        hits = found
        self.groups = groups
    }

    /// One owner-scope `MemoryIndex` search per group, `groupLimit` hits each; empty groups are left out.
    private nonisolated static func searchMemory(store: Store, companyId: String, query: String) throws -> [SearchGroup] {
        let index = MemoryIndex(store: store)
        let now = Store.now()
        return try groupSources.compactMap { group in
            let hits = try index.search(companyId: companyId, scope: .owner, query: query, sources: group.sources,
                                        limit: groupLimit, now: now)
            return hits.isEmpty ? nil : SearchGroup(title: group.title, hits: Array(hits.prefix(groupLimit)))
        }
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
