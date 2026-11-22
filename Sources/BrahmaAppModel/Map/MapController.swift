import Foundation
import Observation
import BrahmaCore

/// Where a map's company comes from: a live store, or the deterministic demo company (`--map-demo`).
public enum MapSource: Sendable {
    case live(store: Store, companyId: String)
    case synthetic(agents: Int, rate: Double, seed: UInt64)
}

public enum CameraTarget: Equatable, Sendable {
    case fit
    case agent(String)
}

/// The replay scrubber's state (Task 7b drives it).
public struct ReplayState: Equatable, Sendable {
    public var timeline: MapTimeline
    public var time: Date
    public var playing: Bool
    public var speed: Double

    public init(timeline: MapTimeline, time: Date, playing: Bool, speed: Double) {
        self.timeline = timeline; self.time = time; self.playing = playing; self.speed = speed
    }
}

/// Feeds one company's map: snapshots in (`sync`), traffic in (`poll`), animations out (`frame`).
///
/// Every stored property later tasks mutate is declared here (extensions cannot add stored properties). Setters that the
/// Task 7b extensions (separate files) need are `internal(set)` rather than `private(set)`; the public surface is the same.
///
/// Agent text: item titles and blocker lines pass through `Store.redactor` in `sync` (5-lite does not redact them at write
/// time) and then through `MapText.clean` in `MapModel`. While the store's secrets are held (`Store.secretsHeld`: never
/// loaded in this process, or the last reload left one unloaded) nothing is shown raw: an item shows its key and
/// `withheld`, an owner blocker `"Waiting on you: " + withheld`.
@MainActor @Observable
public final class MapController {
    public static let pollInterval: Duration = .milliseconds(500)
    public static let highlightDuration: TimeInterval = 1.5
    /// Polls between two cursor checks (the first poll after `init` and after `start()` always checks).
    public static let cursorCheckEvery = 10
    /// The people provider is consulted at most this often.
    static let peopleInterval: TimeInterval = 10
    /// Synthetic mode: one random reorg this often.
    static let syntheticReorgEvery: TimeInterval = 30
    /// Synthetic mode: the share of agents whose state changes per poll.
    static let syntheticChurn = 0.02
    /// Shown instead of agent text while the redactor cannot vouch for it.
    public static let withheld = "[hidden until secrets load]"
    static let redactionCacheLimit = 4096
    nonisolated static let feedPages = 10

    public static func modeKey(_ id: String) -> String { "brahma.map.mode.\(id)" }
    /// The owner's office unlock (Plan 4c), this Mac's user, independent of company.
    public static let officeUnlockedKey = "brahma.map.office.unlocked"

    // MARK: Setup

    public let companyId: String
    public let isSynthetic: Bool
    @ObservationIgnored let source: MapSource
    @ObservationIgnored let people: (any MapPeopleProviding)?
    @ObservationIgnored let vault: (any SecretVault)?
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let clock: @Sendable () -> Date
    @ObservationIgnored private let createdAt: Date

    // MARK: State

