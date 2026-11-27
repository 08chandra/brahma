import Foundation
import Observation
import BrahmaCore

@MainActor @Observable
public final class AppModel {
    public private(set) var store: Store
    public let paths: BrahmaPaths
    @ObservationIgnored let clock: @Sendable () -> Date

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
    /// The interactive secret store for the owner's Load secrets action, Company › Settings › Secrets and the phone-alert
    /// credentials (set by the app; nil in tests unless given).
    @ObservationIgnored public var ownerSecretVault: (any SecretVault)? {
        didSet { settings.vault = ownerSecretVault }
    }
    /// Provides a requested secret (`Store.provideSecret`, Task 4-wire, through `StoreSecretProvider`). Nil makes the card say
    /// the build cannot provide secrets.
    @ObservationIgnored public var secretProvider: (any SecretProviding)? = StoreSecretProvider()
    /// The owner's `preventSleep` pref (the menu's "Prevent sleep while agents run"); refreshed every tick.
    public internal(set) var preventSleep = OwnerPrefs.defaults.preventSleep
    public var activityFilter: ActivityFilter = .all
    /// The item open in the backlog's detail pane (`item:<KEY>`).
    public var selectedItemKey: String?
    /// Backlog: also list Done items.
    public var showDoneItems = false
    /// Board: only this sprint's items; nil shows them all.
    public var boardSprintId: String?
    public private(set) var search: SearchModel
    /// Settings › Backups.
    public private(set) var backups: BackupsModel
    /// Inbox › Grants and the access cards.
    public private(set) var access: AccessModel
    /// Company › Settings.
    public private(set) var settings: SettingsModel
    /// Inbox › Digest.
    public private(set) var digest: DigestModel
    /// The message to scroll to and tint after opening a search hit; the chat view clears it after 2 s.
    public var highlightedMessageId: String?
    /// The preview pane's tab (a `PreviewTabID`); nil or an unknown id shows the default tab.
    public var selectedPreviewTab: String?
    /// The artifact the ARTIFACTS tab shows (`selectArtifact`); nil or a deleted one shows the newest.
    public var selectedArtifactId: String?
    /// Artifact id → the owner's "PHONE FRAME" choice for a video (Plan 4a); unset keeps `VideoLayout`'s detection. Per company.
    public var phoneFrameOverride: [String: Bool] = [:]
    /// Artifact ids whose page the owner let run scripts ("Enable scripts for this artifact", `setArtifactScripts`): an agent's,
    /// an outside or a tainted HTML artifact runs without them otherwise (`ArtifactScripts`). Read-only outside the model, kept
    /// for this session and company only, never stored, and written by no agent path.
    public internal(set) var scriptEnabledArtifacts: Set<String> = []
    /// An artifact older than the snapshot's newest ones, opened by `artifact:AR-n` (`openArtifact(number:)`); per company.
    var pinnedArtifact: PinnedArtifact?
    /// Shown in the ARTIFACTS tab beside the list (never in its place): the pinned artifact was deleted outside the app
    /// (`checkPinnedArtifact`). Cleared by the next artifact pick, tab pick or a refresh that has something selected.
    public internal(set) var artifactNotice: String?
    /// Bumped by every artifact selection, so a lookup result that lands after the owner picked something else is dropped.
    @ObservationIgnored var artifactSelectionGeneration = 0
    /// Surface id → the parsed OpenAPI copy of a running backend (`refreshOpenAPI`, through `RendererCaps.parse`).
    var openAPICache: [String: OpenAPICacheEntry] = [:]
    /// How a running backend's OpenAPI copy is parsed: `defaultOpenAPIParser` (the hardened read under `RendererCaps.parse`);
    /// tests inject one on a manual clock.
    @ObservationIgnored var openAPIParser: @Sendable (OpenAPICopy) async throws -> [OpenAPIOperation]? = AppModel.defaultOpenAPIParser
    /// The agent whose turn stream some view observes (`observeTurnStream`); loaded off-main per tick only while set.
    public internal(set) var turnStreamAgentId: String?
    var turnStreamCache: TurnStreamCache?
    /// The ask a notification banner pointed at (set by `ask:<id>`); the Inbox calls it out.
    public var highlightedAskId: String?
    /// The release a launch target selected (`release:<ref>`); Work › Releases opens its inspector until the owner picks a row.
    public var selectedReleaseRef: String?
    /// The secret store this app was booted with (`Booted.secretVault`; a `MemoryVault` in tests): resource drops scan against
    /// its values (`Store.knownSecretValues`) and store a dropped file as a secret through it.
    public let secretVault: any SecretVault
    /// Where the resource drops keep the owner's advisory acknowledgments (`advisoryAck.<companyId>`): `.standard` in the app.
    @ObservationIgnored public var dropDefaults: UserDefaults = .standard
    /// The resource the owner confirmed purging in the library's dialog (`purge(resource:)` refuses any other).
    public var confirmPurge: String?
    /// Work › Handbook of the selected company (`ensureHandbook()` makes it; dropped when the company or store changes).
    public internal(set) var handbook: HandbookModel?
    /// Work › Budget › STORAGE (`ensureStorage()` makes it; it follows the selected company and keeps its per-company cache).
    public internal(set) var storage: StorageModel?
    /// How the storage meter sizes the disk (`LiveFileSizing` in the app; tests inject one that touches nothing).
    @ObservationIgnored public var storageSizing: any FileSizing = LiveFileSizing()
    /// The open replay: an agent's day (People › agent inspector › REPLAY) or an item's history (Work › item inspector ›
    /// HISTORY). Dropped when the company or store changes.
    public internal(set) var replay: ReplayModel?

