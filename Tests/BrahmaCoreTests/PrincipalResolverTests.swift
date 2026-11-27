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
    @Test func ceilingNarrowsEveryProfile() async throws {
        let s = try S(profile: .full)
        let item = try s.submitted()
        let run = try s.latest(item)
        let surface = try s.store.upsertPreviewSurface(companyId: s.company.id, by: .agent(s.eng.id),
                                                       PreviewDraft(name: "web", run: "sleep 1", url: "http://127.0.0.1:{port}/"))
        try Self.exec(s.store, "UPDATE company SET smokeCheckSetById = ? WHERE id = ?", [s.eng.id, s.company.id])
        let merge = MergeRun(companyId: s.company.id, kind: .item, itemId: item.id, status: .running)
        try await s.store.writer.write { try merge.insert($0) }
        let subjects: [ActionSubject] = [.verificationRun(runId: run.id), .mergeRun(runId: merge.id), .preview(surfaceId: surface.id),
                                         .mainSmoke(companyId: s.company.id),
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

    // MARK: S6-c1: decide from the record the command comes from

    /// S6-c1 (TOCTOU to a sandbox bypass): the start reads the surface, then resolves. A setter changed in between must never
    /// give the command it read a decision made for someone else: the preview runs sandboxed or not at all, and a later pass
    /// starts the current surface under its own setter's decision.
    @Test func s6c1SetterChangedBetweenFetchAndResolve() async throws {
        // Owner -> agent (the brief's case): a Full company whose agent role is Full too.
        do {
            let x = try PreviewRunnerTests.Fx(profile: .full)
            let surface = try x.store.upsertPreviewSurface(companyId: x.company.id, by: .owner,
                                                           PreviewDraft(name: "web", run: "sleep 300", url: "http://127.0.0.1:{port}/"), now: x.now)
            #expect(surface.setById == "owner")
            let (store, devops) = (x.store, x.devops.id)
            await x.runner.setBeforeResolve { held in
                try? store.writer.write { db in
                    try db.execute(sql: "UPDATE previewSurface SET setById = ?, run = 'sleep 301' WHERE id = ?", arguments: [devops, held.id])
                }
            }
            await x.pass()
            #expect(x.unsandboxed.calls.isEmpty, "the owner's command never ran under the agent's decision")
            #expect(x.unsandboxed.calls.allSatisfy { !$0.command.contains("sleep 300") })
            await x.runner.setBeforeResolve(nil)
            await x.pass()
            #expect(!x.unsandboxed.calls.isEmpty && x.unsandboxed.calls.allSatisfy { $0.command.contains("sleep 301") },
                    "the next start runs the current surface under its own setter's decision")
            #expect(try x.state().status == .running)
            await x.stop()
        }
        // Agent -> owner (the bypass): a Workspace-role agent's command must never run under the owner's Full decision.
        do {
            let x = try PreviewRunnerTests.Fx(profile: .full)
            try x.store.updateSandbox(companyId: x.company.id, SandboxPatch(roleProfiles: [x.devops.role: .workspace]), userHome: try tempDir())
            let store = x.store
            await x.runner.setBeforeResolve { held in
                try? store.writer.write { db in
                    try db.execute(sql: "UPDATE previewSurface SET setById = 'owner', run = 'sleep 302' WHERE id = ?", arguments: [held.id])
                }
            }
            await x.pass()
            #expect(x.unsandboxed.calls.isEmpty, "the agent's command never ran unsandboxed")
            await x.runner.setBeforeResolve(nil)
            await x.pass()
            #expect(!x.unsandboxed.calls.isEmpty && x.unsandboxed.calls.allSatisfy { $0.command.contains("sleep 302") },
                    "only the owner's own command runs Full")
            #expect(x.spawns.allSatisfy { !$0.command.contains("sleep 302") })
            await x.stop()
        }
    }

    /// S6-c1 at every site that holds a record: the held record decides when its stored copy still matches (same members as the
    /// id-based resolution); a changed setter or command, or a record gone, is a denial (the caller runs nothing on it).
    @Test func s6c1HeldRecordMustStillMatch() async throws {
        let s = try S(profile: .full)
        let item = try s.submitted()
        let run = try s.latest(item)
        let resolver = PrincipalResolver(store: s.store, ceiling: nil)
        func allowed(_ d: Decision<PrincipalSet>) -> PrincipalSet? { if case .allow(let set, _) = d { return set }; return nil }
        func denied(_ d: Decision<PrincipalSet>) -> String? { if case .deny(let why) = d { return why }; return nil }
        // Checks (verification run).
        #expect(allowed(resolver.resolve(holding: .verificationRun(run))) == resolver.resolve(.verificationRun(runId: run.id)))
        try Self.exec(s.store, "UPDATE verificationRun SET requestedBy = ? WHERE id = ?", [s.eng2.id, run.id])
        #expect(denied(resolver.resolve(holding: .verificationRun(run))) == "verification run \(run.id) changed while it was starting")
        try Self.exec(s.store, "UPDATE verificationRun SET requestedBy = ?, command = 'true; curl evil' WHERE id = ?", [run.requestedBy, run.id])
        #expect(denied(resolver.resolve(holding: .verificationRun(run))) != nil, "a changed command")
        // Checks (merge run).
        let merge = MergeRun(companyId: s.company.id, kind: .item, itemId: item.id, status: .running)
        try await s.store.writer.write { try merge.insert($0) }
        #expect(allowed(resolver.resolve(holding: .mergeRun(merge))) == resolver.resolve(.mergeRun(runId: merge.id)))
        try Self.exec(s.store, "UPDATE mergeRun SET kind = 'main' WHERE id = ?", [merge.id])
        #expect(denied(resolver.resolve(holding: .mergeRun(merge))) != nil)
        // Previews: the setter, then the command.
        let surface = try s.store.upsertPreviewSurface(companyId: s.company.id, by: .owner,
                                                       PreviewDraft(name: "web", run: "sleep 1", url: "http://127.0.0.1:{port}/"))
        #expect(allowed(resolver.resolve(holding: .preview(surface)))?.members == [.owner(companyId: s.company.id)])
        try Self.exec(s.store, "UPDATE previewSurface SET setById = ? WHERE id = ?", [s.eng.id, surface.id])
        #expect(denied(resolver.resolve(holding: .preview(surface))) == "preview surface web changed while it was starting")
        try Self.exec(s.store, "UPDATE previewSurface SET setById = 'owner', build = 'make evil' WHERE id = ?", [surface.id])
        #expect(denied(resolver.resolve(holding: .preview(surface))) != nil, "a changed build command")
        try Self.exec(s.store, "DELETE FROM previewSurface WHERE id = ?", [surface.id])
        #expect(denied(resolver.resolve(holding: .preview(surface))) == "preview surface web is gone")
        // Main smokes: the held company's smoke check and its setter.
        let (cid, engId) = (s.company.id, s.eng.id)
        try await s.store.writer.write { db in
            var c = try #require(try Company.fetchOne(db, key: cid))
            c.smokeCheck = CheckSpec(command: "true"); c.smokeCheckSetById = engId
            try c.update(db)
        }
        let company = try #require(try s.store.company(id: s.company.id))
        #expect(Self.agentIds(try #require(allowed(resolver.resolve(holding: .mainSmoke(company))))) == [s.eng.id])
        try Self.exec(s.store, "UPDATE company SET smokeCheckSetById = 'owner' WHERE id = ?", [s.company.id])
        #expect(denied(resolver.resolve(holding: .mainSmoke(company))) == "the main smoke check changed while it was starting")
        // A store whose re-read throws: denied, never allowed.
        try Self.exec(s.store, "ALTER TABLE verificationRun RENAME TO verificationRun_unreachable")
        #expect(denied(resolver.resolve(holding: .verificationRun(run)))?.hasPrefix("verification run \(run.id) could not be read again") == true)
    }

    /// S6-c1 for release builds: the held release decides while its proposer and build are unchanged; otherwise the build is
    /// refused and nothing runs.
    @Test func s6c1ReleaseBuildNeedsItsHeldRecord() async throws {
        let fx = try ReleaseExecutorTests.Fx(profile: .full)
        try fx.preinstallTools()
        let approved = try fx.proposeAndApprove()
        let resolver = PrincipalResolver(store: fx.store, ceiling: nil)
        guard case .allow(let set, _) = resolver.resolve(holding: .release(approved)) else { Issue.record("denied"); return }
        #expect(Self.agentIds(set) == [fx.devops.id])
        #expect(set == resolver.resolve(.release(releaseId: approved.id)), "the held path and the id path agree when nothing changed")
        // M4: the ceiling narrows a release's principals too.
        for (ceiling, expected) in [(nil, PermissionProfile.full), (.workspace, .workspace), (.sandboxed, .sandboxed)]
            as [(PermissionProfile?, PermissionProfile)] {
            let ceiled = PrincipalResolver(store: fx.store, ceiling: ceiling).resolve(.release(releaseId: approved.id))
            #expect(ceiled.ownerProfile == expected && Self.profiles(ceiled) == [expected], "\(String(describing: ceiling))")
        }
        try Self.exec(fx.store, "UPDATE release SET proposedById = 'owner' WHERE id = ?", [approved.id])
        guard case .deny(let why) = resolver.resolve(holding: .release(approved)) else { Issue.record("allowed"); return }
        #expect(why == "\(approved.ref) changed while it was starting")
    }

    /// S6-c1: the same setter with a changed command, and a surface removed, between the start's read and its resolution: the
    /// start aborts back to idle with a restart requested; no failure is recorded, no setter is told, no B1 line is written.
    @Test func s6c1PreviewAbortIsQuiet() async throws {
        for removal in [false, true] {
            let x = try PreviewRunnerTests.Fx(profile: .full)
            let store = x.store
            await x.runner.setBeforeResolve { held in
                try? store.writer.write { db in
                    if removal {
                        try db.execute(sql: "DELETE FROM previewSurface WHERE id = ?", arguments: [held.id])
                    } else {
                        try db.execute(sql: "UPDATE previewSurface SET run = 'sleep 303' WHERE id = ?", arguments: [held.id])
                    }
                }
            }
            let surfaceId = try x.surface("web").id
            await x.pass()
            #expect(x.unsandboxed.calls.isEmpty && x.spawns.isEmpty, "removal \(removal): nothing ran on the stale record")
            let lines = try x.activity()
            #expect(!lines.contains { $0.contains("failed") || $0.contains("ran sandboxed") }, "removal \(removal): \(lines)")
            #expect(try x.messages().isEmpty, "removal \(removal): no setter was told")
            if !removal {
                let state = try #require(try x.store.previewStates(companyId: x.company.id)[surfaceId])
                #expect(state.status == .idle && state.restartRequestedAt != nil, "back to idle, a restart requested")
                await x.runner.setBeforeResolve(nil)
                await x.pass()
                #expect(!x.unsandboxed.calls.isEmpty && x.unsandboxed.calls.allSatisfy { $0.command.contains("sleep 303") })
            }
            await x.stop()
        }
    }

    /// S6-c1 (I1): the main smoke decides from the company it claimed. A Full agent re-setting the smoke check after a Workspace
    /// agent's run was claimed never gets that claimed command run unsandboxed: the run is not run on the stale record.
    @Test func s6c1MainSmokeSetterChangedAfterTheClaim() async throws {
        let fx = try MainSmokeTests.Fx(profile: .full)
        try fx.store.updateSandbox(companyId: fx.company.id, SandboxPatch(roleProfiles: ["devops": .workspace]), userHome: try tempDir())
        try fx.setSmoke("test -f a.txt")
        let head = try fx.merge(["a.txt": "x"])
        let (store, cid, engId) = (fx.store, fx.company.id, fx.eng.id)
        var checks = SmokeChecks(sandbox: fx.sandbox, unsandboxed: fx.unsandboxed, paths: fx.w.paths)
        checks.afterClaim = { _ in
            try? store.writer.write { db in
                try db.execute(sql: "UPDATE company SET smokeCheckSetById = ? WHERE id = ?", arguments: [engId, cid])
            }
        }
        let run = try await fx.store.runSmoke(companyId: cid, commit: head, reason: .manual, releaseId: nil, checks: checks,
                                              blocking: Blocking(), clock: { Date() })
        #expect(fx.unsandboxed.calls.isEmpty, "the claimed command never ran under the new setter's Full decision")
        #expect(fx.sandbox.calls.isEmpty, "nothing ran on the stale record")
        #expect(run.status == .error && run.outputTail == "the smoke check changed while it was starting", "\(run)")
    }

    /// S6-c1 (M0): the release build decides from the release it holds; a proposer or build changed before the build is the
    /// integrity failure, and no build runs.
    @Test func s6c1ReleaseChangedBeforeTheBuild() async throws {
        for change in ["UPDATE release SET proposedById = 'owner' WHERE id = ?", "UPDATE release SET build = 'echo evil' WHERE id = ?"] {
            let fx = try ReleaseExecutorTests.Fx(smoke: "sleep 2", profile: .full)
            try fx.store.updateSandbox(companyId: fx.company.id, SandboxPatch(roleProfiles: ["devops": .workspace]), userHome: try tempDir())
            try fx.preinstallTools()
            let approved = try fx.proposeAndApprove()
            async let advanced: Void = fx.advance()
            await fx.smokeSandbox.waitForRun { $0.command == "sleep 2" }
            try Self.exec(fx.store, change, [approved.id])
            await advanced
            let r = try fx.reload(approved)
            #expect(fx.calls(in: fx.export(r), of: fx.unsandboxed).isEmpty && fx.calls(in: fx.export(r), of: fx.sandbox).isEmpty,
                    "\(change): no build ran")
            #expect(r.status == .failed && r.failedReason == "the approved commands no longer match; propose again", "\(change): \(r)")
        }
    }

    /// S6-c1 (I2): a main-check merge run whose recorded command is not the company's current main check (re-set mid-batch)
    /// has a principal the engine cannot vouch for: sandboxed, with the reason.
    @Test func s6c1MergeRunMainCheckMustMatch() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        try m.store.updateSandbox(companyId: m.company.id, SandboxPatch(profile: .full), userHome: try tempDir())
        let (cid, engId) = (m.company.id, m.eng.id)
        try await m.store.writer.write { db in
            var c = try #require(try Company.fetchOne(db, key: cid))
            c.mainCheck = CheckSpec(command: "make smoke"); c.mainCheckSetById = engId
            try c.update(db)
        }
        let company = try #require(try m.store.company(id: cid))
        func route(_ kind: MergeRun.Kind, command: String?) async throws -> (CheckRoute, PrincipalSet) {
            let runId = UUID().uuidString
            let dir = try EngineExport.export(store: m.store, company: company, runId: runId, commit: try main(m))
            let run = MergeRun(id: runId, companyId: cid, candidateCommit: try main(m), kind: kind, itemId: i.id, command: command,
                               status: .running)
            try await m.store.writer.write { try run.insert($0) }
            return (Orchestrator.checkRoute(store: m.store)(dir.path), PrincipalResolver(store: m.store, ceiling: nil).resolve(.mergeRun(runId: runId)))
        }
        func sandboxed(_ r: CheckRoute) -> Bool { if case .sandboxed = r { return true } else { return false } }
        let (same, sameSet) = try await route(.main, command: "make smoke")
        #expect(!sandboxed(same) && !sameSet.hasUnknown, "control: the recorded command is the current main check")
        let (changed, changedSet) = try await route(.main, command: "make weaker")
        #expect(sandboxed(changed))
        #expect(Self.unknownReasons(changedSet) == ["the main check changed since this run started"])
        let (_, atBase) = try await route(.mainAtBase, command: "make weaker")
        #expect(Self.unknownReasons(atBase).contains("the main check changed since this run started"))
        let (_, item) = try await route(.item, command: "make test")
        #expect(!Self.unknownReasons(item).contains("the main check changed since this run started"), "an item run has its own check")
    }

    // MARK: B1 negatives (M2)

    /// No B1 line when the company is not Full, when the ceiling narrows it below Full, or when the setter is a known non-Full
    /// agent (the ordinary sandboxed route): previews.
    @Test func b1NoLineForPreviewsUnlessAnUnconfirmedFullDecision() async throws {
        func lines(_ x: PreviewRunnerTests.Fx, runner: PreviewRunner? = nil) async throws -> [String] {
            let r = runner ?? x.runner
            await r.reconcile(now: x.now)
            await r.waitForStarts()
            await r.stopAll()
            return try x.activity().filter { $0.contains("ran sandboxed") }
        }
        let notFull = try PreviewRunnerTests.Fx(profile: .workspace)
        try Self.exec(notFull.store, "UPDATE previewSurface SET setById = 'ghost-agent' WHERE companyId = ?", [notFull.company.id])
        #expect(try await lines(notFull).isEmpty, "a Workspace company")
        let ceiled = try PreviewRunnerTests.Fx(profile: .full)
        try Self.exec(ceiled.store, "UPDATE previewSurface SET setById = 'ghost-agent' WHERE companyId = ?", [ceiled.company.id])
        let paths = ceiled.w.paths
        let narrowed = PreviewRunner(store: ceiled.store, paths: paths, deps: ceiled.deps,
                                     sandboxLayout: { SandboxLayout(paths: paths, company: $0, agentHandle: "preview") },
                                     timeouts: PreviewRunnerTests.Fx.fast, memory: { false }, clock: ceiled.w.clock.function, ceiling: .workspace)
        #expect(try await lines(ceiled, runner: narrowed).isEmpty, "a Full company under a Workspace ceiling")
        let known = try PreviewRunnerTests.Fx(profile: .full)
        try known.store.updateSandbox(companyId: known.company.id, SandboxPatch(roleProfiles: [known.devops.role: .workspace]), userHome: try tempDir())
        #expect(try await lines(known).isEmpty, "a known Workspace-role setter")
        #expect(!known.spawns.isEmpty && known.unsandboxed.calls.isEmpty, "it ran sandboxed, silently")
    }

    /// Main smokes: the same three negatives.
    @Test func b1NoLineForMainSmokesUnlessAnUnconfirmedFullDecision() async throws {
        func lines(profile: PermissionProfile, ceiling: PermissionProfile?, setter: (MainSmokeTests.Fx) -> String?,
                   roles: [String: PermissionProfile]? = nil) async throws -> [String] {
            let fx = try MainSmokeTests.Fx(profile: profile)
            if let roles { try fx.store.updateSandbox(companyId: fx.company.id, SandboxPatch(roleProfiles: roles), userHome: try tempDir()) }
            try fx.setSmoke("true")
            try Self.exec(fx.store, "UPDATE company SET smokeCheckSetById = ? WHERE id = ?", [setter(fx), fx.company.id])
            let head = try fx.merge(["a.txt": "x"])
            let checks = SmokeChecks(sandbox: fx.sandbox, unsandboxed: fx.unsandboxed, paths: fx.w.paths, ceiling: ceiling)
            let run = try await fx.store.runSmoke(companyId: fx.company.id, commit: head, reason: .manual, releaseId: nil, checks: checks,
                                                  blocking: Blocking(), clock: { Date() })
            #expect(run.status == .passed && fx.unsandboxed.calls.isEmpty)
            return try Self.activity(fx.store, fx.company.id).filter { $0.contains("ran sandboxed") }
        }
        #expect(try await lines(profile: .workspace, ceiling: nil, setter: { _ in nil }).isEmpty, "a Workspace company")
        #expect(try await lines(profile: .full, ceiling: .workspace, setter: { _ in nil }).isEmpty, "a Workspace ceiling")
        #expect(try await lines(profile: .full, ceiling: nil, setter: { $0.devops.id }, roles: ["devops": .workspace]).isEmpty,
                "a known Workspace-role setter")
        #expect(try await lines(profile: .full, ceiling: nil, setter: { _ in nil }).count == 1, "control: the unconfirmed Full case")
    }

    /// Release builds: no line in a Workspace company, under a ceiling (resolver level: the executor's ceiling is the
    /// orchestrator's), or for a known non-Full proposer.
    @Test func b1NoLineForReleaseBuildsUnlessAnUnconfirmedFullDecision() async throws {
        for (profile, roles, ghost) in [(PermissionProfile.workspace, nil, true), (.full, ["devops": PermissionProfile.workspace], false)]
            as [(PermissionProfile, [String: PermissionProfile]?, Bool)] {
            let fx = try ReleaseExecutorTests.Fx(profile: profile)
            if let roles { try fx.store.updateSandbox(companyId: fx.company.id, SandboxPatch(roleProfiles: roles), userHome: try tempDir()) }
            try fx.preinstallTools()
            let approved = try fx.proposeAndApprove()
            if ghost { try Self.exec(fx.store, "UPDATE release SET proposedById = 'ghost-agent' WHERE id = ?", [approved.id]) }
            if profile == .full {
                guard case .allow(let ceiled, _) = PrincipalResolver(store: fx.store, ceiling: .workspace).resolve(holding: .release(try fx.reload(approved)))
                else { Issue.record("denied"); continue }
                #expect(ceiled.unconfirmedInFullCompany == nil && !ceiled.runsUnsandboxed, "a Workspace ceiling")
            }
            await fx.advance()
            let r = try fx.reload(approved)
            #expect(fx.calls(in: fx.export(r), of: fx.sandbox).count == 1 && fx.unsandboxed.calls.isEmpty, "\(profile): sandboxed build")
            #expect(try Self.activity(fx.store, fx.company.id).allSatisfy { !$0.contains("ran sandboxed") }, "\(profile)")
        }
    }

    /// Ruling S6-2 pinned: an unknown merge-run principal runs sandboxed without a line.
    @Test func b1NoLineForAnUnknownMergeRunPrincipal() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        try m.store.updateSandbox(companyId: m.company.id, SandboxPatch(profile: .full), userHome: try tempDir())
        let company = try #require(try m.store.company(id: m.company.id))
        let runId = UUID().uuidString
        let dir = try EngineExport.export(store: m.store, company: company, runId: runId, commit: try main(m))
        let run = MergeRun(id: runId, companyId: company.id, kind: .main, itemId: i.id, status: .running)   // no setter: unknown
        try await m.store.writer.write { try run.insert($0) }
        guard case .sandboxed = Orchestrator.checkRoute(store: m.store)(dir.path) else { Issue.record("not sandboxed"); return }
        #expect(try Self.activity(m.store, m.company.id).allSatisfy { !$0.contains("ran sandboxed") })
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
