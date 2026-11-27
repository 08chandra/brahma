import Foundation
import Testing
@testable import BrahmaCore

/// The git leg of company scoping (Plan X6a, ruling R3: an ordinary test over a `GitFixture`, gated by nothing).
@Suite(.scratch) struct MeasureScopeGitTests {
    /// `report` for `acme` must succeed while `zeta`'s workspace path does not exist on disk, and the other way round. In Task 1 no
    /// metric reads git at all, so this passes trivially; it is the tripwire for Tasks 3–4: a metric that reaches into another
    /// company's workspace (anything but the `git` it is handed) fails here as soon as the fixture gives `acme` landings whose
    /// git-derived metrics run, because the only repository on disk is the company's own.
    @Test func otherWorkspaceNeverRead() throws {
        let now = MeasureFixtures.t0
        let store = try Store.inMemory()
        let acmeRepo = try GitFixture(files: ["README.md": "acme\n"])
        let acme = try MeasureFixtures.seed(store, name: "Acme", landed: 24, workspacePath: acmeRepo.root.path, now: now)
        // Zeta's workspace is a path nothing created.
        let zetaPath = try tempDir().appending(path: "zeta-missing").path
        let zeta = try MeasureFixtures.seed(store, name: "Zeta", landed: 48, workspacePath: zetaPath, now: now)
        #expect(!FileManager.default.fileExists(atPath: zetaPath))
        let window = try MeasureWindow.parse("all", now: now, companyCreated: acme.createdAt, tz: TimeZone(identifier: "UTC")!)

        let r = try Measure.report(store: store, git: acmeRepo.ws, companyId: acme.id, window: window, now: now)
        #expect(r.companyId == acme.id && r.metrics.map(\.id) == MetricId.all)

        // The other way round: zeta gets a real repository, acme's is gone.
        let zetaRepo = try GitFixture(files: ["README.md": "zeta\n"])
        try store.writer.write { db in
            try db.execute(sql: "UPDATE company SET workspacePath = ? WHERE id = ?", arguments: [zetaRepo.root.path, zeta.id])
            try db.execute(sql: "UPDATE company SET workspacePath = ? WHERE id = ?", arguments: ["/nonexistent/acme-gone", acme.id])
        }
        let z = try Measure.report(store: store, git: zetaRepo.ws, companyId: zeta.id, window: window, now: now)
        #expect(z.companyId == zeta.id && z.metrics.map(\.id) == MetricId.all)
    }
}