    /// The agent map of the selected company (live), or the installed demo (`--map-demo`); `ensureMapController()` makes it.
    public private(set) var mapController: MapController?
    /// The map is shown in its own window rather than in Mission Control.
    public var mapPoppedOut = false
    /// Optional people data for live maps (none in 4b).
    @ObservationIgnored public var mapPeopleProvider: (any MapPeopleProviding)? = nil
    /// The vault a live map's poll reloads the redactor from (the engine reloads it only while it runs). Nil, as in the app,
    /// means the vault the embedded engine was given: the app delegate's non-interactive vault, which `restartEngine` keeps
    /// (`mapVault`). Tests set it, or give the engine a `MemoryVault`/`FileVault`; never a Keychain-backed one.
    @ObservationIgnored public var mapSecretVault: (any SecretVault)? = nil
    /// Between `closeStore()` and a successful `reopenStore()`: `store` is closed, so no live map may be built over it.
    @ObservationIgnored private var storeClosed = false

    /// Plan C: the preview's OPENED slot and its history (per company, `PreviewNavStore`).
    public internal(set) var previewNav = PreviewNav()
    /// Plan C: the body of the opened ref (rendered off-main; nil while it loads or with nothing open).
    public internal(set) var openedBody: RefBody?
    /// Plan C: the ref open in chat's inspector split, and its body.
    public internal(set) var chatInspector: OpenedRef?
    public internal(set) var inspectorBody: RefBody?
    /// Plan C: the search-and-ask bar (atop the preview, and the ⌘K palette).
    public private(set) var showBar: ShowBarModel
    /// Plan C: the owner's open show requests, as waiting chips (refreshed every tick).
    public internal(set) var waitingChips: [WaitingChip] = []
    /// Plan C: answers opened in the background since the owner last looked at the OPENED tab.
    public internal(set) var autoOpenBadge = 0
    /// Plan C: the "owner requests" Budget line's numbers.
    public internal(set) var ownerRequestUsage: OwnerRequestUsage?
    /// Bumped by every open, so a body rendered for a ref the owner has since left is dropped.
    @ObservationIgnored var openGeneration = 0
    @ObservationIgnored let showFiles = FileIndexCache()
    @ObservationIgnored let showCommits = CommitIndexCache()
    /// The archive and PDF reader renders and shares pass to the gate (`Orchestrator.gateArchives` in the app; tests inject one).
    @ObservationIgnored public var refArchives: @Sendable (Store, BrahmaPaths, String) -> any ArchiveReader = {
        Orchestrator.gateArchives(store: $0, paths: $1, companyId: $2)
    }
    /// Ruling C6-2(b): the owner principal every owner-only Store call takes; established for this process at init (nil in a
    /// turn's process: every owner action then refuses with the generic text).
    @ObservationIgnored public var owner: OwnerPrincipal? = { OwnerPrincipal.enterOwnerProcess(); return try? OwnerPrincipal.mint() }()
    /// Where `PreviewNav` is kept (`.standard` in the app; tests give a suite of their own).
    @ObservationIgnored public var navDefaults: UserDefaults = .standard
    /// Plan C C6b: the live changes engine over `store` (one loop per observed item and compare; rebuilt with the store).
    @ObservationIgnored public private(set) var liveChanges: LiveChanges
    /// Plan C C6b: the CHANGES tab's model for the selected company (nil with none selected). It streams only while the tab or a
    /// live diff in the OPENED tab is visible (`updateChangesVisibility`).
    public internal(set) var changes: ChangesTabModel?

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

