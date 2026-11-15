import Foundation
import BrahmaCore

public enum MapControllerError: Error, Equatable, LocalizedError {
    /// The synthetic (`--map-demo`) company has no store behind it.
    case demoIsReadOnly
    /// The controller was invalidated: the company changed or the store closed.
    case stale
    /// A replay is open: the map shows history, and history is never written.
    case replaying

    public var errorDescription: String? {
        switch self {
        case .demoIsReadOnly: "The demo map is read-only"
        case .stale: "This map belongs to another company"
        case .replaying: "The map is showing a replay; go back to LIVE to change the org"
        }
    }
}

/// A context-menu item on the map. Vacancy handles are the map's (cleaned) vacancy ids; the controller maps them to the
/// raw org handle itself.
public enum MapAction: Equatable, Sendable {
    case message(handle: String)
    case follow(agentId: String)
    case addVacancy(managerHandle: String?)
    case fill(handle: String)
    case removeVacancy(handle: String)
}

/// What filling an open seat would do, shown before the owner confirms. Every string comes from the cleaned vacancy (or
/// through `MapText.clean`).
public struct FillPreview: Equatable, Sendable {
    public var handle: String
    public var roleTitle: String
    public var companyName: String
    public var managerHandle: String?
    public var team: String?

    public static let costLine =
        "This starts a new paid agent. It runs Claude turns, and uses your usage allowance, as soon as it has work."

    public init(handle: String, roleTitle: String, companyName: String, managerHandle: String? = nil, team: String? = nil) {
        self.handle = handle; self.roleTitle = roleTitle; self.companyName = companyName
        self.managerHandle = managerHandle; self.team = team
    }
}

/// The owner's vacancy actions on a live map (Plan 4b Task 7b). Only an open `.org` seat of this live, current controller
/// can be filled or removed, and only through the raw handle `orgVacancyHandles` recorded for it: a provider-supplied id,
/// a cleaned id that differs from its raw handle, the demo and a stale controller never reach the Store.
extension MapController {
    /// The context menu for `hit`, and its only source. Nothing for the demo or an invalidated controller; no vacancy
    /// write while a replay is open (history is never written).
    public func actions(for hit: MapHit) -> [MapAction] {
        guard !isSynthetic, !isInvalidated, liveStore != nil else { return [] }
        switch hit {
        case .agent(let id):
            guard model.agents[id] != nil, let agent = lastSnapshot?.agents.first(where: { $0.id == id }) else { return [] }
            // A former agent (shown with "show former") can be followed, not messaged or given reports.
            guard agent.state != .killed else { return [.follow(agentId: id)] }
            if isReplaying { return [.message(handle: agent.name), .follow(agentId: id)] }
            return [.message(handle: agent.name), .follow(agentId: id), .addVacancy(managerHandle: agent.name)]
        case .owner:
            return isReplaying ? [] : [.addVacancy(managerHandle: nil)]
        case .vacancy(let id):
            return isReplaying || fillPreview(handle: id) == nil ? [] : [.fill(handle: id), .removeVacancy(handle: id)]
        case .stub, .team:
            return []
        }
    }

    /// The preview for the open `.org` seat shown as `handle`; nil for anything else (a provider vacancy, an unknown or
    /// closed seat, the demo, a stale controller).
    public func fillPreview(handle: String) -> FillPreview? {
        guard !isSynthetic, !isInvalidated, liveStore != nil,
              let raw = orgVacancyHandles[handle],
              let row = orgVacancyRows?.first(where: { $0.handle == raw }),
              let vacancy = model.vacancies.first(where: { $0.id == handle }), vacancy.source == .org,
              let company = lastSnapshot?.companies.first(where: { $0.id == companyId })?.company
        else { return nil }
        return FillPreview(handle: vacancy.id, roleTitle: vacancy.roleTitle, companyName: MapText.clean(company.name, max: 40),
                           managerHandle: row.managerHandle.map { MapText.clean($0, max: 40) }, team: vacancy.team)
    }

    /// Adds an open seat (`Store.addVacancy`: the Store validates and redacts the note, fail-closed).
    public func addVacancy(role: String, managerHandle: String?, team: String?, note: String) async throws {
        let store = try writableStore()
        let companyId = self.companyId
        try await Task.detached {
            _ = try store.addVacancy(companyId: companyId, role: role, managerHandle: managerHandle, team: team, note: note)
        }.value
        await poll()
    }

    /// Takes back the open `.org` seat shown as `handle`.
    public func removeVacancy(handle: String) async throws {
        let store = try writableStore()
        let raw = try ownerSeat(handle)
        let companyId = self.companyId
        try await Task.detached { try store.removeVacancy(companyId: companyId, handle: raw) }.value
        await poll()
    }

    /// Hires the open `.org` seat shown as `handle` as the owner (3a's `fillVacancy`): a new paid agent. The new agent and
    /// the closed seat reach the map in one apply.
    public func fillVacancy(handle: String) async throws {
        let store = try writableStore()
        let raw = try ownerSeat(handle)
        let companyId = self.companyId
        let (rows, snapshot) = try await Task.detached { () -> ([OrgVacancy]?, Snapshot?) in
            try store.fillVacancy(companyId: companyId, handle: raw)
            return (try? store.vacancies(companyId: companyId), try? Snapshot.load(store: store, selectedCompanyId: companyId))
        }.value
        if !isInvalidated, let rows { orgVacancyRows = rows }
        if let snapshot {
            sync(snapshot: snapshot)
        } else if !isInvalidated, replay == nil, let last = lastSnapshot {
            model.apply(inputs(for: last, store: store), now: mapNow(), emitEvents: isRunning)
        }
        await poll()
    }

    /// The store an owner write may use: never the demo's (it has none), never a stale controller's, never while a replay
    /// is open.
    private func writableStore() throws -> Store {
        if isSynthetic { throw MapControllerError.demoIsReadOnly }
        guard !isInvalidated, let store = liveStore else { throw MapControllerError.stale }
        if isReplaying { throw MapControllerError.replaying }
        return store
    }

    /// The raw org handle behind the seat shown as `handle`, or `StoreError.notFound` when it is not an open `.org` seat
    /// of this map.
    private func ownerSeat(_ handle: String) throws -> String {
        guard fillPreview(handle: handle) != nil, let raw = orgVacancyHandles[handle] else { throw StoreError.notFound }
        return raw
    }
}
