import Foundation
import Observation
import BrahmaCore

@MainActor @Observable
public final class AppModel {
    public private(set) var store: Store
    public let paths: BrahmaPaths
    @ObservationIgnored private let clock: @Sendable () -> Date

    public private(set) var snapshot: Snapshot = .empty
    public private(set) var loaded = false
    public private(set) var activity: [ActivityEvent] = []
    public private(set) var selectedCompanyId: String?
    public private(set) var sidebarSelection: SidebarItem = .missionControl
    /// The open channel or DM, nil for every other sidebar selection.
    public private(set) var chat: ChatModel?
    public var selectedAgentId: String?
    public var presentedSheet: AppSheet?
    public var errorMessage: String?
    /// A standing startup warning (e.g. the dev/demo owner-key store is in use), shown above the detail pane.
    public var startupNotice: String?
    /// Shown while this process cannot read every secret (agents are paused): "Load secrets" asks the owner (`loadSecrets`).
    public internal(set) var secretsBanner: String?
    /// The interactive secret store for the owner's Load secrets action (set by the app; nil in tests unless given).
    @ObservationIgnored public var ownerSecretVault: (any SecretVault)?
    public var activityFilter: ActivityFilter = .all
    /// The item open in the backlog's detail pane (`item:<KEY>`).
    public var selectedItemKey: String?
    /// Backlog: also list Done items.
    public var showDoneItems = false
    /// Board: only this sprint's items; nil shows them all.
    public var boardSprintId: String?
    public private(set) var search: SearchModel
    /// The message to scroll to and tint after opening a search hit; the chat view clears it after 2 s.
    public var highlightedMessageId: String?
    /// The ask a notification banner pointed at (set by `ask:<id>`); the Inbox calls it out.
    public var highlightedAskId: String?

    /// The embedded engine, when this app hosts one. Set by the app delegate.
    public var engine: EngineHost?
    /// Runs after each tick that read the database without error.
    @ObservationIgnored public var afterTick: (@MainActor () async -> Void)?
    /// Posts owner banners. Nil in headless runs and before the app has set one up: nothing is delivered or marked then.
    @ObservationIgnored public var poster: (any NotificationPosting)?
    @ObservationIgnored var ticksSinceDelivery = 0
    @ObservationIgnored var delivering = false

    @ObservationIgnored private var ticksSinceTakeoverCheck = 0
    @ObservationIgnored private var cursor: Int64 = 0
    @ObservationIgnored private var ticksSinceSnapshot = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// The DB-read error of the current failure streak; an identical one is not re-raised every tick.
    @ObservationIgnored private var lastDBError: String?

    private static let activityCap = 500
    /// Owner notices are planned on every 4th tick (about every 2 s at the default poll).
    static let deliveryEvery = 4

    public init(store: Store, paths: BrahmaPaths, clock: @escaping @Sendable () -> Date = { .now }) {
        self.store = store
        self.paths = paths
        self.clock = clock
        self.search = SearchModel(store: store)
    }

    public var selectedCompany: CompanySummary? {
        snapshot.companies.first { $0.id == selectedCompanyId }
    }

    public var sidebar: SidebarSections {
        SidebarSections(channels: snapshot.channels, unread: snapshot.unreadByChannel)
    }

    public var filteredActivity: [ActivityEvent] {
        activityFilter == .all ? activity : activity.filter { activityFilter.includes($0.kind) }
    }