    public internal(set) var model = MapModel()
    public var mode: MapMode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey(companyId)) }
    }
    public var zoom: Double = 1
    /// Subtree id → expanded (true) or collapsed (false); wins over the default collapse.
    public var orgOverrides: [String: Bool] = [:]
    public var hoveredAgentId: String?
    public var selectedManagerId: String?
    public internal(set) var camera: CameraTarget = .fit
    /// Bumped by every `follow`, `zoomToFit` and `jump(to:)`, even when `camera` ends up equal to what it was: the view eases
    /// to the target again (after the owner panned away) when this changes. Setting an Equatable value to itself is not a
    /// change to Observation, so `camera` alone cannot say "go there again".
    public internal(set) var cameraRequest = 0
    public internal(set) var follow: String?
    public internal(set) var replay: ReplayState?
    /// Whether a replay is open. Changes only on enter and exit, so a view that only needs to know (the header, the menus,
    /// the sheets) does not re-render with every replay frame the way a read of `replay` does.
    public internal(set) var isReplaying = false
    public internal(set) var searchHits: [String] = []
    public internal(set) var highlightId: String? {
        didSet { if highlightId != oldValue { highlightStartedAt = nil } }
    }
    public internal(set) var isRunning = false
    public internal(set) var isInvalidated = false
    public internal(set) var reseeds = 0
    /// The owner has found the office (`unlockOffice()`); read from `defaults` in `init`, never cleared (no re-lock in 4c).
    public internal(set) var officeUnlocked: Bool
    /// The map time of the unlock in this controller, for the reveal chip (`MapOverlay.revealDuration`); nil otherwise.
    public internal(set) var officeRevealAt: TimeInterval?
    @ObservationIgnored var officeUnlock = OfficeUnlock()

    // Live feed bookkeeping.
    /// The last live snapshot `sync` took (7b's `exitReplay` re-syncs it; `poll` re-applies it when vacancies or people change).
    @ObservationIgnored var lastSnapshot: Snapshot?
    @ObservationIgnored var messageCursor: Int64 = 0
    @ObservationIgnored var handoffCursor: Int64 = 0
    /// False when `init` could not read the maxima: the next poll seeds the cursors instead of reading flows.
    @ObservationIgnored var cursorsSeeded = false
    @ObservationIgnored var pollsUntilCursorCheck = 0
    /// Bumped by `stop()` and `start()`: a poll that started under another generation discards its result.
    @ObservationIgnored var generation = 0
    @ObservationIgnored var pollsInFlight = 0
    @ObservationIgnored var lastPeopleLoad: Date?
    /// 3a's open `orgVacancy` rows as last read (raw handles); nil before the first poll.
    @ObservationIgnored var orgVacancyRows: [OrgVacancy]?
    /// Cleaned vacancy id (what the map shows and hits name) → the raw org handle every Store call must use. Provider
    /// vacancies are never in it.
    @ObservationIgnored var orgVacancyHandles: [String: String] = [:]
    /// The provider's last answer, uncleaned (cleaned when applied).
    @ObservationIgnored var cachedPeople: MapPeople = .empty
    @ObservationIgnored private var redactionCache: [String: String] = [:]
    @ObservationIgnored private var redactionVersion: String?

    // Frame bookkeeping.
    @ObservationIgnored var highlightStartedAt: TimeInterval?
    @ObservationIgnored private var lastFrameNow: TimeInterval?
    @ObservationIgnored private var lastFrameAt: Date?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    // Synthetic world.
    struct SyntheticWorld {
        var agents: [Agent]
        var pack: IndustryPack
        var vacancies: [Vacancy]
        var meetings: [Meeting]
        var items: [String: String]
        var blockers: [String: String]
        var itemPhases: [String: MapItemPhase] = [:]
        var reviewing: Set<String> = []
        var people: MapPeople = .empty
        var openAsks: Int = 0
        var traffic: SyntheticTraffic
        var rng: SplitMix64
        var rate: Double
        var last: Date
        var lastReorg: Date
    }
    @ObservationIgnored var synthetic: SyntheticWorld?
    /// The synthetic company's traffic bursts: `size` extra messages at every multiple of `every` seconds. The offscreen bench
    /// (`MapBench`) varies it; nil turns bursts off.
    @ObservationIgnored public var syntheticBurst: (every: TimeInterval, size: Int)? = (10, 200)

    public init(source: MapSource, people: (any MapPeopleProviding)? = nil, vault: (any SecretVault)? = nil,
                defaults: UserDefaults = .standard, clock: @escaping @Sendable () -> Date = { .now }) {
        self.source = source
        self.vault = vault
        self.defaults = defaults
        self.clock = clock
        let now = clock()
        self.createdAt = now
        switch source {
        case .live(let store, let companyId):
            self.companyId = companyId
            self.isSynthetic = false
            self.people = people
            // Old traffic is not replayed: the cursors start at the current maxima.
            if let (m, h) = Self.maxima(store: store, companyId: companyId) {
                messageCursor = m
                handoffCursor = h
                cursorsSeeded = true
            }
        case .synthetic(let agents, let rate, let seed):
            self.companyId = "demo"
            self.isSynthetic = true
            // Synthetic mode never consults a provider.
            self.people = nil
            let made = SyntheticCompany.make(agents: agents, seed: seed, companyId: "demo")
            synthetic = SyntheticWorld(agents: made.agents, pack: made.pack, vacancies: made.vacancies, meetings: made.meetings,
                                       items: made.currentItems, blockers: made.blockers,
                                       itemPhases: made.itemPhases, reviewing: made.reviewing, people: made.people,
                                       openAsks: made.openAsks, traffic: SyntheticTraffic(seed: seed),
                                       rng: SplitMix64(seed: seed &+ 0x5EED), rate: Swift.max(0, rate), last: now, lastReorg: now)
        }
        let unlocked = defaults.bool(forKey: Self.officeUnlockedKey)
        officeUnlocked = unlocked
        let stored = defaults.string(forKey: Self.modeKey(companyId)).flatMap(MapMode.init(rawValue:)) ?? .org
        // A stored office for an owner who has not unlocked it falls back to org.
        mode = stored == .office && !unlocked ? .org : stored
        if let world = synthetic { model.apply(Self.inputs(world), now: mapNow()) }
    }

    /// The store a live controller reads (nil for synthetic): `AppModel` never hands out one bound to a store it replaced.
    public var liveStore: Store? {
        if case .live(let store, _) = source { return store }
        return nil
    }

    // MARK: Derived

    /// The subtrees drawn as stubs (none in the office): the tree's default collapse, the owner's overrides, and every
    /// ancestor of the followed or highlighted agent expanded.
    public var collapsed: Set<String> {
        // The office has no stubs: every agent has a desk.
        if mode == .office { return [] }
        var active = 0
        for a in model.agents.values where a.state != .killed { active += 1 }
        return model.tree.collapsed(defaults: model.tree.defaultCollapsed(activeCount: active), overrides: orgOverrides,
                                    focus: follow ?? highlightId)
    }

    /// Folds or unfolds a subtree of the org chart. Nothing in the office: it has no subtrees, and its empty `collapsed`
    /// would write an expand override the org chart would then keep.
    public func toggleSubtree(_ id: String) {
        guard mode != .office else { return }
        orgOverrides[id] = collapsed.contains(id)
    }

    /// The `now` of the last `frame(now:)`, or nil before the first. A view that mounts on a controller that has already been
    /// framed continues from here, so map time never runs backwards (queue entries and edge decay live on it).
    public var lastFrameTime: TimeInterval? { lastFrameNow }

    /// Map time (the renderer's `frame(now:)` base), extrapolated from the last frame with the clock; before any frame,
    /// seconds since the controller was made. A view that mounts again starts its time base here, not at `lastFrameTime`, so
    /// facts stamped while the map was unmounted are not "in the future" of its first frame.
    public func mapNow() -> TimeInterval {
        let t = clock()
        if let n = lastFrameNow, let at = lastFrameAt { return n + Swift.max(0, t.timeIntervalSince(at)) }
        return Swift.max(0, t.timeIntervalSince(createdAt))
    }

    // MARK: Lifecycle

    /// Starts polling. Only a running map queues events, and it starts at the current maxima: what happened while the map
    /// was stopped (or before it was first shown) is never played as live traffic; the model itself was kept current by
    /// `sync` meanwhile. A poll still in flight from before (a write's) is discarded.
    public func start() {
        guard !isInvalidated, pollTask == nil else { return }
        isRunning = true
        generation += 1
        if case .live(let store, let companyId) = source {
            if let (m, h) = Self.maxima(store: store, companyId: companyId) {
                (messageCursor, handoffCursor) = (m, h)
                cursorsSeeded = true
            } else {
                cursorsSeeded = false   // the first poll seeds them
            }
        }
        pollsUntilCursorCheck = 0
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let me = self else { return }
                await me.poll()
                try? await AwakeTime.sleep(for: MapController.pollInterval)
            }
        }
    }

    /// Stops polling and drops the queued events: nothing frames a stopped map, and its queue would only grow.
    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        generation += 1
        isRunning = false
        model.discardPending()
    }

    /// The company's newest message and hand-off rowids, or nil when they cannot be read (a closing store).
    private static func maxima(store: Store, companyId: String) -> (Int64, Int64)? {
        guard let m = try? store.maxMessageRowId(companyId: companyId),
              let h = try? store.maxHandoffRowId(companyId: companyId) else { return nil }
        return (m, h)
    }

    /// Stops for good: `sync`, `poll` and `handle` do nothing afterwards (the company changed or the store closed).
    public func invalidate() {
        stop()
        isInvalidated = true
    }

    // MARK: Sync

    /// Applies a live snapshot; its changes become events only while the map runs (a stopped map stays current without
    /// queuing). While replaying it is only recorded: `exitReplay` applies the newest one.
    public func sync(snapshot: Snapshot) {
        guard case .live(let store, _) = source, !isInvalidated else { return }
        // A snapshot of another company (or the empty one of a reopening store) is not this map's.
        guard snapshot.companies.contains(where: { $0.id == companyId }),
              snapshot.agents.allSatisfy({ $0.companyId == companyId }) else { return }
        lastSnapshot = snapshot
        guard replay == nil else { return }
        model.apply(inputs(for: snapshot, store: store), now: mapNow(), emitEvents: isRunning)
    }

    /// `raw` through the redactor, cached per raw string until the redactor's version changes; nil while the secrets are
    /// held (the caller shows a placeholder, never the raw text).
    func redacted(_ raw: String, store: Store) -> String? {
        guard !store.secretsHeld else {
            redactionCache = [:]
            redactionVersion = nil
            return nil
        }
        let version = store.redactor.version
        if version != redactionVersion {
            redactionCache = [:]
            redactionVersion = version
        }
        if let hit = redactionCache[raw] { return hit }
        let out = store.redactor.apply(raw)
        if redactionCache.count >= Self.redactionCacheLimit { redactionCache = [:] }
        redactionCache[raw] = out
        return out
    }

    func inputs(for snapshot: Snapshot, store: Store) -> MapInputs {
        let company = snapshot.companies.first { $0.id == companyId }?.company
        // Display only: vacancy writes never fall back to another pack.
        let pack = company.flatMap { store.catalog.pack($0.packId) } ?? SoftwarePack.pack
        let agents = snapshot.agents
        let living = agents.filter { $0.state != .killed }
        let livingIds = Set(living.map(\.id))

        // Each owner's newest active item, as redacted "KEY title".
        var newest: [String: WorkItem] = [:]
        for item in snapshot.work.items where item.status == .inProgress || item.status == .inReview {
            guard let owner = item.ownerId else { continue }
            if let current = newest[owner],
               (current.updatedAt, current.createdAt, current.number) >= (item.updatedAt, item.createdAt, item.number) { continue }
            newest[owner] = item
        }
        var currentItems: [String: String] = [:]
        for (owner, item) in newest {
            currentItems[owner] = redacted("\(item.key) \(item.title)", store: store) ?? "\(item.key) \(Self.withheld)"
        }

        // Blocker lines (an owner blocker carries the agent's reason).
        let handles = Dictionary(agents.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var blockers: [String: String] = [:]
        for a in agents {
            guard let b = a.blocker else { continue }
            let line = BlockerText.describe(b, handles: handles, timeZone: snapshot.work.timeZone)
            if let r = redacted(line, store: store) {
                blockers[a.id] = r
            } else if case .owner = b {
                blockers[a.id] = "Waiting on you: \(Self.withheld)"
            } else if case .agent(let id) = b, handles[id] == nil {
                // `describe` falls back to the raw id, which is agent text when it names no agent.
                blockers[a.id] = "Waiting on \(Self.withheld)"
            } else {
                // The other blockers hold no agent text: handles, item keys and times.
                blockers[a.id] = line
            }
        }

        // Vacancies: the owner's seats first (raw handles kept for Store calls), then the provider's, display only.
        let idsByHandle = Dictionary(living.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        var vacancies: [Vacancy] = []
        var handleMap: [String: String] = [:]
        let rows = orgVacancyRows ?? []
        for var row in rows {
            // Owner text, redacted at write time with the secrets known then: redacted again with today's, and withheld
            // while they are held (as `brahma org vacancies` does).
            if !row.note.isEmpty { row.note = redacted(row.note, store: store) ?? Self.withheld }
            let v = Vacancy(row: row, pack: pack, agentIdsByHandle: idsByHandle)
            if handleMap[v.id] == nil { handleMap[v.id] = row.handle }
            vacancies.append(v)
        }
        orgVacancyHandles = handleMap
        let rawHandles = Set(rows.map { $0.handle.lowercased() })
        var shown = Set(vacancies.map(\.id))
        for var p in cachedPeople.vacancies {
            p.source = .provider
            guard !rawHandles.contains(p.id.lowercased()) else { continue }
            let cleaned = p.cleaned()
            guard shown.insert(cleaned.id).inserted else { continue }
            vacancies.append(cleaned)
        }

        let dotted = DottedLinks.reviewers(items: snapshot.work.items, agents: livingIds)
            + cachedPeople.dotted.filter { livingIds.contains($0.from) && livingIds.contains($0.to) }
        let meetings = Meetings.detect(agents: agents, pack: pack, sprints: snapshot.work.openSprints)
        return MapInputs(agents: agents, pack: pack, currentItems: currentItems, blockers: blockers, vacancies: vacancies,
                         dotted: dotted, meetings: meetings, people: Self.cleaned(cachedPeople),
                         itemPhases: Self.itemPhases(snapshot.work, newest: newest),
                         reviewing: Self.reviewing(snapshot.work, living: livingIds), openAsks: snapshot.work.inbox.count)
    }

    /// The provider's strings through `MapText.clean` (trust label and title, meter line, perks); vacancies travel
    /// separately.
    static func cleaned(_ p: MapPeople) -> MapPeople {
        MapPeople(
            trust: p.trust.mapValues { MapTrust(label: MapText.clean($0.label, max: 8), title: MapText.clean($0.title, max: 40),
                                                tier: $0.tier) },
            perks: p.perks.mapValues { perks in
                perks.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(2).map { MapText.clean($0, max: 8) }
            },
            meters: p.meters.mapValues { MapMeter(line: MapText.clean($0.line, max: 40), fraction: $0.fraction) },
            dotted: p.dotted)
    }

    static func inputs(_ w: SyntheticWorld) -> MapInputs {
        MapInputs(agents: w.agents, pack: w.pack, currentItems: w.items, blockers: w.blockers, vacancies: w.vacancies,
                  meetings: w.meetings, people: w.people, itemPhases: w.itemPhases, reviewing: w.reviewing,
                  openAsks: w.openAsks)
    }

    // MARK: Poll

    public func poll() async {
        guard !isInvalidated else { return }
        switch source {
        case .synthetic: pollSynthetic()
        case .live(let store, let companyId): await pollLive(store: store, companyId: companyId)
        }
    }

    struct LiveRead: Sendable {
        /// Cursors to adopt without reading flows: a first seed, or a re-seed after a cursor ran above the maximum.
        var seedTo: (message: Int64, handoff: Int64)?
        var isReseed = false
        var messages: [MessageFlow] = []
        var handoffs: [HandoffFlow] = []
        var vacancies: [OrgVacancy]?
        var people: MapPeople?
        /// The poll's vault reload installed a new redactor load: what is on the map is re-redacted at once.
        var reloaded = false
    }

    private func pollLive(store: Store, companyId: String) async {
        let startedIn = generation
        let checkCursors = !cursorsSeeded || pollsUntilCursorCheck <= 0
        pollsUntilCursorCheck = checkCursors ? Self.cursorCheckEvery - 1 : pollsUntilCursorCheck - 1
        let now = clock()
        var provider: (any MapPeopleProviding)?
        if let people, lastPeopleLoad.map({ now.timeIntervalSince($0) >= Self.peopleInterval || now < $0 }) ?? true {
            provider = people
            lastPeopleLoad = now
        }
        let (seeded, m, h, vault) = (cursorsSeeded, messageCursor, handoffCursor, vault)
        pollsInFlight += 1
        defer { pollsInFlight -= 1 }
        let read = await Task.detached {
            Self.readLive(store: store, companyId: companyId, seeded: seeded, messageCursor: m, handoffCursor: h,
                          checkCursors: checkCursors, vault: vault, people: provider, now: now)
        }.value
        // `stop()` or `invalidate()` ran during the read: the result belongs to a map that is gone.
        guard startedIn == generation, !isInvalidated else { return }

        if let seed = read.seedTo {
            messageCursor = seed.message
            handoffCursor = seed.handoff
            cursorsSeeded = true
            if read.isReseed { reseeds += 1 }
        } else {
            // Overlapping polls read the same rows: only what is past the cursor now is new.
            let messages = read.messages.filter { $0.rowId > messageCursor }
            let handoffs = read.handoffs.filter { $0.rowId > handoffCursor }
            if let last = read.messages.last?.rowId { messageCursor = Swift.max(messageCursor, last) }
            if let last = read.handoffs.last?.rowId { handoffCursor = Swift.max(handoffCursor, last) }
            let facts = (messages.map(MapFact.message) + handoffs.map(MapFact.handoff)).enumerated()
                .sorted { $0.element.at != $1.element.at ? $0.element.at < $1.element.at : $0.offset < $1.offset }
                .map(\.element)
            // Replay shows history; live traffic that arrives meanwhile is skipped, not queued. A stopped map (a write's
            // poll) only moves its cursors.
            if isRunning && replay == nil && !facts.isEmpty { model.ingest(facts, now: mapNow()) }
        }

        var changed = read.reloaded
        if let rows = read.vacancies, rows != orgVacancyRows {
            orgVacancyRows = rows
            changed = true
        }
        if let p = read.people, p != cachedPeople {
            cachedPeople = p
            changed = true
        }
        if changed, replay == nil, let snapshot = lastSnapshot {
            model.apply(inputs(for: snapshot, store: store), now: mapNow(), emitEvents: isRunning)
        }
    }

    /// The off-main half of a live poll. Read failures (a closing store) leave that part out.
    nonisolated static func readLive(store: Store, companyId: String, seeded: Bool, messageCursor: Int64, handoffCursor: Int64,
                                     checkCursors: Bool, vault: (any SecretVault)?, people: (any MapPeopleProviding)?,
                                     now: Date) -> LiveRead {
        var read = LiveRead()
        // The engine tick reloads the redactor only while the engine runs.
        if let vault { read.reloaded = (try? store.reloadRedactorIfNeeded(vault: vault)) ?? false }
        read.vacancies = try? store.vacancies(companyId: companyId)
        if let people { read.people = try? people.load(store: store, companyId: companyId, now: now) }

        if checkCursors, let maxM = try? store.maxMessageRowId(companyId: companyId),
           let maxH = try? store.maxHandoffRowId(companyId: companyId) {
            if !seeded {
                read.seedTo = (maxM, maxH)
                return read
            }
            // A cursor above the maximum: the database went back (a restore). Both cursors follow it; nothing is read.
            if maxM < messageCursor || maxH < handoffCursor {
                read.seedTo = (maxM, maxH)
                read.isReseed = true
                return read
            }
        }
        guard seeded else { return read }

        var cursor = messageCursor
        for _ in 0..<feedPages {
            guard let batch = try? store.messageFlows(companyId: companyId, afterRowId: cursor), !batch.isEmpty else { break }
            read.messages += batch
            cursor = batch.last!.rowId
            if batch.count < 500 { break }
        }
        cursor = handoffCursor
        for _ in 0..<feedPages {
            guard let batch = try? store.handoffFlows(companyId: companyId, afterRowId: cursor), !batch.isEmpty else { break }
            read.handoffs += batch
            cursor = batch.last!.rowId
            if batch.count < 200 { break }
        }
        return read
    }

    /// Synthetic traffic for the time since the last poll, 2 % of the agents changing state, and a reorg every 30 s.
    /// Public so the offscreen bench can poll without suspending; a live or invalidated controller does nothing.
    public func pollSynthetic() {
        guard !isInvalidated, var w = synthetic else { return }
        let now = clock()
        let facts = now > w.last ? w.traffic.facts(from: w.last, to: now, agents: w.agents, rate: w.rate, burst: syntheticBurst) : []
        if now > w.last { w.last = now }

        let handles = Dictionary(w.agents.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let states: [AgentState] = [.ready, .running, .sleeping, .blocked]
        for i in w.agents.indices where w.agents[i].state != .killed {
            guard Double.random(in: 0..<1, using: &w.rng) < Self.syntheticChurn else { continue }
            let choices = states.filter { $0 != w.agents[i].state }
            let next = choices.randomElement(using: &w.rng)!
            w.agents[i].state = next
            if next == .blocked {
                let reason = SyntheticCompany.ownerReasons.randomElement(using: &w.rng)!
                w.agents[i].blocker = .owner(reason: reason)
                w.blockers[w.agents[i].id] = BlockerText.describe(w.agents[i].blocker, handles: handles)
            } else {
                w.agents[i].blocker = nil
                w.blockers[w.agents[i].id] = nil
            }
        }

        if now.timeIntervalSince(w.lastReorg) >= Self.syntheticReorgEvery {
            w.lastReorg = now
            Self.reorg(&w)
        }
        synthetic = w
        guard replay == nil else { return }
        let t = mapNow()
        model.apply(Self.inputs(w), now: t)
        if !facts.isEmpty { model.ingest(facts, now: t) }
    }

    /// Moves one living individual contributor under another living manager (and into that manager's team).
    static func reorg(_ w: inout SyntheticWorld) {
        let living = w.agents.indices.filter { w.agents[$0].state != .killed }
        let livingIds = Set(living.map { w.agents[$0].id })
        var reports: [String: [Int]] = [:]
        for i in living { if let m = w.agents[i].managerId { reports[m, default: []].append(i) } }
        let managers = living.filter { reports[w.agents[$0].id] != nil }
        let leaves = living.filter { reports[w.agents[$0].id] == nil && w.agents[$0].managerId.map(livingIds.contains) == true }
        guard let mover = leaves.randomElement(using: &w.rng) else { return }
        let targets = managers.filter { w.agents[$0].id != w.agents[mover].managerId && $0 != mover }
        guard let target = targets.randomElement(using: &w.rng) else { return }
        let managerId = w.agents[target].id
        w.agents[mover].managerId = managerId
        let agents = w.agents
        w.agents[mover].team = reports[managerId]?.lazy.compactMap { agents[$0].team }.first ?? agents[target].team
    }

    // MARK: Frame

    /// One render frame: while a replay plays, advances it by the frame's Δt·speed (`advanceReplay`); then drains the queue
    /// with agents inside collapsed subtrees resolved to their visible ancestor, and clears the highlight 1.5 s after it
    /// first showed.
    public func frame(now: TimeInterval, budget: Int? = nil) -> [VisualEvent] {
        let previousFrame = lastFrameNow
        lastFrameNow = now
        lastFrameAt = clock()
        if replay?.playing == true, !isInvalidated {
            advanceReplay(by: previousFrame.map { now - $0 } ?? 0, now: now)
        }
        if highlightId != nil {
            if let since = highlightStartedAt {
                if now - since >= Self.highlightDuration || now < since { highlightId = nil }
            } else {
                highlightStartedAt = now
            }
        }
        let collapsed = self.collapsed
        let tree = model.tree
        return model.step(now: now, resolve: { endpoint in
            guard case .agent(let id) = endpoint else { return endpoint }
            let visible = tree.visibleAncestor(id, collapsed: collapsed)
            return visible == tree.rootId ? .owner : .agent(visible)
        }, budget: budget)
    }

    // MARK: Hits

    /// A click on the map. Nothing for an invalidated controller or one of a company that is no longer selected; a
    /// synthetic (demo) controller only expands and collapses subtrees, it never touches the app's selection.
    public func handle(_ hit: MapHit, appModel: AppModel) {
        guard !isInvalidated else { return }
        if isSynthetic {
            if case .stub(let id) = hit { toggleSubtree(id) }
            return
        }
        guard appModel.selectedCompanyId == companyId else { return }
        switch hit {
        case .agent(let id):
            appModel.select(.agents)
            appModel.selectedAgentId = id
        case .stub(let id):
            toggleSubtree(id)
        case .team(let managerId):
            selectedManagerId = managerId
        case .owner, .vacancy:
            break   // the view shows a context menu
        }
    }
}
