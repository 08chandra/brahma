import Foundation
import Observation
import BrahmaCore

@MainActor @Observable
public final class AppModel {
    public let store: Store
    public let paths: BrahmaPaths
    @ObservationIgnored private let clock: @Sendable () -> Date

    public private(set) var snapshot: Snapshot = .empty
    public private(set) var loaded = false
    public private(set) var activity: [ActivityEvent] = []
    public private(set) var selectedCompanyId: String?
    public private(set) var sidebarSelection: SidebarItem = .missionControl
    public var selectedAgentId: String?
    public var presentedSheet: AppSheet?
    public var errorMessage: String?

    /// The embedded engine, when this app hosts one. Set by the app delegate.
    public var engine: EngineHost?

    @ObservationIgnored private var ticksSinceTakeoverCheck = 0
    @ObservationIgnored private var cursor: Int64 = 0
    @ObservationIgnored private var ticksSinceSnapshot = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    private static let activityCap = 500

    public init(store: Store, paths: BrahmaPaths, clock: @escaping @Sendable () -> Date = { .now }) {
        self.store = store
        self.paths = paths
        self.clock = clock
    }

    public var selectedCompany: CompanySummary? {
        snapshot.companies.first { $0.id == selectedCompanyId }
    }

    public var sidebar: SidebarSections {
        SidebarSections(channels: snapshot.channels, unread: snapshot.unreadByChannel)
    }

    public var usageLine: String { UsageText.line(snapshot.usage, now: clock()) }

    public var usageGateLine: String? {
        guard let mode = selectedCompany?.company.usageMode else { return nil }
        return UsageText.gateLine(snapshot.usage, mode: mode, now: clock())
    }

    // MARK: Loading and polling

    public func load() async {
        let store = self.store
        do {
            let (cursor, firstId) = try await Task.detached {
                (try store.maxEventId(), try store.companies().first?.id)
            }.value
            self.cursor = cursor
            selectedCompanyId = firstId
            try await reloadSelected()
            loaded = true
        } catch {
            report(error)
        }
    }

    public func tick(forceSnapshot: Bool = false) async {
        // Independent of the snapshot cadence: about every 5 s at the 500 ms poll, try to take over from a
        // terminal `brahma run` that has stopped.
        ticksSinceTakeoverCheck += 1
        if ticksSinceTakeoverCheck >= 10 {
            ticksSinceTakeoverCheck = 0
            if let engine, engine.status == .external { await engine.retryTakeover() }
        }
        let store = self.store
        let start = cursor
        do {
            let events: [ActivityEvent] = try await Task.detached {
                var all: [ActivityEvent] = []
                var cur = start
                var batch: [ActivityEvent]
                repeat {
                    batch = try store.events(afterId: cur, limit: 500)
                    all += batch
                    cur = batch.last?.id ?? cur
                } while batch.count == 500
                return all
            }.value
            if let last = events.last?.id { cursor = max(cursor, last) }
            // Selection may have changed during the await: filter by the current company and skip anything
            // the selection reload already put in the feed.
            let newest = activity.last?.id ?? 0
            let mine = events.filter { $0.companyId == selectedCompanyId && ($0.id ?? 0) > newest }
            if !mine.isEmpty {
                activity += mine
                if activity.count > Self.activityCap { activity.removeFirst(activity.count - Self.activityCap) }
            }
            ticksSinceSnapshot += 1
            if forceSnapshot || !events.isEmpty || ticksSinceSnapshot >= 4 {
                try await refreshSnapshot()
            }
        } catch {
            report(error)
        }
    }

    public func startPolling(interval: Duration = .milliseconds(500)) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Selection

    public func selectCompany(_ id: String) async {
        selectedCompanyId = id
        sidebarSelection = .missionControl
        selectedAgentId = nil
        activity = []
        do { try await reloadSelected() } catch { report(error) }
    }

    public func select(_ item: SidebarItem) { sidebarSelection = item }

    /// Applies a launch/automation target, resolving names against the current snapshot.
    public func apply(_ target: SelectTarget) {
        switch target {
        case .missionControl: select(.missionControl)
        case .activity: select(.activity)
        case .agents: select(.agents)
        case .agent(let handle):
            select(.agents)
            selectedAgentId = snapshot.agents.first { $0.name.lowercased() == handle }?.id
        case .channel(let name):
            if let c = snapshot.channels.first(where: { $0.name.lowercased() == name }) {
                select(.channel(id: c.id))
            } else {
                errorMessage = "No channel #\(name)"
            }
        case .dm(let handle): select(.dm(handle: handle))
        case .search: break  // Task 6
        case .sheet(let s): presentedSheet = s
        }
    }

    // MARK: Actions

    public func createCompany(_ form: CompanyForm) async throws -> Company {
        if let message = form.validate() { throw FormError.invalid(message) }
        let name = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = form.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let store = self.store, root = paths.workspaces
        let company = try await Task.detached { try store.createCompany(name: name, goal: goal, workspacesRoot: root) }.value
        await selectCompany(company.id)
        return company
    }

    public func setUsageMode(_ mode: UsageMode) async {
        guard let id = selectedCompanyId else { return }
        await mutate(id) { $0.usageMode = mode }
    }

    public func setCompanyRunning(_ running: Bool, companyId: String) async {
        await mutate(companyId) { $0.status = running ? .running : .paused }
    }

    // MARK: Internals

    private func mutate(_ companyId: String, _ change: @escaping @Sendable (inout Company) -> Void) async {
        let store = self.store
        do {
            _ = try await Task.detached { try store.updateCompany(id: companyId, change) }.value
            await tick(forceSnapshot: true)
        } catch {
            report(error)
        }
    }

    private func reloadSelected() async throws {
        let store = self.store
        let id = selectedCompanyId
        let recent: [ActivityEvent] = try await Task.detached {
            guard let id else { return [] }
            return try store.recentEvents(companyId: id, limit: 200)
        }.value
        // Keep the cursor ahead of anything already loaded so a tick never replays it.
        if let last = recent.last?.id, last > cursor { cursor = last }
        guard id == selectedCompanyId else { return }
        activity = recent
        try await refreshSnapshot()
    }

    private func refreshSnapshot() async throws {
        let store = self.store
        let id = selectedCompanyId
        let new = try await Task.detached { try Snapshot.load(store: store, selectedCompanyId: id) }.value
        guard id == selectedCompanyId else { return }  // selection changed mid-load: the stale snapshot is dropped
        if new != snapshot { snapshot = new }
        ticksSinceSnapshot = 0
    }

    private func report(_ error: Error) {
        errorMessage = "Couldn't read the Brahma database: \(error)"
    }
}
