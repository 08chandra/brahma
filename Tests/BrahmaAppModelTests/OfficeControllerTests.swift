import Testing
import Foundation
@testable import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite(.scratch) struct OfficeControllerTests {
    private func suite() -> UserDefaults { UserDefaults(suiteName: UUID().uuidString)! }

    private func demo(agents: Int = 20, defaults: UserDefaults, clock: MapTestClock) -> MapController {
        MapController(source: .synthetic(agents: agents, rate: 0, seed: 1), defaults: defaults, clock: { clock.now })
    }

    @Test func officeUnlockPersistsAndSwitchesMode() {
        let d = suite()
        let clock = MapTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let c = demo(defaults: d, clock: clock)
        #expect(!c.officeUnlocked)
        #expect(c.mode == .org)
        #expect(c.officeRevealAt == nil)
        for i in 0..<5 {
            #expect(!c.officeUnlocked, "not before the fifth click (\(i))")
            clock.now = clock.now.addingTimeInterval(0.4)
            c.officeBoardClick()
        }
        #expect(c.officeUnlocked)
        #expect(c.mode == .office)
        #expect(c.officeRevealAt == c.mapNow())
        #expect(d.bool(forKey: MapController.officeUnlockedKey))
        #expect(MapController.officeUnlockedKey == "brahma.map.office.unlocked")

        // The owner's unlock and the company's mode survive a new controller on the same defaults.
        let again = demo(defaults: d, clock: clock)
        #expect(again.officeUnlocked)
        #expect(again.mode == .office)
        #expect(again.officeRevealAt == nil, "the reveal chip is for the moment of discovery only")
        again.mode = .org
        #expect(demo(defaults: d, clock: clock).mode == .org)
    }

    @Test func officeKeysUnlockOnce() throws {
        let d = suite()
        let clock = MapTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let c = demo(defaults: d, clock: clock)
        for ch in "office" {
            #expect(!c.officeUnlocked)
            clock.now = clock.now.addingTimeInterval(0.3)
            c.officeKey(ch)
        }
        #expect(c.officeUnlocked)
        #expect(c.mode == .office)
        let revealAt = try #require(c.officeRevealAt)

        // Once unlocked, the routes change nothing: the owner's later mode choice stands and the reveal stays where it was.
        c.mode = .org
        for ch in "office" { clock.now = clock.now.addingTimeInterval(0.3); c.officeKey(ch) }
        for _ in 0..<5 { clock.now = clock.now.addingTimeInterval(0.1); c.officeBoardClick() }
        c.officeOtherClick()
        c.unlockOffice()
        #expect(c.mode == .org)
        #expect(c.officeRevealAt == revealAt)
        #expect(c.officeUnlocked)
    }

    @Test func otherClickResetsTheBoardCount() {
        let clock = MapTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let c = demo(defaults: suite(), clock: clock)
        for _ in 0..<4 { clock.now = clock.now.addingTimeInterval(0.2); c.officeBoardClick() }
        c.officeOtherClick()
        clock.now = clock.now.addingTimeInterval(0.2)
        c.officeBoardClick()
        #expect(!c.officeUnlocked)
        #expect(c.mode == .org)
    }

    @Test func slowBoardClicksDoNotUnlock() {
        let clock = MapTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let c = demo(defaults: suite(), clock: clock)
        for _ in 0..<5 { clock.now = clock.now.addingTimeInterval(1); c.officeBoardClick() }
        #expect(!c.officeUnlocked)
    }

    @Test func storedOfficeModeWithoutUnlockFallsBack() {
        let clock = MapTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let locked = suite()
        locked.set(MapMode.office.rawValue, forKey: MapController.modeKey("demo"))
        #expect(demo(defaults: locked, clock: clock).mode == .org)

        let unlocked = suite()
        unlocked.set(MapMode.office.rawValue, forKey: MapController.modeKey("demo"))
        unlocked.set(true, forKey: MapController.officeUnlockedKey)
        let c = demo(defaults: unlocked, clock: clock)
        #expect(c.officeUnlocked)
        #expect(c.mode == .office)
    }

    @Test func collapsedEmptyInOfficeMode() {
        let clock = MapTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let c = demo(agents: 300, defaults: suite(), clock: clock)
        #expect(!c.collapsed.isEmpty, "300 agents start with collapsed subtrees on the org chart")
        c.mode = .office
        #expect(c.collapsed.isEmpty, "the office has no stubs: every agent has a desk")
        c.mode = .org
        #expect(!c.collapsed.isEmpty)
    }

    @Test func appModelBuildsMapControllersOnMapDefaults() async throws {
        let (store, paths) = try makeHome()
        _ = try seedAcme(store, paths)
        let model = AppModel(store: store, paths: paths)
        let d = suite()
        d.set(true, forKey: MapController.officeUnlockedKey)
        model.mapDefaults = d
        await model.load()
        let c = try #require(model.ensureMapController())
        #expect(c.officeUnlocked, "the live controller reads the model's map defaults, not .standard")
        c.mode = .office
        #expect(d.string(forKey: MapController.modeKey(c.companyId)) == "office")
    }

    @Test func itemPhasesReviewingAndAsksFromSnapshot() throws {
        let (store, paths) = try makeHome()
        let (acme, ceo, cto, eng) = try seedAcme(store, paths)
        func item(_ title: String, owner: String, reviewer: String, status: WorkItemStatus) throws -> WorkItem {
            let item = try store.createWorkItem(companyId: acme.id, by: .owner, draft: WorkItemDraft(type: .task, title: title))
            try store.writer.write { db in
                try db.execute(sql: "UPDATE workItem SET status = ?, ownerId = ?, reviewerId = ? WHERE id = ?",
                               arguments: [status.rawValue, owner, reviewer, item.id])
            }
            return item
        }
        // eng's item is in review by cto, with its check running; ceo's item is in progress with eng named as reviewer.
        let reviewed = try item("Ship it", owner: eng.id, reviewer: cto.id, status: .inReview)
        _ = try item("Plan it", owner: ceo.id, reviewer: eng.id, status: .inProgress)
        for title in ["Pick a name", "Pick a colour"] {
            _ = try store.propose(companyId: acme.id, by: .agent(eng.id), kind: .other, risk: .high, category: "general",
                                  title: title, summary: "why", viaOwner: true, quotaExempt: .devHook)
        }
        var snapshot = try Snapshot.load(store: store, selectedCompanyId: acme.id)
        #expect(snapshot.work.inbox.count == 2)
        snapshot.work.latestRuns[reviewed.id] = VerificationRun(
            id: "run-1", companyId: acme.id, itemId: reviewed.id, checkRevision: 1, scriptHash: "h", commit: "c", command: "check",
            workingDirectory: "/tmp", timeoutSeconds: 60, purpose: .submit, status: .running, createdAt: Date())

        let c = MapController(source: .live(store: store, companyId: acme.id), defaults: suite())
        let inputs = c.inputs(for: snapshot, store: store)
        #expect(inputs.itemPhases == [eng.id: .checking, ceo.id: .working])
        #expect(inputs.reviewing == [cto.id], "an inProgress item's reviewer is not reviewing")
        #expect(inputs.openAsks == 2)

        c.sync(snapshot: snapshot)
        #expect(c.model.phase(agentId: eng.id) == .checking)
        #expect(c.model.agents[eng.id]?.shipping == .checking)
        #expect(c.model.phase(agentId: ceo.id) == .working)
        #expect(c.model.agents[ceo.id]?.shipping == nil)
        #expect(c.model.openAsks == 2)
        // cto is sleeping in Acme: away, though reviewing; eng is blocked on the owner.
        #expect(c.model.agents[cto.id]?.activity == .away)
        #expect(c.model.agents[eng.id]?.activity == .waitingOnOwner)
        #expect(c.model.agents[ceo.id]?.activity == .idle)
    }

    @Test func officeModeTitle() {
        #expect(MapMode.office.title == "OFFICE")
        #expect(MapMode.allCases.first == .org)
        #expect(MapMode.allCases == [.org, .office])
    }
}
