import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite struct AppModelRestoreTests {
    @Test func restoreClosesAndReopensTheStore() async throws {
        let (store, paths) = try makeHome()
        try seedAcme(store, paths)
        let model = AppModel(store: store, paths: paths)
        await model.load()
        let snapshot = try BackupService(paths: paths, writer: store.writer).snapshot(reason: .manual)
        _ = try store.createCompany(name: "Later", goal: "after the snapshot", workspacesRoot: paths.workspaces)
        try store.appendEvent(ActivityEvent(companyId: try #require(try store.companies().first).id, agentId: nil, turnId: nil,
                                            kind: .message, text: "after", createdAt: .now))

        let outcome = try await model.restore(from: snapshot)

        #expect(outcome.previousCopy != nil)
        // The model works on a new store; the old one is closed.
        #expect(model.store !== store)
        #expect(throws: (any Error).self) { try store.companies() }
        #expect(try model.store.companies().map(\.name).sorted() == ["Acme", "Globex"])
        #expect(model.loaded)
        // The activity cursor was re-seeded from the restored database: nothing is replayed.
        #expect(model.activity.allSatisfy { $0.text != "after" })
        model.stopPolling()
    }

    @Test func closeStoreThenReopenKeepsTheData() async throws {
        let (store, paths) = try makeHome()
        try seedAcme(store, paths)
        let model = AppModel(store: store, paths: paths)
        await model.closeStore()
        #expect(throws: (any Error).self) { try store.companies() }
        await model.reopenStore()
        #expect(try model.store.companies().count == 2)
        model.stopPolling()
    }
}
