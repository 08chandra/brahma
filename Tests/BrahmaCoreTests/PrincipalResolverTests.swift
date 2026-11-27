import Testing
import Foundation
import GRDB
@testable import BrahmaCore
@testable import BrahmaSafety

/// Plan S Task S6 (spec §6.2.3): `PrincipalResolver` turns an action's subject into the principals whose bytes or code it
/// touches, from the engine's records only, company-scoped, narrowed by the engine ceiling, total (a failed lookup is an
/// `.unknown` member, never an error and never an empty set), and once per action. One test per row of the resolution table,
/// the 4a merge-run rule ported member by member, the B1 activity line on each Full route that met an unknown member
/// (checks, previews, main smokes, release builds), and the resolve-once count of each migrated site.
@Suite(.scratch, .serialized) struct PrincipalResolverTests {
    typealias S = SandboxedCheckTests.S

    // MARK: Helpers

    static func agentIds(_ set: PrincipalSet) -> Set<String> {
        Set(set.members.compactMap { member -> String? in
            if case .agent(let a) = member { return a.agentId }
            return nil
        })
    }

    static func profiles(_ set: PrincipalSet) -> [PermissionProfile] {
        set.members.compactMap { member -> PermissionProfile? in
            if case .agent(let a) = member { return a.profile }
            return nil
        }
    }

    static func unknownReasons(_ set: PrincipalSet) -> [String] {
        set.members.compactMap { member -> String? in
            if case .unknown(let why) = member { return why }
            return nil
        }
    }

    /// The Full route every migrated site takes (brief: `allFull && ownerProfile == .full`).
    static func full(_ set: PrincipalSet) -> Bool { set.allFull && set.ownerProfile == .full }

    static func activity(_ store: Store, _ companyId: String) throws -> [String] {
        try store.writer.read { try ActivityEvent.filter(Column("companyId") == companyId).order(Column("id")).fetchAll($0) }.map(\.text)
    }

    static func exec(_ store: Store, _ sql: String, _ args: StatementArguments = []) throws {
        try store.writer.write { try $0.execute(sql: sql, arguments: args) }
    }

    // MARK: verificationRun

