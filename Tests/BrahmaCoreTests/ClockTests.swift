import Foundation
import Testing
@testable import BrahmaCore

@Suite(.scratch) struct ClockTests {
    private func make() throws -> (Store, Company, Date) {
        let store = try Store.inMemory()
        let c = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        return (store, c, Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func accruesOnlyWhileRunning() throws {
        let (store, c, t0) = try make()
        try store.accrueActiveTime(now: t0)                       // first sight: nothing to add
        try store.accrueActiveTime(now: t0.addingTimeInterval(10))
        #expect(store.activeNow(companyId: c.id) == 10)
        var paused = c; paused.status = .paused
        try store.updateCompany(paused)
        try store.accrueActiveTime(now: t0.addingTimeInterval(40))
        try store.accrueActiveTime(now: t0.addingTimeInterval(50))
        #expect(store.activeNow(companyId: c.id) == 10, "a paused company gains 0")
        try store.updateCompany(c)
        try store.accrueActiveTime(now: t0.addingTimeInterval(55))
        #expect(store.activeNow(companyId: c.id) == 15, "resuming counts from the pause's last tick, not the pause itself")
    }

    @Test func gapsOverSixtySecondsCountSixty() throws {
        let (store, c, t0) = try make()
        try store.accrueActiveTime(now: t0)
        try store.accrueActiveTime(now: t0.addingTimeInterval(7200))   // quit or sleep for 2 h
        #expect(store.activeNow(companyId: c.id) == CompanyClock.maxGap)
        #expect(CompanyClock.maxGap == 60)
        try store.accrueActiveTime(now: t0.addingTimeInterval(7230))
        #expect(store.activeNow(companyId: c.id) == 90)
        // A clock that jumps backwards adds nothing.
        try store.accrueActiveTime(now: t0.addingTimeInterval(7000))
        #expect(store.activeNow(companyId: c.id) == 90)
    }

    @Test func frozenDuringHold() throws {
        let (store, c, t0) = try make()
        try store.accrueActiveTime(now: t0)
        try store.accrueActiveTime(now: t0.addingTimeInterval(20))
        #expect(!store.isFrozen(companyId: c.id))
        #expect(try store.setHold(reason: .network, detail: "x", now: t0.addingTimeInterval(20)))
        #expect(store.isFrozen(companyId: c.id))
        try store.accrueActiveTime(now: t0.addingTimeInterval(50))
        try store.accrueActiveTime(now: t0.addingTimeInterval(80))
        #expect(store.activeNow(companyId: c.id) == 20)
        try store.clearHold(now: t0.addingTimeInterval(80))
        try store.accrueActiveTime(now: t0.addingTimeInterval(90))
        #expect(store.activeNow(companyId: c.id) == 30)
    }

    @Test func isFrozenWhenCompanyNotRunning() throws {
        let (store, c, _) = try make()
        var p = c; p.status = .paused
        try store.updateCompany(p)
        #expect(store.isFrozen(companyId: c.id))
        #expect(store.isFrozen(companyId: "no-such-company"))
    }

    @Test func advanceActiveAddsSeconds() throws {
        let (store, c, _) = try make()
        try store.advanceActive(companyId: c.id, by: 3 * 86_400)
        try store.advanceActive(companyId: c.id, by: 5)
        #expect(store.activeNow(companyId: c.id) == 3 * 86_400 + 5)
    }

    @Test func ownerTimeZonePersistsAndValidates() throws {
        let store = try Store.inMemory()
        #expect(store.ownerTimeZone().identifier == TimeZone.current.identifier)
        try store.setOwnerTimeZone("Asia/Kolkata")
        #expect(store.ownerTimeZone().identifier == "Asia/Kolkata")
        #expect(throws: SettingsError.invalid("Mars/Olympus")) { try store.setOwnerTimeZone("Mars/Olympus") }
        #expect(throws: SettingsError.self) { try store.setOwnerTimeZone("") }
        #expect(store.ownerTimeZone().identifier == "Asia/Kolkata", "a rejected id changes nothing")
    }

    @Test func formatsInOwnerTimeZone() throws {
        let store = try Store.inMemory()
        try store.setOwnerTimeZone("Asia/Kolkata")
        let utcNoon = Date(timeIntervalSince1970: TimeInterval(Int(1_800_000_000) - Int(1_800_000_000) % 86_400 + 12 * 3600))
        #expect(store.formatTime(utcNoon) == "17:30")
        try store.setOwnerTimeZone("UTC")
        #expect(store.formatTime(utcNoon) == "12:00")
    }

    @Test func planTierAndShareDefaultsAndValidation() throws {
        let store = try Store.inMemory()
        #expect(store.planTier() == .max5x)
        #expect(store.weeklyShare() == 0.7)
        try store.setPlanTier(.max20x)
        #expect(store.planTier() == .max20x)
        try store.setWeeklyShare(0.5)
        #expect(store.weeklyShare() == 0.5)
        #expect(throws: SettingsError.self) { try store.setWeeklyShare(0.05) }
        #expect(throws: SettingsError.self) { try store.setWeeklyShare(1.1) }
        try store.setWeeklyShare(1.0)
        #expect(store.weeklyShare() == 1.0)
    }

    @Test func seatBudgetFollowsPlanTier() throws {
        let store = try Store.inMemory()
        #expect(store.seatBudget() == 8)
        try store.setPlanTier(.max20x)
        #expect(store.seatBudget() == 24)
    }

    @Test func companyReservePersists() throws {
        let (store, c, _) = try make()
        #expect(c.ownerReserve == nil)
        try store.setOwnerReserve(companyId: c.id, 0.5)
        #expect(try store.company(id: c.id)?.ownerReserve == 0.5)
        try store.setOwnerReserve(companyId: c.id, nil)
        #expect(try store.company(id: c.id)?.ownerReserve == nil)
        #expect(throws: SettingsError.self) { try store.setOwnerReserve(companyId: c.id, 0.95) }
        #expect(throws: SettingsError.self) { try store.setOwnerReserve(companyId: c.id, -0.1) }
    }
}