    public init(store: Store, paths: BrahmaPaths, secretVault: any SecretVault, clock: @escaping @Sendable () -> Date = { .now }) {
        self.store = store
        self.paths = paths
        self.secretVault = secretVault
        self.clock = clock
        self.liveChanges = LiveChanges(store: store)
        self.search = SearchModel(store: store)
        self.backups = BackupsModel(store: store, paths: paths)
        self.access = AccessModel(store: store, owner: owner)
        self.settings = SettingsModel(store: store)
        self.digest = DigestModel(store: store)
        self.showBar = ShowBarModel(backend: .empty)
        wireSubmodels()
    }

    /// The per-company models follow the selection and refresh the snapshot after a change.
    private func wireSubmodels() {
        access.afterChange = { [weak self] in await self?.tick(forceSnapshot: true) }
        settings.afterChange = { [weak self] in await self?.tick(forceSnapshot: true) }
        settings.vault = ownerSecretVault
        access.companyId = selectedCompanyId
        settings.companyId = selectedCompanyId
        digest.companyId = selectedCompanyId
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
        // A live map reads this store: it stops for good, and the next `ensureMapController()` after `reopenStore()` builds
        // one whose cursors start at the restored database's maxima.
        storeClosed = true
        dropLiveMapController()
        // The map's vacancy sheets act on the company and store they were opened for.
        if presentedSheet?.isCompanyBound == true { presentedSheet = nil }
        let store = self.store
        try? await Task.detached { try store.close() }.value
    }

