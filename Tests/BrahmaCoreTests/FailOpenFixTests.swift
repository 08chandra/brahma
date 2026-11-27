import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan S Task S2 (spec §7.1, B1/B2): the engine's routing of checks and previews fails closed. A check or preview whose
/// author the engine cannot confirm (no holder, an unknown agent, a lookup that throws) runs sandboxed in a Full company,
/// with an activity line that says so; the engine's ceiling narrows previews as it narrows checks; the known-author routes
/// are unchanged. The fixture is `SandboxedCheckTests.S` (a Full company with a real git workspace and engine-run checks).
@Suite(.scratch, .serialized) struct FailOpenFixTests {
    typealias S = SandboxedCheckTests.S

    /// A submitted item's check run, recorded `running` in its engine-made checkout (what `checkRoute` needs to route it).
    private func runningCheck(_ s: S, of item: WorkItem) async throws -> (run: VerificationRun, checkout: URL) {
        let run = try s.latest(item)
        let checkout = s.git.checkoutPath(runId: run.id)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try await s.store.writer.write { db in
            try db.execute(sql: "UPDATE verificationRun SET status = 'running', workingDirectory = ? WHERE id = ?",
                           arguments: [checkout.path, run.id])
        }
        return (run, checkout)
    }

    private func activity(_ s: S) async throws -> [String] {
        try await s.store.writer.read { try ActivityEvent.filter(Column("companyId") == s.company.id).fetchAll($0) }.map(\.text)
    }

    // MARK: Checks (B1)

    /// No lease and a `requestedBy` the company has no agent for: the engine cannot confirm who wrote the check, so a Full
    /// company's check runs sandboxed, and one activity line on the company says so.
    @Test func verificationRunWithUnknownHolderRunsSandboxed() async throws {
        let s = try S(profile: .full)
        let item = try s.submitted()
        let (run, checkout) = try await runningCheck(s, of: item)
        try await s.store.writer.write { db in
            try db.execute(sql: "DELETE FROM workLease WHERE itemId = ?", arguments: [item.id])
            try db.execute(sql: "UPDATE verificationRun SET requestedBy = ? WHERE id = ?", arguments: ["ghost-agent", run.id])
        }
        guard case .sandboxed = Orchestrator.checkRoute(store: s.store)(checkout.path) else {
            Issue.record("a check with an unknown holder ran unsandboxed in a Full company"); return
        }
        let lines = try await activity(s).filter { $0.contains("ran sandboxed: the engine could not confirm who wrote it") }
        #expect(lines.count == 1, "\(lines)")
        #expect(lines.first?.hasPrefix(item.key) == true, "the subject is the item key: \(lines)")
    }

    /// The agent lookup throws (the `agent` table is renamed out from under the store, so every other lookup still works):
    /// sandboxed, never unsandboxed by default.
    @Test func verificationRunWithLookupErrorRunsSandboxed() async throws {
        let s = try S(profile: .full)
        let item = try s.submitted()
        let (_, checkout) = try await runningCheck(s, of: item)
        try await s.store.writer.write { db in try db.execute(sql: "ALTER TABLE agent RENAME TO agent_unreachable") }
        #expect(throws: (any Error).self) { try s.store.agent(id: s.eng.id) }
        guard case .sandboxed = Orchestrator.checkRoute(store: s.store)(checkout.path) else {
            Issue.record("a check whose holder lookup failed ran unsandboxed in a Full company"); return
        }
        let lines = try await activity(s).filter { $0.contains("ran sandboxed: the engine could not confirm who wrote it") }
        #expect(lines.count == 1, "\(lines)")
    }

    /// Unchanged: a Full company's check held by a known agent whose role runs Full is unconfined, with no note.
    @Test func knownFullHolderStillUnsandboxed() async throws {
        let s = try S(profile: .full)
        let item = try s.submitted()
        let (_, checkout) = try await runningCheck(s, of: item)
        guard case .unsandboxed = Orchestrator.checkRoute(store: s.store)(checkout.path) else {
            Issue.record("a Full company's check with a known Full holder was sandboxed"); return
        }
        #expect(try await activity(s).allSatisfy { !$0.contains("ran sandboxed") })
    }

    // MARK: Previews and main smokes (B1, B2)

    /// S6 re-point: `PreviewRunner.unsandboxed(store:company:setById:ceiling:)` is gone (spec §7.3); its rule is the resolver's
    /// setter row (previews, main smokes and release builds share it) and the shared Full route (`runsUnsandboxed`). For a
    /// main smoke, `setById` is recorded as the company's smoke-check setter (the setter column that can be nil) and resolved
    /// from the held company (`resolve(holding: .mainSmoke)`, S6-c1); for a preview, as a surface's setter (nil is an empty
    /// id: the column is `NOT NULL`) and resolved from the held surface.
    private func setterRunsUnsandboxed(_ s: S, setById: String?, ceiling: PermissionProfile?) throws -> Bool {
        try s.store.writer.write { db in
            try db.execute(sql: "UPDATE company SET smokeCheckSetById = ? WHERE id = ?", arguments: [setById, s.company.id])
        }
        let company = try #require(try s.store.company(id: s.company.id))
        return Self.full(PrincipalResolver(store: s.store, ceiling: ceiling).resolve(holding: .mainSmoke(company)))
    }

    private func surfaceRunsUnsandboxed(_ s: S, setById: String?, ceiling: PermissionProfile?) throws -> Bool {
        let surface = try s.store.previewSurfaces(companyId: s.company.id).first
            ?? s.store.upsertPreviewSurface(companyId: s.company.id, by: .owner,
                                            PreviewDraft(name: "web", run: "sleep 1", url: "http://127.0.0.1:{port}/"))
        try s.store.writer.write { db in
            try db.execute(sql: "UPDATE previewSurface SET setById = ? WHERE id = ?", arguments: [setById ?? "", surface.id])
        }
        let held = try #require(try s.store.previewSurface(companyId: s.company.id, id: surface.id))
        return Self.full(PrincipalResolver(store: s.store, ceiling: ceiling).resolve(holding: .preview(held)))
    }

