import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

/// A people provider for the controller tests: returns `people`, counts its calls and, with a `gate`, blocks inside `load`
/// until the test signals it (so a poll can be held in flight).
final class FakePeopleProvider: MapPeopleProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _people: MapPeople
    private var _calls = 0
    private var _entered = false
    let gate: DispatchSemaphore?

    init(_ people: MapPeople = .empty, gated: Bool = false) {
        _people = people
        gate = gated ? DispatchSemaphore(value: 0) : nil
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return _entered }

    func load(store: Store, companyId: String, now: Date) throws -> MapPeople {
        lock.lock()
        _calls += 1
        _entered = true
        let people = _people
        lock.unlock()
        gate?.wait()
        return people
    }
}

final class MapTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return _now }
        set { lock.lock(); _now = newValue; lock.unlock() }
    }
}

@MainActor @Suite(.scratch) struct MapControllerTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: UUID().uuidString)! }

    private func live(_ store: Store, _ companyId: String, people: (any MapPeopleProviding)? = nil,
                      vault: (any SecretVault)? = nil) -> MapController {
        MapController(source: .live(store: store, companyId: companyId), people: people, vault: vault, defaults: defaults())
    }

    private func snapshot(_ store: Store, _ companyId: String) throws -> Snapshot {
        try Snapshot.load(store: store, selectedCompanyId: companyId)
    }

    /// An `inProgress` item owned by `owner`, written raw (so a title can hold text the redactor would now catch).
    @discardableResult
    private func activeItem(_ store: Store, _ companyId: String, title: String, owner: String, reviewer: String? = nil,
                            status: WorkItemStatus = .inProgress) throws -> WorkItem {
        let item = try store.createWorkItem(companyId: companyId, by: .owner, draft: WorkItemDraft(type: .task, title: "placeholder"))
        try store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET title = ?, status = ?, ownerId = ?, reviewerId = ? WHERE id = ?",
                           arguments: [title, status.rawValue, owner, reviewer, item.id])
        }
        return item
    }

    @Test func defaultModeIsOrgPersistedPerCompany() throws {
        #expect(MapController.modeKey("acme") == "brahma.map.mode.acme")
        let d = defaults()
        let synthetic = MapController(source: .synthetic(agents: 20, rate: 0, seed: 1), defaults: d)
        #expect(synthetic.companyId == "demo")
        #expect(synthetic.isSynthetic)
        #expect(synthetic.mode == .org)
        synthetic.mode = .org
        #expect(d.string(forKey: "brahma.map.mode.demo") == "org")

        let (store, paths) = try makeHome()
        let (acme, _, _, _) = try seedAcme(store, paths)
        let d2 = defaults()
        d2.set("hive-not-yet", forKey: MapController.modeKey(acme.id))
        let c = MapController(source: .live(store: store, companyId: acme.id), defaults: d2)
        #expect(!c.isSynthetic && c.companyId == acme.id)
        #expect(c.mode == .org, "an unknown stored mode falls back to .org")
        c.mode = .org
        #expect(d2.string(forKey: "brahma.map.mode.\(acme.id)") == "org")
        #expect(d2.string(forKey: "brahma.map.mode.demo") == nil, "per company")
    }

    @Test func dmBecomesMessageEvent() async throws {
        let (store, paths) = try makeHome()
        let (acme, _, cto, _) = try seedAcme(store, paths)
        let c = live(store, acme.id)
        c.sync(snapshot: try snapshot(store, acme.id))
        _ = try MessageRouter(store: store).sendDM(companyId: acme.id, from: .owner, to: "cto", text: "hello")
        await c.poll()
        let events = c.frame(now: 1)
        #expect(events.contains { $0.kind == .message && $0.from == .owner && $0.to == .agent(cto.id) }, "\(events)")
    }

    @Test func oldTrafficNotReplayedLive() async throws {
        let (store, paths) = try makeHome()
        let (acme, _, _, _) = try seedAcme(store, paths)
        let router = MessageRouter(store: store)
        for i in 0..<5 { _ = try router.sendDM(companyId: acme.id, from: .owner, to: "cto", text: "old \(i)") }
        _ = try router.post(companyId: acme.id, channel: "general", from: .owner, text: "old @cto")
        let c = live(store, acme.id)
        c.sync(snapshot: try snapshot(store, acme.id))
        await c.poll()
        await c.poll()
        #expect(c.model.stats.ingested == 0)
        #expect(c.frame(now: 1).isEmpty)
    }

    @Test func itemAndBlockerRedacted() async throws {
        let (store, paths) = try makeHome()
        let (acme, _, _, eng) = try seedAcme(store, paths)
        let value = "sk-test-1234567890"
        let item = try activeItem(store, acme.id, title: "Rotate \(value) now", owner: eng.id)
        _ = try store.transition(agentId: eng.id, to: .ready)
        _ = try store.transition(agentId: eng.id, to: .blocked, blocker: .owner(reason: "key \(value)"))
        store.redactor.update([(name: "API_KEY", value: value)], version: "t")

        let c = live(store, acme.id)
        c.sync(snapshot: try snapshot(store, acme.id))
        let agent = try #require(c.model.agents[eng.id])
        let itemLine = try #require(agent.item)
        #expect(itemLine.hasPrefix(item.key))
        #expect(itemLine.contains("[redacted API_KEY]"), "\(itemLine)")
        #expect(agent.blocker.contains("[redacted API_KEY]"), "\(agent.blocker)")
        let card = try #require(c.model.hoverCard(agentId: eng.id))
        #expect(card.item?.contains("[redacted API_KEY]") == true)
        #expect(card.blocker.contains("[redacted API_KEY]"))
        for text in [itemLine, agent.blocker, card.item ?? "", card.blocker] { #expect(!text.contains(value)) }

        // A new redactor version is picked up (the cache is per version).
        store.redactor.update([(name: "OTHER", value: value)], version: "t2")
        c.sync(snapshot: try snapshot(store, acme.id))
        #expect(c.model.agents[eng.id]?.item?.contains("[redacted OTHER]") == true)
    }

    @Test func itemAndBlockerWithheldWhileSecretsUnloaded() async throws {
        let (owner, paths) = try makeHome()
        let (acme, ceo, _, eng) = try seedAcme(owner, paths)
        let value = "sk-live-abcdefgh12345"
        let item = try activeItem(owner, acme.id, title: "Use \(value)", owner: eng.id)
        _ = try owner.transition(agentId: eng.id, to: .ready)
        _ = try owner.transition(agentId: eng.id, to: .blocked, blocker: .owner(reason: "paste \(value)"))
        // An agent blocker naming no agent: `describe` would show the raw id.
        _ = try owner.transition(agentId: ceo.id, to: .blocked, blocker: .agent(value))
        // One naming a real agent keeps its handle.
        let qa = try owner.hire(companyId: acme.id, name: "qa", role: "engineer", model: "sonnet")
        _ = try owner.transition(agentId: qa.id, to: .ready)
        _ = try owner.transition(agentId: qa.id, to: .blocked, blocker: .agent(eng.id))
        try owner.setSecret(companyId: acme.id, name: "API_KEY", value: value, isTest: false, vault: MemoryVault())
        // A new process: the database has a secret and the redactor has not loaded it.
        let store = try Store(path: paths.database.path)
        #expect(store.secretsHeld)
        let c = live(store, acme.id)
        c.sync(snapshot: try snapshot(store, acme.id))
        let agent = try #require(c.model.agents[eng.id])
        #expect(agent.item == "\(item.key) \(MapController.withheld)", "\(agent.item ?? "nil")")
        #expect(agent.blocker == "Waiting on you: \(MapController.withheld)", "\(agent.blocker)")
        #expect(!(agent.item ?? "").contains(value) && !agent.blocker.contains(value))
        #expect(c.model.agents[ceo.id]?.blocker == "Waiting on \(MapController.withheld)")
        #expect(c.model.agents[qa.id]?.blocker == "Waiting on @eng")
        #expect(c.model.hoverCard(agentId: ceo.id)?.blocker.contains(value) == false)
    }

    @Test func pollReloadReappliesAtOnce() async throws {
        let (store, paths) = try makeHome()
        let (acme, _, _, eng) = try seedAcme(store, paths)
        let value = "sk-added-later-98765"
        try activeItem(store, acme.id, title: "Use \(value)", owner: eng.id)
        let vault = MemoryVault()
        let c = live(store, acme.id, vault: vault)
        c.sync(snapshot: try snapshot(store, acme.id))
        await c.poll()   // vacancies loaded: nothing else changes on the next poll
        try store.setSecret(companyId: acme.id, name: "API_KEY", value: value, isTest: false, vault: vault)
        await c.poll()
        // No refreshSnapshot ran: the poll's reload re-applied the last snapshot itself.
        let item = try #require(c.model.agents[eng.id]?.item)
        #expect(item.contains("[redacted API_KEY]"), "\(item)")
        #expect(!item.contains(value))
    }

    @Test func noLiveControllerOverAClosedStore() async throws {
        let (store, paths) = try makeHome()
        let (acme, _, _, _) = try seedAcme(store, paths)
        let app = AppModel(store: store, paths: paths)
        await app.load()
        let first = try #require(app.ensureMapController())
        await app.closeStore()
        #expect(first.isInvalidated)
        // A view asking for the map while the store is closed gets none.
        #expect(app.ensureMapController() == nil)
        // One installed over the closed store anyway is dropped by the reopen.
        let stray = live(store, acme.id)
        app.installMapController(stray)
        await app.reopenStore()
        app.stopPolling()
        #expect(stray.isInvalidated)
        let fresh = try #require(app.ensureMapController())
        #expect(fresh !== stray && fresh !== first)
        #expect(fresh.liveStore === app.store)
        #expect(fresh.messageCursor == (try app.store.maxMessageRowId(companyId: acme.id)))
        #expect(fresh.handoffCursor == (try app.store.maxHandoffRowId(companyId: acme.id)))
        #expect(app.ensureMapController() === fresh)
    }

    @Test func redactorReloadsOnPollWhileEngineStopped() async throws {
        let (store, paths) = try makeHome()
        let (acme, _, _, _) = try seedAcme(store, paths)
        let vault = MemoryVault()
        let c = live(store, acme.id, vault: vault)
        try store.setSecret(companyId: acme.id, name: "API_KEY", value: "sk-poll-reload-123456", isTest: false, vault: vault)
        #expect(store.redactor.version != (try store.secretsVersion()))
        await c.poll()
        #expect(store.redactor.version == (try store.secretsVersion()))
        #expect(store.redactor.apply("sk-poll-reload-123456") == "[redacted API_KEY]")
    }

    @Test func providerVacanciesTaggedAndDeduped() async throws {
        let (store, paths) = try makeHome()
        let (acme, _, cto, _) = try seedAcme(store, paths)
        let row = try store.addVacancy(companyId: acme.id, role: "engineer", managerHandle: "cto", team: nil, note: "owner note")
        let people = MapPeople(vacancies: [
            Vacancy(id: "x-1", role: "designer", roleTitle: "Designer", managerId: cto.id, team: nil, note: "", source: .org),
            Vacancy(id: row.handle, role: "designer", roleTitle: "Designer", managerId: nil, team: nil, note: "", source: .org),
        ])
        let c = live(store, acme.id, people: FakePeopleProvider(people))
        c.sync(snapshot: try snapshot(store, acme.id))
        await c.poll()
        let vacancies = c.model.vacancies
        #expect(vacancies.first { $0.id == "x-1" }?.source == .provider)
        let org = vacancies.filter { $0.id == row.handle }
        #expect(org.count == 1)
        #expect(org.first?.source == .org)
        #expect(org.first?.role == "engineer")
        #expect(org.first?.managerId == cto.id)
        #expect(org.first?.note == "owner note")
        // The raw org handle is what Store calls use; provider ids never appear there.
        #expect(c.orgVacancyHandles[row.handle] == row.handle)
        #expect(c.orgVacancyHandles["x-1"] == nil)
    }

    @Test func reviewLinesAndMeetings() async throws {
        let (store, paths) = try makeHome()
        let (acme, _, cto, eng) = try seedAcme(store, paths)
        try activeItem(store, acme.id, title: "Reviewed work", owner: eng.id, reviewer: cto.id)
        let planned = try store.createWorkItem(companyId: acme.id, by: .owner, draft: WorkItemDraft(type: .task, title: "Planned"))
        let (sprint, _) = try store.planSprint(companyId: acme.id, by: .agent(cto.id), goal: "Ship it", itemKeys: [planned.key])
        #expect(sprint.status == .pendingApproval)
        let c = live(store, acme.id)
        c.sync(snapshot: try snapshot(store, acme.id))
        #expect(c.model.dotted.count == 1)
        #expect(c.model.dotted.first?.from == cto.id && c.model.dotted.first?.to == eng.id)
        #expect(c.model.meetings.first?.kind == .sprintPlanning)
        #expect((c.model.meetings.first?.participantIds.count ?? 0) >= 2)
    }

    @Test func peopleOptional() async throws {
        let (store, paths) = try makeHome()
        let (acme, _, _, eng) = try seedAcme(store, paths)
        let bare = live(store, acme.id)
        bare.sync(snapshot: try snapshot(store, acme.id))
        await bare.poll()
        #expect(bare.model.hoverCard(agentId: eng.id)?.trust == nil)

        let provider = FakePeopleProvider(MapPeople(trust: [eng.id: MapTrust(label: "T2\u{202E}", title: "Trusted\u{0007}", tier: 2)],
                                                    perks: [eng.id: ["☕", " "]]))
        let c = live(store, acme.id, people: provider)
        c.sync(snapshot: try snapshot(store, acme.id))
        await c.poll()
        let card = try #require(c.model.hoverCard(agentId: eng.id))
        #expect(card.trust?.label == "T2")
        #expect(card.trust?.title == "Trusted")
        #expect(card.trust?.tier == 2)
        #expect(card.perks == ["☕"])
        #expect(provider.calls == 1)
        // Every 10 s, not every poll.
        await c.poll()
        #expect(provider.calls == 1)

        let synthetic = FakePeopleProvider(MapPeople(trust: ["x": MapTrust(label: "T1", title: "", tier: 1)]))
        let demo = MapController(source: .synthetic(agents: 20, rate: 5, seed: 3), people: synthetic, defaults: defaults())
        await demo.poll()
        await demo.poll()
        #expect(synthetic.calls == 0)
    }

    @Test func closeStoreDropsControllerAndReseeds() async throws {
        let (store, paths) = try makeHome()
        let (acme, _, _, _) = try seedAcme(store, paths)
        _ = try MessageRouter(store: store).sendDM(companyId: acme.id, from: .owner, to: "cto", text: "before")
        let app = AppModel(store: store, paths: paths)
        await app.load()
        let old = try #require(app.ensureMapController())
        #expect(app.ensureMapController() === old)
        old.start()
        #expect(old.isRunning)
        await app.closeStore()
        #expect(old.isInvalidated)
        #expect(!old.isRunning)
        #expect(app.mapController == nil)

        await app.reopenStore()
        app.stopPolling()
        // Written while the store was being reopened: older than the new controller, never replayed.
        _ = try MessageRouter(store: app.store).sendDM(companyId: acme.id, from: .owner, to: "cto", text: "older")
        let fresh = try #require(app.ensureMapController())
        #expect(fresh !== old)
        #expect(fresh.messageCursor == (try app.store.maxMessageRowId(companyId: acme.id)))
        await fresh.poll()
        #expect(fresh.model.stats.ingested == 0)
        _ = try MessageRouter(store: app.store).sendDM(companyId: acme.id, from: .owner, to: "cto", text: "now")
        await fresh.poll()
        await fresh.poll()
        #expect(fresh.model.stats.ingested == 1)
        // The old controller ignores everything now.
        await old.poll()
        old.sync(snapshot: app.snapshot)
        #expect(old.model.stats.ingested == 0)
    }

    @Test func cursorAboveMaxReseeds() async throws {
        let (store, paths) = try makeHome()
        let (acme, _, _, _) = try seedAcme(store, paths)
        let router = MessageRouter(store: store)
        _ = try router.sendDM(companyId: acme.id, from: .owner, to: "cto", text: "one")
        let c = live(store, acme.id)
        c.sync(snapshot: try snapshot(store, acme.id))
        await c.poll()
        #expect(c.reseeds == 0)
        c.messageCursor += 1000
        c.handoffCursor += 1000
        var polls = 0
        while c.reseeds == 0 && polls < MapController.cursorCheckEvery {
            await c.poll()
            polls += 1
        }
        #expect(c.reseeds == 1)
        #expect(c.messageCursor == (try store.maxMessageRowId(companyId: acme.id)))
        #expect(c.handoffCursor == (try store.maxHandoffRowId(companyId: acme.id)))
        #expect(c.model.stats.ingested == 0)
        _ = try router.sendDM(companyId: acme.id, from: .owner, to: "cto", text: "two")
        await c.poll()
        await c.poll()
        #expect(c.model.stats.ingested == 1)
        #expect(c.reseeds == 1)
    }

    @Test func selectCompanyStopsOldControllerAndDropsStaleResults() async throws {
        let (store, paths) = try makeHome()
        let (acme, _, _, _) = try seedAcme(store, paths)
        let globex = try #require(try store.companies().first { $0.name == "Globex" })
        let app = AppModel(store: store, paths: paths)
        await app.load()
        #expect(app.selectedCompanyId == acme.id)
        let provider = FakePeopleProvider(gated: true)
        app.mapPeopleProvider = provider
        let old = try #require(app.ensureMapController())
        let agentsBefore = old.model.agents
        _ = try MessageRouter(store: store).sendDM(companyId: acme.id, from: .owner, to: "cto", text: "in flight")
        old.start()
        // The first poll is now held inside the provider, after it read the DM.
        try await eventually { provider.entered }
        await app.selectCompany(globex.id)
        #expect(!old.isRunning)
        #expect(old.isInvalidated)
        #expect(app.mapController == nil)
        provider.gate?.signal()
        try await eventually { old.pollsInFlight == 0 }
        #expect(old.model.stats.ingested == 0)
        #expect(old.model.agents == agentsBefore)
        // The next ensure builds a Globex controller.
        let next = try #require(app.ensureMapController())
        #expect(next.companyId == globex.id)
        app.stopPolling()
    }

    @Test func installedControllerIsEnsured() async throws {
        let (store, paths) = try makeHome()
        let app = AppModel(store: store, paths: paths)
        #expect(app.selectedCompanyId == nil)
        #expect(app.ensureMapController() == nil)
        let demo = MapController(source: .synthetic(agents: 20, rate: 1, seed: 1), defaults: defaults())
        app.installMapController(demo)
        #expect(app.ensureMapController() === demo)
        demo.start()

        let (acme, _, _, _) = try seedAcme(store, paths)
        await app.selectCompany(acme.id)
        #expect(app.mapController === demo)
        #expect(demo.isRunning)
        #expect(!demo.isInvalidated)
        await app.closeStore()
        #expect(app.mapController === demo, "closeStore leaves a synthetic controller alone")
        #expect(demo.isRunning)

        // Installing another one invalidates the previous.
        let other = MapController(source: .synthetic(agents: 20, rate: 1, seed: 2), defaults: defaults())
        app.installMapController(other)
        #expect(demo.isInvalidated && !demo.isRunning)
        #expect(app.mapController === other)
    }

    @Test func hitHandling() async throws {
        let (store, paths) = try makeHome()
        let (acme, ceo, cto, _) = try seedAcme(store, paths)
        let globex = try #require(try store.companies().first { $0.name == "Globex" })
        let app = AppModel(store: store, paths: paths)
        await app.load()
        let c = try #require(app.ensureMapController())
        #expect(c.companyId == acme.id)

        c.handle(.agent(cto.id), appModel: app)
        #expect(app.sidebarSelection == .agents)
        #expect(app.selectedAgentId == cto.id)

        let before = c.orgOverrides[ceo.id]
        c.handle(.stub(ceo.id), appModel: app)
        #expect(c.orgOverrides[ceo.id] != before)
        let flipped = c.orgOverrides[ceo.id]
        c.handle(.stub(ceo.id), appModel: app)
        #expect(c.orgOverrides[ceo.id] == flipped.map { !$0 })

        c.handle(.team(cto.id), appModel: app)
        #expect(c.selectedManagerId == cto.id)

        func reset() { app.select(.missionControl); app.selectedAgentId = nil }
        let synthetic = MapController(source: .synthetic(agents: 20, rate: 0, seed: 1), defaults: defaults())
        let invalidated = live(store, acme.id)
        invalidated.invalidate()
        let otherCompany = live(store, globex.id)
        for other in [synthetic, invalidated, otherCompany] {
            reset()
            let id = other.isSynthetic ? try #require(other.model.agents.keys.first) : cto.id
            other.handle(.agent(id), appModel: app)
            #expect(app.sidebarSelection == .missionControl)
            #expect(app.selectedAgentId == nil)
        }
        app.stopPolling()
    }

    @Test func syntheticSourceProducesTraffic() async throws {
        let clock = MapTestClock(Date(timeIntervalSince1970: 1_800_000_003))
        let c = MapController(source: .synthetic(agents: 300, rate: 50, seed: 1), defaults: defaults(), clock: { clock.now })
        #expect(c.model.agents.count == 300)
        #expect(c.isSynthetic && c.companyId == "demo")
        await c.poll()
        clock.now = clock.now.addingTimeInterval(1)
        await c.poll()
        #expect(c.model.stats.ingested >= 40, "\(c.model.stats)")
        #expect(c.model.agents.count == 300)
        // sync is ignored for a synthetic source.
        c.sync(snapshot: .empty)
        #expect(c.model.agents.count == 300)
        #expect(!c.frame(now: 1).isEmpty)
    }
}
