import Foundation
import Observation
import BrahmaCore

/// What the MEMORY tab lists.
public struct MemoryBrowserFilter: Equatable, Sendable {
    /// Entries written by, or private to, this agent.
    public var agentId: String?
    public var kind: MemoryEntryKind?
    /// A case-insensitive substring of the fact.
    public var query = ""
    /// Owner-deleted and removed entries too, as tombstones.
    public var showRemoved = false

    public init(agentId: String? = nil, kind: MemoryEntryKind? = nil, query: String = "", showRemoved: Bool = false) {
        self.agentId = agentId; self.kind = kind; self.query = query; self.showRemoved = showRemoved
    }
}

/// One memory entry as the owner's table shows it. The fact is agent-written and rendered verbatim; a deleted entry's is
/// `[purged]` (its text is gone from the database).
public struct MemoryRow: Equatable, Identifiable, Sendable {
    public var id: String
    /// `mem:<n>`.
    public var ref: String
    public var number: Int
    /// `SEMANTIC` or `EPISODIC`.
    public var kind: String
    /// `FACT`, `PREFERENCE`, `HOWTO`, `PERSON`, `DECISION`, `EPISODE`.
    public var type: String
    /// `company`, `team payments`, `agent @eng-1`, `item ENG-7` …
    public var scope: String
    /// `@handle`, `owner` or `engine`.
    public var author: String
    /// Two decimals.
    public var confidence: String
    /// `yyyy-MM-dd HH:mm` in the owner's zone.
    public var created: String
    public var fact: String
    public var key: String?
    public var isContradicted: Bool
    public var isTainted: Bool
    public var taintReason: String?
    public var isExpired: Bool
    public var isInherited: Bool
    /// Deleted by the owner (purged) or removed.
    public var isRemoved: Bool
    public var isPurged: Bool

    /// `CONTRADICTED`, `TAINTED`, `EXPIRED`, `INHERITED`, then `PURGED` or `REMOVED`.
    public var flags: [String] {
        var out: [String] = []
        if isContradicted { out.append("CONTRADICTED") }
        if isTainted { out.append("TAINTED") }
        if isExpired { out.append("EXPIRED") }
        if isInherited { out.append("INHERITED") }
        if isPurged { out.append("PURGED") } else if isRemoved { out.append("REMOVED") }
        return out
    }

    public var canDelete: Bool { !isPurged }
}

/// Handbook › MEMORY: the owner's browser over remembered facts and recorded episodes, with the owner-only decisions delete
/// (`Store.ownerDeleteMemory`, the secure purge) and inherit (`Store.inheritMemory`, from killed agents only). Never
/// `CompanyTools`.
@MainActor @Observable
public final class MemoryBrowserModel {
    public nonisolated static let limit = 500
    public nonisolated static let inheritNeedsKilled = "Only a killed agent's memory can be handed over."

    /// The delete dialog, exactly.
    public nonisolated static func deleteConfirmText(_ ref: String) -> String {
        "Delete \(ref)? Its text is erased; a tombstone remains."
    }

    public let companyId: String
    public var filter = MemoryBrowserFilter()
    public private(set) var rows: [MemoryRow] = []
    /// Every agent of the company, for the agent filter.
    public private(set) var agents: [Agent] = []
    public private(set) var isLoading = false
    public private(set) var isWorking = false
    /// The entry the owner confirmed deleting in the dialog (`delete(_:)` refuses any other; cleared either way).
    public var confirmDelete: String?
    public var error: String?
    /// The last decision's outcome (`copied 2 entries from @old to @new`).
    public var notice: String?
    /// Runs after a delete or inherit (the app refreshes its snapshot).
    @ObservationIgnored public var afterChange: (@MainActor () async -> Void)?

    @ObservationIgnored private let store: Store
    @ObservationIgnored private var generation = 0

    public init(store: Store, companyId: String) {
        self.store = store
        self.companyId = companyId
    }

    /// Killed agents: the only ones whose private facts the owner can hand over.
    public var inheritSources: [Agent] { agents.filter { $0.state == .killed } }
    /// Agents that can receive them (not killed).
    public var inheritTargets: [Agent] { agents.filter { $0.state != .killed } }

    public func reload() async {
        generation += 1
        let gen = generation
        let (store, companyId, filter) = (self.store, self.companyId, self.filter)
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        do {
            let (rows, agents) = try await Task.detached { try Self.load(store: store, companyId: companyId, filter: filter) }.value
            guard gen == generation else { return }
            self.rows = rows
            self.agents = agents
        } catch {
            guard gen == generation else { return }
            self.error = "Couldn't read memory: \(error)"
        }
    }