    /// Opens the database again (after a restore), starts from a clean snapshot and re-seeds the activity cursor from the
    /// current maximum, so no event of the restored database is replayed or skipped.
    public func reopenStore() async {
        let (path, backupsDir, catalog) = (paths.database.path, paths.backupsDir, store.catalog)
        do {
            let reopened = try await Task.detached { try Store(path: path, catalog: catalog, backupsDir: backupsDir) }.value
            store = reopened
            // Anything built or installed over the closed store while it was away is dropped; the next ensure builds a
            // controller over `reopened`, its cursors at the restored database's maxima.
            storeClosed = false
            changes?.stop()
            changes = nil
            liveChanges = LiveChanges(store: reopened)
            dropLiveMapController()
            search = SearchModel(store: reopened)
            backups = BackupsModel(store: reopened, paths: paths)
            access = AccessModel(store: reopened, owner: owner)
            settings = SettingsModel(store: reopened)
            digest = DigestModel(store: reopened)
            handbook = nil
            storage = nil
            replay = nil
            wireSubmodels()
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
    /// the engine. The store is reopened even when the restore fails. A restored database always carries the owner's stop
    /// (`RestoreCarry`, final review I3), so the restarted engine runs nothing until the owner resumes it.
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
            // A live map of another company (one built over a reopened store before this reload) is not this selection's.
            if firstId != selectedCompanyId { dropLiveMapController() }
            if handbook?.companyId != firstId { handbook = nil }
            selectedCompanyId = firstId
            access.companyId = firstId
            settings.companyId = firstId
            digest.companyId = firstId
            cleanRenderScratch(all: true)
            if let firstId { loadPreviewNav(companyId: firstId) }
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
        await refreshPreventSleep()
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
            if turnStreamAgentId != nil { await refreshTurnStream() }
            await refreshCollab()
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
        dropLiveMapController()
        // The map's vacancy sheets act on the company they were opened for.
        if presentedSheet?.isCompanyBound == true { presentedSheet = nil }
        selectedCompanyId = id
        access.companyId = id
        settings.companyId = id
        digest.companyId = id
        settings.pendingFull = nil
        sidebarSelection = .missionControl
        chat = nil
        selectedAgentId = nil
        selectedItemKey = nil
        selectedPreviewTab = nil
        selectedArtifactId = nil
        pinnedArtifact = nil
        artifactNotice = nil
        phoneFrameOverride = [:]
        scriptEnabledArtifacts = []
        openAPICache = [:]
        stopObservingTurnStream()
        boardSprintId = nil
        activity = []
        search.query = ""
        highlightedMessageId = nil
        handbook = nil
        replay = nil
        loadPreviewNav(companyId: id)
        do { try await reloadSelected() } catch { report(error) }
    }

    public func select(_ item: SidebarItem) {
        sidebarSelection = item
        if item == .budget { ensureStorage() }
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
        model.drops = dropContext(for: target).map { ResourceDropModel(app: self, context: $0, defaults: dropDefaults) }
        model.cardMaker = makeCardMaker(companyId: companyId)
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
        case .backups: select(.settingsBackups)
        case .grants: select(.inboxGrants)
        case .digest: select(.inboxDigest)
        case .companySettings: select(.companySettings)
        case .releases: select(.releases)
        case .mergeQueue: select(.mergeQueue)
        case .resources: select(.resources)
        case .budget: select(.budget)
        case .replayAgent(let handle, let day):
            select(.agents)
            guard let agent = snapshot.agents.first(where: { $0.name.lowercased() == handle }) else {
                errorMessage = "No agent @\(handle)"
                return
            }
            selectedAgentId = agent.id
            openReplay(agentId: agent.id, day: day)
        case .replayItem(let key):
            select(.backlog)
            selectedItemKey = key
            openReplay(itemKey: key)
        case .handbook: openHandbook(tab: .pages)
        case .memory: openHandbook(tab: .memory)
        case .kb(let path): openHandbook(tab: .pages, page: path)
        case .release(let ref):
            select(.releases)
            selectedReleaseRef = ref
        case .preview(let name):
            select(.missionControl)
            if name == PreviewTabID.live || name == PreviewTabID.artifacts {
                selectPreviewTab(name)
            } else if let s = snapshot.preview.surfaces.first(where: { $0.name.lowercased() == name }) {
                selectPreviewTab(PreviewTabID.surface(s.id))
            } else {
                errorMessage = "No preview \(name)"
            }
        case .artifact(let number):
            // In the snapshot: shown at once. Older than its newest ones: looked up and pinned (`openArtifact`), off-main.
            select(.missionControl)
            if let a = snapshot.preview.artifacts.first(where: { $0.number == number }) {
                selectArtifact(a)
            } else {
                Task { await openArtifact(number: number) }
            }
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
        case .map:
            select(.missionControl)
            _ = ensureMapController()
        case .ref(let companyId, let canonical):
            // View-only: the company is selected and the ref opened; nothing is asked, shared, granted or spent.
            Task { await applyRef(companyId: companyId, canonical: canonical) }
        case .find(let query):
            openShow(presentation: .overlay)
            showBar.query = query
            Task { await showBar.update(query: query) }
        case .changes(let key):
            // The board, or that item's live diff vs main, on the CHANGES tab (the key is selected first, so the stream starts on it).
            select(.missionControl)
            if let key { changes?.select(key) }
            selectPreviewTab(PreviewTabID.changes)
        }
    }

    // MARK: Map