    /// The lease holder of the run's item, else who requested the run.
    @Test func verificationRunUsesHolderThenRequester() throws {
        let s = try S(profile: .full)
        let item = try s.submitted()
        let run = try s.latest(item)
        try Self.exec(s.store, "UPDATE verificationRun SET requestedBy = ? WHERE id = ?", [s.eng2.id, run.id])
        let resolver = PrincipalResolver(store: s.store, ceiling: nil)
        let held = resolver.resolve(.verificationRun(runId: run.id))
        #expect(held.companyId == s.company.id)
        #expect(held.members == [.agent(AgentPrincipal(agentId: s.eng.id, companyId: s.company.id, role: "engineer", profile: .full,
                                                       grantDomains: []))])
        #expect(Self.full(held))
        try Self.exec(s.store, "DELETE FROM workLease WHERE itemId = ?", [item.id])
        let requested = resolver.resolve(.verificationRun(runId: run.id))
        #expect(Self.agentIds(requested) == [s.eng2.id] && !requested.hasUnknown)
    }

    /// Neither a holder nor a requester, an agent the company has no record of (or one of another company), or no run at all:
    /// `.unknown`, never Full (the old `?? true`).
    @Test func verificationRunMissingIsUnknown() throws {
        let s = try S(profile: .full)
        let item = try s.submitted()
        let run = try s.latest(item)
        let resolver = PrincipalResolver(store: s.store, ceiling: nil)
        try Self.exec(s.store, "DELETE FROM workLease WHERE itemId = ?", [item.id])
        try Self.exec(s.store, "UPDATE verificationRun SET requestedBy = NULL WHERE id = ?", [run.id])
        let nobody = resolver.resolve(.verificationRun(runId: run.id))
        #expect(Self.unknownReasons(nobody) == ["no agent holds or requested it"])
        #expect(!Self.full(nobody))
        try Self.exec(s.store, "UPDATE verificationRun SET requestedBy = 'ghost-agent' WHERE id = ?", [run.id])
        #expect(Self.unknownReasons(resolver.resolve(.verificationRun(runId: run.id))) == ["no agent ghost-agent in the company's records"])
        // Company-scoped: an agent of another company is not this company's principal.
        let other = try s.world.company("Other", profile: .full)
        let stranger = try s.store.hire(companyId: other.id, name: "eng-x", role: "engineer", model: "sonnet")
        try Self.exec(s.store, "UPDATE verificationRun SET requestedBy = ? WHERE id = ?", [stranger.id, run.id])
        let foreign = resolver.resolve(.verificationRun(runId: run.id))
        #expect(Self.unknownReasons(foreign) == ["no agent \(stranger.id) in the company's records"])
        #expect(!Self.full(foreign))
        let none = resolver.resolve(.verificationRun(runId: "no-such-run"))
        #expect(none.hasUnknown && !Self.full(none))
    }

    // MARK: mergeRun (4a's rule, ported)

    func queue(_ m: MergeFixture) -> MergeQueue {
        MergeQueue(store: m.store, paths: m.world.paths, checks: m.world.checks, knownValues: { _ in [] }, clock: { m.now })
    }

    func main(_ m: MergeFixture) throws -> String { try #require(try m.ws.head(of: GitWorkspace.mainRef)) }

    func roles(_ m: MergeFixture, _ r: [String: PermissionProfile]) throws {
        try m.store.updateSandbox(companyId: m.company.id, SandboxPatch(roleProfiles: r), userHome: try tempDir())
    }

    /// A `running` merge run with these fields, resolved.
    func merge(_ m: MergeFixture, _ kind: MergeRun.Kind?, itemId: String?, batch: String? = nil, at commit: String? = nil) async throws -> PrincipalSet {
        let run = MergeRun(companyId: m.company.id, batchId: batch, candidateCommit: commit, kind: kind, itemId: itemId, status: .running)
        try await m.store.writer.write { try run.insert($0) }
        return PrincipalResolver(store: m.store, ceiling: nil).resolve(.mergeRun(runId: run.id))
    }

    /// Each 4a merge-run principal test (MergeQueueTests `mergeRunPrincipalDecidesTheSandbox`,
    /// `mergeCheckSandboxNeedsEveryPrincipalFull`, `lookupErrorsForceTheSandbox`; MergeBatchTests
    /// `earlierLandedNonFullAuthorForcesTheSandbox`, `preQueueDoneItemsArePrincipals`, `mainAtBasePrincipalsIncludeLandedAuthors`),
    /// with its fixture, asserting the members the rule names and that the Full route agrees with the 4a test's expectation.
    @Test func mergeRunMatches4aRule() async throws {
        // mergeRunPrincipalDecidesTheSandbox
        do {
            let m = try MergeFixture()
            let i = try await m.approved()
            try m.store.updateSandbox(companyId: m.company.id, SandboxPatch(profile: .full), userHome: try tempDir())
            var s = try await merge(m, .item, itemId: i.id)
            #expect(Self.agentIds(s) == [m.eng.id] && !s.hasUnknown && Self.full(s), "the holder")
            try m.exec("DELETE FROM workLease WHERE itemId = ?", [i.id])
            s = try await merge(m, .item, itemId: i.id)
            #expect(Self.agentIds(s) == [m.eng.id] && !s.hasUnknown && Self.full(s), "the assignee")
            s = try await merge(m, .item, itemId: nil)
            #expect(s.hasUnknown && !Self.full(s), "no item, no principal")
            s = try await merge(m, .main, itemId: i.id)
            #expect(s.hasUnknown && Self.agentIds(s) == [m.eng.id] && !Self.full(s), "no setter")
            try m.exec("UPDATE company SET mainCheckSetById = 'no-such-agent' WHERE id = ?", [m.company.id])
            s = try await merge(m, .main, itemId: i.id)
            #expect(Self.unknownReasons(s) == ["no agent no-such-agent in the company's records"] && !Self.full(s))
            try m.exec("UPDATE company SET mainCheckSetById = ? WHERE id = ?", [m.eng.id, m.company.id])
            s = try await merge(m, .main, itemId: i.id)
            #expect(Self.agentIds(s) == [m.eng.id] && !s.hasUnknown && Self.full(s))
            try roles(m, ["engineer": .sandboxed])
            s = try await merge(m, .main, itemId: i.id)
            #expect(Self.agentIds(s) == [m.eng.id] && !s.hasUnknown && !Self.full(s) && Self.profiles(s) == [.sandboxed])
            s = try await merge(m, nil, itemId: i.id)
            #expect(s.hasUnknown && !Self.full(s), "a run of no kind")
        }
        // mergeCheckSandboxNeedsEveryPrincipalFull
        do {
            let m = try MergeFixture()
            let i = try await m.approved()
            let ops = try m.store.hire(companyId: m.company.id, name: "ops-1", role: "ops", model: "sonnet")
            let junior = try m.store.hire(companyId: m.company.id, name: "jr", role: "junior", model: "sonnet")
            try m.store.updateSandbox(companyId: m.company.id, SandboxPatch(profile: .full), userHome: try tempDir())
            try roles(m, ["ops": .full, "engineer": .full, "junior": .workspace])
            try m.exec("UPDATE company SET mainCheckSetById = ? WHERE id = ?", [ops.id, m.company.id])
            var s = try await merge(m, .main, itemId: i.id)
            #expect(Self.agentIds(s) == [ops.id, m.eng.id] && !s.hasUnknown && Self.full(s))
            s = try await merge(m, .item, itemId: i.id)
            #expect(Self.agentIds(s) == [m.eng.id] && Self.full(s), "the item check does not run the setter's code")
            try roles(m, ["ops": .full, "engineer": .workspace, "junior": .workspace])
            #expect(!Self.full(try await merge(m, .main, itemId: i.id)))
            #expect(!Self.full(try await merge(m, .item, itemId: i.id)))
            try roles(m, ["ops": .workspace, "engineer": .full, "junior": .workspace])
            #expect(!Self.full(try await merge(m, .main, itemId: i.id)))
            #expect(Self.full(try await merge(m, .item, itemId: i.id)))
            try roles(m, ["ops": .full, "engineer": .full, "junior": .workspace])
            try m.exec("UPDATE workItem SET ownerId = ? WHERE id = ?", [junior.id, i.id])
            s = try await merge(m, .item, itemId: i.id)
            #expect(Self.agentIds(s) == [m.eng.id, junior.id] && !Self.full(s), "the holder and the assignee both count")
            #expect(!Self.full(try await merge(m, .main, itemId: i.id)))
            try m.exec("UPDATE workItem SET ownerId = ? WHERE id = ?", [m.eng.id, i.id])
            #expect(Self.full(try await merge(m, .main, itemId: i.id)))
            let other = try m.item("Other")
            try m.exec("UPDATE workItem SET ownerId = ? WHERE id = ?", [junior.id, other.id])
            var a = MergeRequest(companyId: m.company.id, itemId: i.id, number: 98, headCommit: try main(m), enqueuedAt: m.now)
            var b = MergeRequest(companyId: m.company.id, itemId: other.id, number: 99, headCommit: try main(m), enqueuedAt: m.now)
            a.batchId = "batch-1"; b.batchId = "batch-1"
            let (ra, rb) = (a, b)
            try await m.store.writer.write { try ra.insert($0); try rb.insert($0) }
            s = try await merge(m, .main, itemId: i.id, batch: "batch-1")
            #expect(Self.agentIds(s) == [ops.id, m.eng.id, junior.id] && !Self.full(s), "every item of the batch")
            s = try await merge(m, .main, itemId: i.id, batch: "no-such-batch")
            #expect(Self.agentIds(s) == [ops.id, m.eng.id] && Self.full(s))
            s = try await merge(m, .main, itemId: nil)
            #expect(Self.agentIds(s) == [ops.id] && s.hasUnknown && !Self.full(s), "a missing candidate principal")
            try m.exec("DELETE FROM workLease WHERE itemId = ?", [i.id])
            try m.exec("UPDATE workItem SET ownerId = NULL WHERE id = ?", [i.id])
            s = try await merge(m, .main, itemId: i.id)
            #expect(Self.agentIds(s) == [ops.id] && s.hasUnknown && !Self.full(s), "neither holder nor assignee")
            s = try await merge(m, .item, itemId: i.id)
            #expect(Self.agentIds(s).isEmpty && s.hasUnknown && !Self.full(s))
        }
        // lookupErrorsForceTheSandbox
        do {
            let m = try MergeFixture()
            let i = try await m.approved()
            try m.store.updateSandbox(companyId: m.company.id, SandboxPatch(profile: .full), userHome: try tempDir())
            try roles(m, ["engineer": .full])
            #expect(Self.full(try await merge(m, .item, itemId: i.id)), "control")
            try m.exec("UPDATE workItem SET status = 'garbage' WHERE id = ?", [i.id])
            var s = try await merge(m, .item, itemId: i.id)
            #expect(s.hasUnknown && !Self.full(s), "an unreadable item row is unknown, not absent")
            try m.exec("UPDATE workItem SET status = 'inReview' WHERE id = ?", [i.id])
            #expect(Self.full(try await merge(m, .item, itemId: i.id)), "control again")
            try m.exec("UPDATE workLease SET acquiredAt = 'garbage' WHERE itemId = ?", [i.id])
            s = try await merge(m, .item, itemId: i.id)
            #expect(s.hasUnknown && !Self.full(s), "an unreadable lease row")
            try m.exec("UPDATE workLease SET acquiredAt = ? WHERE itemId = ?", [m.now, i.id])
            #expect(Self.full(try await merge(m, .item, itemId: i.id)), "control again")
            let other = try m.item("Other")
            var b = MergeRequest(companyId: m.company.id, itemId: other.id, number: 77, headCommit: try main(m), enqueuedAt: m.now)
            b.batchId = "batch-x"
            let rb = b
            try await m.store.writer.write { try rb.insert($0) }
            try m.exec("UPDATE workItem SET ownerId = ? WHERE id = ?", [m.eng.id, other.id])
            #expect(Self.full(try await merge(m, .item, itemId: i.id, batch: "batch-x")), "control: the other item's author is Full too")
            try m.exec("ALTER TABLE mergeRequest RENAME COLUMN batchId TO batchIdGone")
            s = try await merge(m, .item, itemId: i.id, batch: "batch-x")
            #expect(s.hasUnknown && !Self.full(s), "unreadable batch requests")
        }
        // earlierLandedNonFullAuthorForcesTheSandbox, mainAtBasePrincipalsIncludeLandedAuthors
        do {
            let m = try MergeFixture()
            let landed = try await m.approved()
            _ = await queue(m).runNextBatch(company: try #require(try m.store.company(id: m.company.id)))
            let head = try main(m)
            let junior = try m.store.hire(companyId: m.company.id, name: "jr", role: "junior", model: "sonnet")
            let ops = try m.store.hire(companyId: m.company.id, name: "ops-1", role: "ops", model: "sonnet")
            try m.store.updateSandbox(companyId: m.company.id, SandboxPatch(profile: .full), userHome: try tempDir())
            try roles(m, ["ops": .full, "engineer": .full, "junior": .workspace])
            try m.exec("UPDATE company SET mainCheckSetById = ? WHERE id = ?", [ops.id, m.company.id])
            let current = try m.item("Current")
            try m.exec("UPDATE workItem SET ownerId = ? WHERE id = ?", [m.eng.id, current.id])
            var s = try await merge(m, .main, itemId: current.id, at: head)
            #expect(Self.agentIds(s) == [ops.id, m.eng.id] && Self.full(s), "control: the landed author is Full")
            s = try await merge(m, .mainAtBase, itemId: nil, at: head)
            #expect(Self.agentIds(s) == [ops.id, m.eng.id] && !s.hasUnknown && Self.full(s), "control: a queue-landed head")
            try m.exec("UPDATE workItem SET ownerId = ? WHERE id = ?", [junior.id, landed.id])
            try m.exec("DELETE FROM workLease WHERE itemId = ?", [landed.id])
            for kind in [MergeRun.Kind.mainAtBase, .main, .item] {
                s = try await merge(m, kind, itemId: kind == .mainAtBase ? nil : current.id, at: head)
                #expect(Self.agentIds(s).contains(junior.id) && !Self.full(s), "\(kind): the earlier landing's author counts")
            }
            try m.exec("UPDATE workItem SET ownerId = ? WHERE id = ?", [m.eng.id, landed.id])
            #expect(Self.full(try await merge(m, .mainAtBase, itemId: nil, at: head)), "control again")
            _ = try GitFixture.plainGit(["commit", "-q", "--allow-empty", "-m", "outside"], in: m.root)
            s = try await merge(m, .mainAtBase, itemId: nil, at: try main(m))
            #expect(s.hasUnknown && !Self.full(s), "a head the queue did not land")
            try m.exec("UPDATE company SET mainCheckSetById = NULL WHERE id = ?", [m.company.id])
            s = try await merge(m, .mainAtBase, itemId: nil, at: head)
            #expect(s.hasUnknown && !Self.full(s), "no setter")
        }
        // preQueueDoneItemsArePrincipals
        do {
            let m = try MergeFixture()
            let head = try main(m)
            let junior = try m.store.hire(companyId: m.company.id, name: "jr", role: "junior", model: "sonnet")
            let ops = try m.store.hire(companyId: m.company.id, name: "ops-1", role: "ops", model: "sonnet")
            try m.store.updateSandbox(companyId: m.company.id, SandboxPatch(profile: .full), userHome: try tempDir())
            try roles(m, ["ops": .full, "engineer": .full, "junior": .workspace])
            try m.exec("UPDATE company SET mainCheckSetById = ? WHERE id = ?", [ops.id, m.company.id])
            let current = try m.item("Current")
            try m.exec("UPDATE workItem SET ownerId = ? WHERE id = ?", [m.eng.id, current.id])
            try m.exec("UPDATE workItem SET status = 'backlog' WHERE companyId = ? AND status = 'done'", [m.company.id])
            #expect(Self.full(try await merge(m, .mainAtBase, itemId: nil, at: head)), "control: a fresh company")
            let shipped = try m.item("Shipped before 4a")
            try m.exec("UPDATE workItem SET status = 'done', ownerId = ? WHERE id = ?", [m.eng.id, shipped.id])
            var s = try await merge(m, .mainAtBase, itemId: nil, at: head)
            #expect(s.hasUnknown && !Self.full(s), "main is no longer queue-landed")
            #expect(Self.full(try await merge(m, .main, itemId: current.id)))
            try m.exec("UPDATE workItem SET ownerId = ? WHERE id = ?", [junior.id, shipped.id])
            s = try await merge(m, .item, itemId: current.id)
            #expect(Self.agentIds(s) == [m.eng.id, junior.id] && !Self.full(s), "a done item's author is a principal")
            try m.exec("UPDATE workItem SET ownerId = NULL WHERE id = ?", [shipped.id])
            s = try await merge(m, .main, itemId: current.id)
            #expect(s.hasUnknown && !Self.full(s), "a done item with no author or holder is a missing principal")
        }
    }

    // MARK: preview, mainSmoke, release

    /// A surface whose setter is not recorded (an empty id: the column is `NOT NULL`), a main smoke with no setter, or a setter
    /// lookup that fails: `.unknown` (the old rule followed the company).
    @Test func previewNilSetterIsUnknown() async throws {
        let s = try S(profile: .full)
        let surface = try s.store.upsertPreviewSurface(companyId: s.company.id, by: .owner,
                                                       PreviewDraft(name: "web", run: "sleep 1", url: "http://127.0.0.1:{port}/"))
        let resolver = PrincipalResolver(store: s.store, ceiling: nil)
        try Self.exec(s.store, "UPDATE previewSurface SET setById = '' WHERE id = ?", [surface.id])
        var set = resolver.resolve(.preview(surfaceId: surface.id))
        #expect(Self.unknownReasons(set) == ["no one is recorded as setting it"] && !Self.full(set))
        try Self.exec(s.store, "UPDATE previewSurface SET setById = 'ghost-agent' WHERE id = ?", [surface.id])
        set = resolver.resolve(.preview(surfaceId: surface.id))
        #expect(Self.unknownReasons(set) == ["no agent ghost-agent in the company's records"] && !Self.full(set))
        try Self.exec(s.store, "UPDATE company SET smokeCheckSetById = NULL WHERE id = ?", [s.company.id])
        set = resolver.resolve(.mainSmoke(companyId: s.company.id))
        #expect(Self.unknownReasons(set) == ["no one is recorded as setting it"] && !Self.full(set))
        try Self.exec(s.store, "UPDATE company SET smokeCheckSetById = ? WHERE id = ?", [s.eng.id, s.company.id])
        set = resolver.resolve(.mainSmoke(companyId: s.company.id))
        #expect(Self.agentIds(set) == [s.eng.id] && Self.full(set))
        #expect(resolver.resolve(.preview(surfaceId: "no-such-surface")).hasUnknown)
        #expect(resolver.resolve(.mainSmoke(companyId: "no-such-company")).hasUnknown)
        #expect(resolver.resolve(.release(releaseId: "no-such-release")).hasUnknown)
    }

    /// `"owner"` is the company's owner: Full exactly when the company (after the ceiling) is.
    @Test func previewOwnerSetterIsOwner() async throws {
        let s = try S(profile: .full)
        let surface = try s.store.upsertPreviewSurface(companyId: s.company.id, by: .owner,
                                                       PreviewDraft(name: "web", run: "sleep 1", url: "http://127.0.0.1:{port}/"))
        #expect(surface.setById == "owner")
        let set = PrincipalResolver(store: s.store, ceiling: nil).resolve(.preview(surfaceId: surface.id))
        #expect(set.members == [.owner(companyId: s.company.id)] && Self.full(set))
        try s.store.updateSandbox(companyId: s.company.id, SandboxPatch(profile: .workspace), userHome: try tempDir())
        let narrowed = PrincipalResolver(store: s.store, ceiling: nil).resolve(.preview(surfaceId: surface.id))
        #expect(narrowed.members == [.owner(companyId: s.company.id)] && narrowed.ownerProfile == .workspace && !Self.full(narrowed))
        try Self.exec(s.store, "UPDATE company SET smokeCheckSetById = 'owner' WHERE id = ?", [s.company.id])
        #expect(PrincipalResolver(store: s.store, ceiling: nil).resolve(.mainSmoke(companyId: s.company.id)).members
                == [.owner(companyId: s.company.id)])
    }

    // MARK: worktree, publish, vaultBlob, extensionBundle, engine

    /// The current lease holder of the item with `key`, else the item's assignee, else `.unknown`; company-scoped.
    @Test func worktreeHolderThenOwner() throws {
        let s = try S(profile: .full)
        let item = try s.submitted()
        try Self.exec(s.store, "UPDATE workItem SET ownerId = ? WHERE id = ?", [s.eng2.id, item.id])
        let resolver = PrincipalResolver(store: s.store, ceiling: nil)
        #expect(Self.agentIds(resolver.resolve(.worktree(companyId: s.company.id, key: item.key))) == [s.eng.id])
        try Self.exec(s.store, "DELETE FROM workLease WHERE itemId = ?", [item.id])
        #expect(Self.agentIds(resolver.resolve(.worktree(companyId: s.company.id, key: item.key))) == [s.eng2.id])
        try Self.exec(s.store, "UPDATE workItem SET ownerId = NULL WHERE id = ?", [item.id])
        #expect(resolver.resolve(.worktree(companyId: s.company.id, key: item.key)).hasUnknown)
        #expect(resolver.resolve(.worktree(companyId: s.company.id, key: "NOPE-1")).hasUnknown)
        let other = try s.world.company("Other", profile: .full)
        #expect(resolver.resolve(.worktree(companyId: other.id, key: item.key)).hasUnknown, "another company's key")
        // publish: the publishing agent, or the owner.
        #expect(Self.agentIds(resolver.resolve(.publish(companyId: s.company.id, agentId: s.eng.id))) == [s.eng.id])
        #expect(resolver.resolve(.publish(companyId: s.company.id, agentId: nil)).members == [.owner(companyId: s.company.id)])
        #expect(resolver.resolve(.publish(companyId: other.id, agentId: s.eng.id)).hasUnknown, "another company's agent")
    }

    @Test func vaultBlobFollowsProvenance() throws {
        let s = try S(profile: .full)
        let resolver = PrincipalResolver(store: s.store, ceiling: nil)
        let cid = s.company.id
        #expect(Self.agentIds(resolver.resolve(.vaultBlob(companyId: cid, provenance: .agent(s.eng.id)))) == [s.eng.id])
        #expect(resolver.resolve(.vaultBlob(companyId: cid, provenance: .owner)).members == [.owner(companyId: cid)])
        let web = resolver.resolve(.vaultBlob(companyId: cid, provenance: .external("https://example.com/page")))
        #expect(web.members == [.external(source: "https://example.com/page")] && !web.allFull && web.commonGrantDomains == [])
        let engine = resolver.resolve(.vaultBlob(companyId: cid, provenance: .engine))
        #expect(engine.members == [.engine] && !engine.allFull)
        #expect(Self.unknownReasons(resolver.resolve(.vaultBlob(companyId: cid, provenance: .agent("ghost-agent"))))
                == ["no agent ghost-agent in the company's records"])
    }

    /// An extension is never Full-eligible (architect's call); the engine's own bytes are `.engine`.
    @Test func extensionIsExternal() throws {
        let s = try S(profile: .full)
        let resolver = PrincipalResolver(store: s.store, ceiling: nil)
        let ext = resolver.resolve(.extensionBundle(source: "acme/tool@1.0"))
        #expect(ext.members == [.external(source: "acme/tool@1.0")] && !ext.allFull && ext.commonGrantDomains == [])
        let engine = resolver.resolve(.engine)
        #expect(engine.members == [.engine] && !engine.allFull)
    }

    /// A store whose lookups throw (the table is renamed out from under it, S2's seam): every row resolves to `.unknown`, and
    /// nothing throws.
    @Test func lookupErrorIsUnknown() async throws {
        let s = try S(profile: .full)
        let item = try s.submitted()
        let run = try s.latest(item)
        let surface = try s.store.upsertPreviewSurface(companyId: s.company.id, by: .agent(s.eng.id),
                                                       PreviewDraft(name: "web", run: "sleep 1", url: "http://127.0.0.1:{port}/"))
        let resolver = PrincipalResolver(store: s.store, ceiling: nil)
        #expect(!resolver.resolve(.verificationRun(runId: run.id)).hasUnknown, "control")
        #expect(!resolver.resolve(.preview(surfaceId: surface.id)).hasUnknown, "control")
        try Self.exec(s.store, "ALTER TABLE agent RENAME TO agent_unreachable")
        #expect(throws: (any Error).self) { try s.store.agent(id: s.eng.id) }
        for subject: ActionSubject in [.verificationRun(runId: run.id), .preview(surfaceId: surface.id),
                                       .worktree(companyId: s.company.id, key: item.key),
                                       .publish(companyId: s.company.id, agentId: s.eng.id),
                                       .vaultBlob(companyId: s.company.id, provenance: .agent(s.eng.id))] {
            let set = resolver.resolve(subject)
            #expect(set.hasUnknown && !Self.full(set), "\(subject)")
            #expect(Self.unknownReasons(set).allSatisfy { $0.hasPrefix("the lookup failed") }, "\(subject): \(Self.unknownReasons(set))")
        }
        try Self.exec(s.store, "ALTER TABLE agent_unreachable RENAME TO agent")
        try Self.exec(s.store, "ALTER TABLE verificationRun RENAME TO verificationRun_unreachable")
        #expect(resolver.resolve(.verificationRun(runId: run.id)).hasUnknown)
        try Self.exec(s.store, "ALTER TABLE company RENAME TO company_unreachable")
        let noCompany = resolver.resolve(.preview(surfaceId: surface.id))
        #expect(noCompany.hasUnknown && !Self.full(noCompany))
    }

    /// The engine ceiling narrows the owner's profile and every agent's, whatever the subject.
    @Test func ceilingNarrowsEveryProfile() throws {
        let s = try S(profile: .full)
        let item = try s.submitted()
        let run = try s.latest(item)
        let surface = try s.store.upsertPreviewSurface(companyId: s.company.id, by: .agent(s.eng.id),
                                                       PreviewDraft(name: "web", run: "sleep 1", url: "http://127.0.0.1:{port}/"))
        try Self.exec(s.store, "UPDATE company SET smokeCheckSetById = ? WHERE id = ?", [s.eng.id, s.company.id])
        let subjects: [ActionSubject] = [.verificationRun(runId: run.id), .preview(surfaceId: surface.id), .mainSmoke(companyId: s.company.id),
                                         .worktree(companyId: s.company.id, key: item.key), .publish(companyId: s.company.id, agentId: s.eng.id),
                                         .vaultBlob(companyId: s.company.id, provenance: .agent(s.eng.id))]
        for (ceiling, expected) in [(nil, PermissionProfile.full), (.full, .full), (.workspace, .workspace), (.sandboxed, .sandboxed)]
            as [(PermissionProfile?, PermissionProfile)] {
            let resolver = PrincipalResolver(store: s.store, ceiling: ceiling)
            for subject in subjects {
                let set = resolver.resolve(subject)
                #expect(set.ownerProfile == expected && Self.profiles(set) == [expected], "\(subject) under \(String(describing: ceiling))")
                #expect(Self.full(set) == (expected == .full))
            }
            let owner = resolver.resolve(.publish(companyId: s.company.id, agentId: nil))
            #expect(owner.ownerProfile == expected && owner.allFull == (expected == .full))
        }
        // The company's own profile narrows its agents too (a Full role in a Workspace company is not Full).
        try s.store.updateSandbox(companyId: s.company.id, SandboxPatch(profile: .workspace, roleProfiles: ["engineer": .full]),
                                  userHome: try tempDir())
        let set = PrincipalResolver(store: s.store, ceiling: nil).resolve(.verificationRun(runId: run.id))
        #expect(Self.profiles(set) == [.workspace] && !Self.full(set))
    }

    // MARK: Resolve once

    /// Each migrated site resolves its subject exactly once per action: a merge run's check route, a verification run's,
    /// and a preview start.
    @Test func resolvesOncePerAction() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        try m.store.updateSandbox(companyId: m.company.id, SandboxPatch(profile: .full), userHome: try tempDir())
        let company = try #require(try m.store.company(id: m.company.id))
        let runId = UUID().uuidString
        let dir = try EngineExport.export(store: m.store, company: company, runId: runId, commit: try main(m))
        defer { EngineExport.remove(store: m.store, company: company, runId: runId) }
        let run = MergeRun(id: runId, companyId: company.id, kind: .main, itemId: i.id, status: .running)
        try await m.store.writer.write { try run.insert($0) }
        let route = Orchestrator.checkRoute(store: m.store)
        let merges = PrincipalResolver.ResolveCount()
        PrincipalResolver.$resolveCount.withValue(merges) { _ = route(dir.path) }
        #expect(merges.value == 1)

        let s = try S(profile: .full)
        let item = try s.submitted()
        let check = try s.latest(item)
        let checkout = s.git.checkoutPath(runId: check.id)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try Self.exec(s.store, "UPDATE verificationRun SET status = 'running', workingDirectory = ? WHERE id = ?", [checkout.path, check.id])
        let checks = PrincipalResolver.ResolveCount()
        PrincipalResolver.$resolveCount.withValue(checks) { _ = Orchestrator.checkRoute(store: s.store)(checkout.path) }
        #expect(checks.value == 1)

        let x = try PreviewRunnerTests.Fx(profile: .full)
        let previews = PrincipalResolver.ResolveCount()
        await PrincipalResolver.$resolveCount.withValue(previews) { await x.pass() }
        #expect(try x.state().status == .running)
        #expect(previews.value == 1)
        await x.stop()
    }

    // MARK: B1 activity lines

    /// Checks: a Full company's check whose holder the engine cannot confirm runs sandboxed with the B1 line (the text names the
    /// resolver's reason).
    @Test func b1LineForAnUnconfirmedCheck() async throws {
        let s = try S(profile: .full)
        let item = try s.submitted()
        let run = try s.latest(item)
        let checkout = s.git.checkoutPath(runId: run.id)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try Self.exec(s.store, "UPDATE verificationRun SET status = 'running', workingDirectory = ?, requestedBy = 'ghost-agent' WHERE id = ?",
                      [checkout.path, run.id])
        try Self.exec(s.store, "DELETE FROM workLease WHERE itemId = ?", [item.id])
        guard case .sandboxed = Orchestrator.checkRoute(store: s.store)(checkout.path) else {
            Issue.record("an unconfirmed check ran unsandboxed"); return
        }
        let lines = try Self.activity(s.store, s.company.id).filter { $0.contains("ran sandboxed") }
        #expect(lines == ["\(item.key) ran sandboxed: the engine could not confirm who wrote it (no agent ghost-agent in the company's records)"])
    }

    /// Previews: a Full company's surface whose setter is not a known agent starts in the sandbox, with the B1 line.
    @Test func b1LineForAnUnconfirmedPreview() async throws {
        let x = try PreviewRunnerTests.Fx(profile: .full)
        try Self.exec(x.store, "UPDATE previewSurface SET setById = 'ghost-agent' WHERE companyId = ?", [x.company.id])
        await x.pass()
        #expect(try x.state().status == .running)
        #expect(!x.spawns.isEmpty, "the sandbox ran it")
        #expect(x.unsandboxed.calls.isEmpty, "never the Full runner")
        let lines = try x.activity().filter { $0.contains("ran sandboxed") }
        #expect(lines == ["Preview web ran sandboxed: the engine could not confirm who wrote it (no agent ghost-agent in the company's records)"])
        await x.stop()
    }

    /// Main smokes: a Full company's smoke check with no recorded setter runs in the sandbox, with the B1 line.
    @Test func b1LineForAnUnconfirmedMainSmoke() async throws {
        let fx = try MainSmokeTests.Fx(profile: .full)
        try fx.setSmoke("test -f a.txt")
        try Self.exec(fx.store, "UPDATE company SET smokeCheckSetById = NULL WHERE id = ?", [fx.company.id])
        _ = try fx.merge(["a.txt": "x"])
        try await fx.w.cycle()
        #expect(fx.unsandboxed.calls.isEmpty); #expect(fx.sandbox.calls.count == 1)
        #expect(try fx.runs().first?.status == .passed)
        let lines = try Self.activity(fx.store, fx.company.id).filter { $0.contains("ran sandboxed") }
        #expect(lines == ["The main smoke check ran sandboxed: the engine could not confirm who wrote it (no one is recorded as setting it)"])
    }

    /// Release builds: a Full company's release whose proposer is not a known agent builds in the sandbox, with the B1 line.
    @Test func b1LineForAnUnconfirmedReleaseBuild() async throws {
        let fx = try ReleaseExecutorTests.Fx(profile: .full)
        try fx.preinstallTools()
        let approved = try fx.proposeAndApprove()
        #expect(PrincipalResolver(store: fx.store, ceiling: nil).resolve(.release(releaseId: approved.id)).members.count == 1)
        #expect(Self.agentIds(PrincipalResolver(store: fx.store, ceiling: nil).resolve(.release(releaseId: approved.id))) == [fx.devops.id])
        try Self.exec(fx.store, "UPDATE release SET proposedById = 'ghost-agent' WHERE id = ?", [approved.id])
        await fx.advance()
        let r = try fx.reload(approved)
        #expect(fx.calls(in: fx.export(r), of: fx.sandbox).count == 1, "the build ran in the sandbox")
        #expect(fx.unsandboxed.calls.isEmpty, "never the Full runner")
        let lines = try Self.activity(fx.store, fx.company.id).filter { $0.contains("ran sandboxed") }
        #expect(lines == ["\(r.ref) build ran sandboxed: the engine could not confirm who wrote it (no agent ghost-agent in the company's records)"])
    }
}