    /// Owner: delete `row` for good (the fact is erased, a tombstone stays). Refused unless the dialog set `confirmDelete` to
    /// this row's ref.
    @discardableResult
    public func delete(_ row: MemoryRow) async -> Bool {
        guard confirmDelete == row.ref else {
            error = "Confirm the delete of \(row.ref) first."
            return false
        }
        confirmDelete = nil
        let (store, companyId, number, ref) = (self.store, self.companyId, row.number, row.ref)
        return await decide("delete \(ref)") { () -> (Bool, String) in
            let deleted = try store.ownerDeleteMemory(companyId: companyId, number: number)
            return (true, deleted ? "deleted \(ref)" : "\(ref) was already deleted")
        } ?? false
    }

    /// Owner: copy killed agent `from`'s private facts to `to`. Returns the number copied, or nil when refused.
    @discardableResult
    public func inherit(from: String, to: String) async -> Int? {
        guard inheritSources.contains(where: { $0.id == from }) else {
            error = Self.inheritNeedsKilled
            return nil
        }
        let names = Dictionary(agents.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let (store, companyId) = (self.store, self.companyId)
        return await decide("hand over memory") { () -> (Int, String) in
            // Checked again at the write: the agent may have changed since the list was loaded.
            guard try store.agent(id: from)?.state == .killed else { throw WorkError.invalid(Self.inheritNeedsKilled) }
            let n = try store.inheritMemory(companyId: companyId, from: from, to: to)
            return (n, "copied \(n) memory entr\(n == 1 ? "y" : "ies") from @\(names[from] ?? "?") to @\(names[to] ?? "?")")
        }
    }

    /// Runs one owner decision off-main, then reloads. The body returns its value and the notice line; nil when refused.
    private func decide<T: Sendable>(_ what: String, _ body: @escaping @Sendable () throws -> (T, String)) async -> T? {
        guard !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }
        error = nil
        let value: T
        do {
            let (v, line) = try await Task.detached { try body() }.value
            value = v
            notice = line
        } catch let e as WorkError {
            error = e.message
            return nil
        } catch {
            self.error = "Couldn't \(what): \(error)"
            return nil
        }
        await reload()
        await afterChange?()
        return value
    }

    nonisolated static func load(store: Store, companyId: String, filter: MemoryBrowserFilter) throws -> ([MemoryRow], [Agent]) {
        let agents = try store.agents(companyId: companyId)
        let handles = Dictionary(agents.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let query = filter.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = try store.memoryEntries(companyId: companyId, filter: MemoryEntryFilter(
            agentId: filter.agentId, kind: filter.kind, includeRemoved: filter.showRemoved, query: query.isEmpty ? nil : query,
            limit: limit))
        let activeNow = store.activeNow(companyId: companyId)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = store.ownerTimeZone()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        // A contradiction counts only while the entry that contradicts it is live (an owner delete lifts it). Entries outside
        // this page are looked up only when one is referenced.
        var liveIds = Set(entries.filter { $0.removedAt == nil && $0.purgedAt == nil }.map(\.id))
        if entries.contains(where: { e in e.contradictedById.map { !liveIds.contains($0) } ?? false }) {
            liveIds = Set(try store.memoryEntries(companyId: companyId, filter: MemoryEntryFilter(limit: Int(Int32.max))).map(\.id))
        }
        var labels: [AccessClass: String] = [:]
        let rows: [MemoryRow] = try entries.map { e in
            var scope = e.accessKind
            if let access = e.access {
                if labels[access] == nil { labels[access] = try store.resourceScopeLabel(access, companyId: companyId) }
                scope = labels[access] ?? scope
            }
            let author = e.authorId == "owner" ? "owner" : e.authorId == "system" ? "engine" : "@" + (handles[e.authorId] ?? "unknown")
            let purged = e.purgedAt != nil
            return MemoryRow(
                id: e.id, ref: e.ref, number: e.number, kind: e.kind.rawValue.uppercased(), type: e.type.rawValue.uppercased(),
                scope: scope, author: author, confidence: String(format: "%.2f", e.confidence), created: f.string(from: e.createdAt),
                fact: purged ? "[purged]" : e.fact, key: purged ? nil : e.key,
                isContradicted: e.contradictedById.map(liveIds.contains) ?? false, isTainted: e.tainted, taintReason: e.taintReason,
                isExpired: e.expiresActive.map { $0 <= activeNow } ?? false, isInherited: e.inheritedFromId != nil,
                isRemoved: e.removedAt != nil || purged, isPurged: purged)
        }
        return (rows, agents)
    }
}