    /// The current map controller: the existing one (an installed demo included), else a new live one for the selected
    /// company over the current `store` (read now: `reopenStore()` replaces it), else nil when no company is selected.
    public func ensureMapController() -> MapController? {
        if let mapController {
            // A live controller over a store this model no longer uses, or of a company it no longer shows, is never handed out.
            if mapController.isSynthetic
                || (mapController.liveStore === store && mapController.companyId == selectedCompanyId) { return mapController }
            dropLiveMapController()
        }
        guard !storeClosed, let id = selectedCompanyId else { return nil }
        let controller = MapController(source: .live(store: store, companyId: id), people: mapPeopleProvider,
                                       vault: mapVault, clock: clock)
        controller.sync(snapshot: snapshot)
        mapController = controller
        return controller
    }

    /// The vault a live map reloads the redactor from: `mapSecretVault`, else the embedded engine's.
    var mapVault: (any SecretVault)? { mapSecretVault ?? engine?.secretVault }

    /// The pop-out map window closed: the map is no longer shown elsewhere, so the flag clears and the controller stops
    /// polling and drops its queue (it keeps its model current without queuing until it starts again, at the then-current
    /// maxima). An inline panel that is mounted restarts it from its `mapPoppedOut` change (`start()` is idempotent).
    public func mapWindowClosed() {
        mapPoppedOut = false
        mapController?.stop()
    }

    /// Installs a controller (the `--map-demo` path), invalidating any previous one.
    public func installMapController(_ c: MapController) {
        if let old = mapController, old !== c { old.invalidate() }
        mapController = c
    }

    /// A live controller belongs to one company and one store: it is invalidated and dropped. A synthetic one stays.
    private func dropLiveMapController() {
        guard let c = mapController, !c.isSynthetic else { return }
        c.invalidate()
        mapController = nil
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
        let source: RepoSource?
        if case .repo(let text) = form.source { source = try RepoSource.parse(text) } else { source = nil }
        let paths = self.paths
        // Task 14: the engine's own fetch, refused (size, file count, LFS, reserved names, links) before the company exists. It
        // and everything after it run on the import's blocking threads, never on the cooperative pool (fix round 1, I3); a
        // task cancelled before the company is created creates nothing and leaves nothing staged.
        try Task.checkCancellation()
        let staged = try await RepoImport.offPool { try source.map { try RepoImport.stage($0, paths: paths) } }
        if Task.isCancelled { staged?.discard(); throw CancellationError() }
        let company = try await RepoImport.offPool { () -> Company in
            defer { staged?.discard() }
            // The seat budget follows the plan tier (`Store.seatBudget()`); the rest of the shape waits as vacancies.
            let seats = store.seatBudget()
            var company = try store.createCompany(name: name, goal: goal, workspacesRoot: root, packId: packId, importing: staged)
            if count > 0, let pack = store.catalog.pack(packId) {
                let plan = try OrgGenerator.generate(goal: goal, count: count, pack: pack)
                let staffed = OrgGenerator.staff(plan: plan, pack: pack, readyWidth: 0, seatBudget: seats)
                try store.applyOrg(companyId: company.id, plan: staffed.seated, pack: pack, vacancies: staffed.vacancies)
            }
            if let staged { _ = try RepoImport.onboard(store: store, company: company, staged: staged) }
            if mode != company.usageMode { company = try store.updateCompany(id: company.id) { $0.usageMode = mode } }
            return company
        }
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
        refreshOpenAPI()
        await checkPinnedArtifact()
        // The deleted-artifact notice lasts until something is selected again (a pick, a tab, or a refresh that left one selected).
        if artifactNotice != nil, selectedArtifactId != nil { artifactNotice = nil }
        if let c = mapController, c.companyId == id { c.sync(snapshot: snapshot) }
        ticksSinceSnapshot = 0
        // The Handbook follows the database only while it is shown (its lists are read on demand, never kept in the snapshot).
        if sidebarSelection == .handbook, let handbook, handbook.companyId == id { await handbook.refresh() }
    }

    func report(_ error: Error) {
        let message = "Couldn't read the Brahma database: \(error)"
        // A persistent failure would otherwise re-raise the alert every 500 ms after the owner dismissed it.
        guard message != lastDBError else { return }
        lastDBError = message
        errorMessage = message
    }
}