    /// The Full route of an allowed resolution; a denial never runs Full.
    private static func full(_ d: Decision<PrincipalSet>) -> Bool {
        switch d {
        case .allow(let set, _): return set.runsUnsandboxed
        case .deny: return false
        }
    }

    /// A smoke with no setter: the engine cannot confirm who wrote its command, so it runs sandboxed even in a Full company.
    @Test func smokeWithNilSetterInFullCompanyIsSandboxed() throws {
        let s = try S(profile: .full)
        #expect(s.company.permissionProfile == .full)
        #expect(try setterRunsUnsandboxed(s, setById: nil, ceiling: nil) == false)
    }

    /// A surface with no setter: the same.
    @Test func previewWithNilSetterInFullCompanyIsSandboxed() throws {
        let s = try S(profile: .full)
        #expect(try surfaceRunsUnsandboxed(s, setById: nil, ceiling: nil) == false)
        #expect(try surfaceRunsUnsandboxed(s, setById: "", ceiling: nil) == false)
    }

    /// The engine's ceiling (`brahma run --profile`) narrows smokes as it narrows checks: a Full company and a Full setter
    /// role under a Sandboxed ceiling run sandboxed; the Full ceiling (or none) leaves them unconfined.
    @Test func smokeHonoursCeiling() throws {
        let s = try S(profile: .full)
        #expect(s.company.profile(forRole: s.eng.role) == .full)
        #expect(try setterRunsUnsandboxed(s, setById: s.eng.id, ceiling: .sandboxed) == false)
        #expect(try setterRunsUnsandboxed(s, setById: s.eng.id, ceiling: .workspace) == false)
        #expect(try setterRunsUnsandboxed(s, setById: s.eng.id, ceiling: .full) == true)
        #expect(try setterRunsUnsandboxed(s, setById: s.eng.id, ceiling: nil) == true)
        // The owner's command is narrowed by the ceiling too.
        #expect(try setterRunsUnsandboxed(s, setById: "owner", ceiling: .sandboxed) == false)
    }

    /// Previews: the same.
    @Test func previewHonoursCeiling() throws {
        let s = try S(profile: .full)
        #expect(try surfaceRunsUnsandboxed(s, setById: s.eng.id, ceiling: .sandboxed) == false)
        #expect(try surfaceRunsUnsandboxed(s, setById: s.eng.id, ceiling: .workspace) == false)
        #expect(try surfaceRunsUnsandboxed(s, setById: s.eng.id, ceiling: .full) == true)
        #expect(try surfaceRunsUnsandboxed(s, setById: s.eng.id, ceiling: nil) == true)
        #expect(try surfaceRunsUnsandboxed(s, setById: "owner", ceiling: .sandboxed) == false)
    }

    /// Unchanged: an owner-set smoke follows its Full company.
    @Test func ownerSmokeSetterStillFollowsCompany() throws {
        let s = try S(profile: .full)
        #expect(try setterRunsUnsandboxed(s, setById: "owner", ceiling: nil) == true)
        try s.store.updateSandbox(companyId: s.company.id, SandboxPatch(profile: .sandboxed), userHome: try tempDir())
        #expect(try setterRunsUnsandboxed(s, setById: "owner", ceiling: nil) == false)
    }

    /// Unchanged: an owner-set surface follows its Full company.
    @Test func ownerSetterStillFollowsCompany() throws {
        let s = try S(profile: .full)
        #expect(try surfaceRunsUnsandboxed(s, setById: "owner", ceiling: nil) == true)
        try s.store.updateSandbox(companyId: s.company.id, SandboxPatch(profile: .sandboxed), userHome: try tempDir())
        #expect(try surfaceRunsUnsandboxed(s, setById: "owner", ceiling: nil) == false)
    }

    /// An agent id the company has no record of, or a lookup that throws, runs sandboxed: smokes.
    @Test func smokeWithUnknownOrUnreadableSetterIsSandboxed() async throws {
        let s = try S(profile: .full)
        #expect(try setterRunsUnsandboxed(s, setById: "ghost-agent", ceiling: nil) == false)
        #expect(try setterRunsUnsandboxed(s, setById: s.eng.id, ceiling: nil) == true)
        try await s.store.writer.write { db in try db.execute(sql: "ALTER TABLE agent RENAME TO agent_unreachable") }
        #expect(try setterRunsUnsandboxed(s, setById: s.eng.id, ceiling: nil) == false)
    }

    /// Previews: the same.
    @Test func previewWithUnknownOrUnreadableSetterIsSandboxed() async throws {
        let s = try S(profile: .full)
        #expect(try surfaceRunsUnsandboxed(s, setById: "ghost-agent", ceiling: nil) == false)
        #expect(try surfaceRunsUnsandboxed(s, setById: s.eng.id, ceiling: nil) == true)
        try await s.store.writer.write { db in try db.execute(sql: "ALTER TABLE agent RENAME TO agent_unreachable") }
        #expect(try surfaceRunsUnsandboxed(s, setById: s.eng.id, ceiling: nil) == false)
    }

    /// The B1 text, exactly.
    @Test func sandboxedNoteText() {
        #expect(SafeRead.sandboxedNote(subject: "K-7", reason: "no agent holds or requested it")
                == "K-7 ran sandboxed: the engine could not confirm who wrote it (no agent holds or requested it)")
    }
}
