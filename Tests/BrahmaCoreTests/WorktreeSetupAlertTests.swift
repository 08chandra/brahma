import Testing
import Foundation
import GRDB
@testable import BrahmaCore

@Suite struct WorktreeSetupAlertTests {
    private struct Boom: Error {}

    private func open(_ store: Store, _ company: Company) throws -> Int {
        try worktreeSetupAlerts(store, company).filter { $0.status == .pendingOwner }.count
    }

    @Test func alertClearsWhenALaterSetupSucceedsAndRaisesAgainOnTheNextFailure() throws {
        let w = try World()
        let c = try w.company("Acme")
        #expect(w.store.noteWorktreeSetupFailure(companyId: c.id, what: "a worktree", error: Boom(), now: w.clock.now))
        #expect(try open(w.store, c) == 1)
        // A second failure while it is open adds nothing.
        #expect(!w.store.noteWorktreeSetupFailure(companyId: c.id, what: "a worktree", error: Boom(), now: w.clock.now))
        #expect(try open(w.store, c) == 1)
        // A success clears it, answering itself with "resolved".
        w.store.noteWorktreeSetupSuccess(companyId: c.id, now: w.clock.now)
        #expect(try open(w.store, c) == 0)
        let settled = try #require(try worktreeSetupAlerts(w.store, c).first)
        #expect(settled.ownerAnswer == "resolved")
        // A success with nothing open changes nothing; a new failure raises it again.
        w.store.noteWorktreeSetupSuccess(companyId: c.id, now: w.clock.now)
        #expect(w.store.noteWorktreeSetupFailure(companyId: c.id, what: "a worktree", error: Boom(), now: w.clock.now))
        #expect(try open(w.store, c) == 1)
    }

    @Test func aSuccessInOneCompanyLeavesAnotherCompanysAlertOpen() throws {
        let w = try World()
        let a = try w.company("Acme"), b = try w.company("Beta")
        w.store.noteWorktreeSetupFailure(companyId: a.id, what: "x", error: Boom(), now: w.clock.now)
        w.store.noteWorktreeSetupFailure(companyId: b.id, what: "x", error: Boom(), now: w.clock.now)
        w.store.noteWorktreeSetupSuccess(companyId: a.id, now: w.clock.now)
        #expect(try open(w.store, a) == 0)
        #expect(try open(w.store, b) == 1)
    }
}
