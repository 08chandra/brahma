import Testing
import Foundation
import BrahmaCore
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

    @Test func officeModeTitle() {
        #expect(MapMode.office.title == "OFFICE")
        #expect(MapMode.allCases.first == .org)
        #expect(MapMode.allCases == [.org, .office])
    }
}