    /// Selected company's agent id → handle, plus "owner" → "owner".
    public var handles: [String: String] {
        var map = Dictionary(snapshot.agents.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        map["owner"] = "owner"; map["system"] = "system"
        return map
    }

    /// The owner's time zone, read with the last snapshot (every calendar-facing string uses it).
    public var ownerTimeZone: TimeZone { snapshot.work.timeZone }

    public var usageLine: String {
        var line = UsageText.line(snapshot.usage, now: clock(), timeZone: ownerTimeZone)
        if let pace = UsageText.pace(snapshot.work.pace) { line += " · " + pace }
        return line
    }

    public var usageGateLine: String? {
        guard let mode = selectedCompany?.company.usageMode else { return nil }
        return UsageText.gateLine(snapshot.usage, mode: mode, now: clock(), timeZone: ownerTimeZone)
    }

    // MARK: Restore

    /// Starts the engine again on a reopened store (the app delegate sets it: it owns the owner-key store and the tools).
    @ObservationIgnored public var restartEngine: (@MainActor (Store) async -> EngineHost?)?

    /// Stops polling and closes this model's database connections, so a restore can replace the file. Any use of the old
    /// `store` fails until `reopenStore()`.
    public func closeStore() async {
        stopPolling()
        chat = nil
        let store = self.store
        try? await Task.detached { try store.close() }.value
    }

    /// Opens the database again (after a restore), starts from a clean snapshot and re-seeds the activity cursor from the
    /// current maximum, so no event of the restored database is replayed or skipped.
    public func reopenStore() async {
        let (path, backups, catalog) = (paths.database.path, paths.backupsDir, store.catalog)
        do {
            let reopened = try await Task.detached { try Store(path: path, catalog: catalog, backupsDir: backups) }.value
            store = reopened
            search = SearchModel(store: reopened)
            snapshot = .empty
            activity = []
            loaded = false
            await load()
            startPolling()
        } catch {
            report(error)
        }
    }

    /// Restores the database from `snapshot`: stops the engine, closes the store, restores, reopens the store and restarts
    /// the engine. The store is reopened even when the restore fails.
    @discardableResult
    public func restore(from snapshot: URL) async throws -> RestoreOutcome {
        await engine?.stop(timeout: .seconds(15))
        await closeStore()
        let paths = self.paths
        var failure: (any Error)?
        var outcome: RestoreOutcome?
        do {
            outcome = try await Task.detached {
                let service = BackupService(paths: paths)
                return try service.restore(try service.planRestore(snapshot: snapshot))
            }.value
        } catch { failure = error }
        await reopenStore()
        if let restartEngine, let started = await restartEngine(store) { engine = started }
        if let failure { throw failure }
        return outcome!
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
        refreshSecrets()
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
            if events.contains(where: { $0.kind == .message && $0.companyId == selectedCompanyId }) {
                await chat?.refresh()
            }
            ticksSinceSnapshot += 1
            if forceSnapshot || !events.isEmpty || ticksSinceSnapshot >= 4 {
                try await refreshSnapshot()
            }
            lastDBError = nil
            ticksSinceDelivery += 1
            if ticksSinceDelivery >= Self.deliveryEvery {
                ticksSinceDelivery = 0
                await deliverNotices()
            }
            await afterTick?()
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
        chat = nil
        selectedAgentId = nil
        selectedItemKey = nil
        boardSprintId = nil
        activity = []
        search.query = ""
        highlightedMessageId = nil
        do { try await reloadSelected() } catch { report(error) }
    }

    public func select(_ item: SidebarItem) {
        sidebarSelection = item
        let target: ChatTarget?
        switch item {
        case .channel(let id): target = .channel(id: id)
        case .dm(let handle): target = .dm(handle: handle)
        default: target = nil
        }
        guard let target, let companyId = selectedCompanyId else {
            chat = nil
            return
        }
        if chat?.target == target { return }
        let model = ChatModel(store: store, companyId: companyId, target: target)
        chat = model
        Task { await model.refresh() }
    }

    /// Applies a launch/automation target, resolving names against the current snapshot.
    public func apply(_ target: SelectTarget) {
        switch target {
        case .missionControl: select(.missionControl)
        case .activity: select(.activity)
        case .agents: select(.agents)
        case .backlog: select(.backlog)
        case .board: select(.board)
        case .inbox: select(.inbox)
        case .ask(let id):
            select(.inbox)
            highlightedAskId = id
        case .item(let key):
            select(.backlog)
            selectedItemKey = key
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
        case .search(let q):
            search.query = q
            Task { await runSearch() }
        case .sheet(let s): presentedSheet = s
        }
    }

    // MARK: Search

    /// Runs the current search query against the selected company.
    public func runSearch() async {
        guard let companyId = selectedCompanyId else { return }
        do { try await search.run(companyId: companyId) } catch { errorMessage = "Search failed: \(error)" }
    }

    /// Opens the hit's conversation, loads back to the message and highlights it.
    public func open(_ hit: SearchHit) async {
        select(hit.target)
        guard let chat else { return }
        await chat.refresh()
        await chat.ensureLoaded(messageId: hit.id)
        highlightedMessageId = hit.id
        search.query = ""
    }

    // MARK: Actions

    public func createCompany(_ form: CompanyForm) async throws -> Company {
        if let message = form.validate() { throw FormError.invalid(message) }
        let name = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = form.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let store = self.store, root = paths.workspaces
        let count = form.agentCount, packId = form.packId, mode = form.usageMode
        let company = try await Task.detached { () -> Company in
            // The seat budget follows the plan tier (`Store.seatBudget()`); the rest of the shape waits as vacancies.
            let seats = store.seatBudget()
            var company = try store.createCompany(name: name, goal: goal, workspacesRoot: root, packId: packId)
            if count > 0, let pack = store.catalog.pack(packId) {
                let plan = try OrgGenerator.generate(goal: goal, count: count, pack: pack)
                let staffed = OrgGenerator.staff(plan: plan, pack: pack, readyWidth: 0, seatBudget: seats)
                try store.applyOrg(companyId: company.id, plan: staffed.seated, pack: pack, vacancies: staffed.vacancies)
            }
            if mode != company.usageMode { company = try store.updateCompany(id: company.id) { $0.usageMode = mode } }
            return company
        }.value
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

    func report(_ error: Error) {
        let message = "Couldn't read the Brahma database: \(error)"
        // A persistent failure would otherwise re-raise the alert every 500 ms after the owner dismissed it.
        guard message != lastDBError else { return }
        lastDBError = message
        errorMessage = message
    }
}
