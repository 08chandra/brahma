import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// A company with a real workspace repository, a reviewer and engineers, driven through the real tools (Plan 4a). Builds on
/// 3a's `World` and `GitFixture`; checks run on `World`'s fake runner.
struct MergeFixture {
    let world: World
    let company: Company
    let eng: Agent, eng2: Agent, eng3: Agent, rev: Agent
    let vault = MemoryVault()
    var store: Store { world.store }
    var now: Date { world.clock.now }
    var root: URL { URL(fileURLWithPath: company.workspacePath, isDirectory: true) }
    var ws: GitWorkspace { GitWorkspace(root: root) }
    static let check = "make test"

    init(autoMergeSmall: Bool = false, observers: [any WorkItemObserver] = []) throws {
        let w = try World(store: try Store.inMemory(observers: observers), vault: vault)
        let c = try w.company("Acme")
        if autoMergeSmall { try w.store.setAutoMergeSmall(companyId: c.id, true) }
        let lead = try w.store.hire(companyId: c.id, name: "mgr", role: "manager", model: "sonnet")
        world = w; company = c
        eng = try w.store.hire(companyId: c.id, name: "eng-1", role: "engineer", model: "sonnet", managerId: lead.id)
        eng2 = try w.store.hire(companyId: c.id, name: "eng-2", role: "engineer", model: "sonnet", managerId: lead.id)
        eng3 = try w.store.hire(companyId: c.id, name: "eng-3", role: "engineer", model: "sonnet", managerId: lead.id)
        rev = try w.store.hire(companyId: c.id, name: "rev", role: "engineer", model: "sonnet", managerId: lead.id)
    }

    func tools(_ a: Agent) -> CompanyTools { CompanyTools(store: store, companyId: company.id, agentId: a.id) }
    func reviewTools(_ a: Agent, _ i: WorkItem) -> CompanyTools {
        CompanyTools(store: store, companyId: company.id, agentId: a.id, reviewItemId: i.id)
    }
    func fresh(_ i: WorkItem) throws -> WorkItem { try #require(try store.workItem(id: i.id)) }
    func kinds(_ i: WorkItem) throws -> [WorkEventKind] { try store.itemEvents(itemId: i.id, limit: 500).map(\.kind) }
    func cycle() async throws {
        await world.orchestrator.tick()
        try await world.orchestrator.waitUntilIdle(timeout: .seconds(300))
    }
    func write(_ path: String, _ text: String, in dir: URL) throws {
        let url = dir.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func exec(_ sql: String, _ args: StatementArguments = []) throws {
        try store.writer.write { try $0.execute(sql: sql, arguments: args) }
    }
    func enqueue(_ item: WorkItem, ahead: Int, secretFindings: [String] = []) throws {
        try store.writer.write { db in try store.enqueueApproved(db: db, item: item, ahead: ahead, secretFindings: secretFindings, now: now) }
    }
    func cancelMerges(_ items: [WorkItem]) throws {
        try store.writer.write { db in for i in items { try store.cancelMerge(db: db, itemId: i.id) } }
    }
    func activity(_ kind: ActivityKind) throws -> [ActivityEvent] {
        try store.writer.read { try ActivityEvent.filter(Column("kind") == kind.rawValue).fetchAll($0) }
    }
    func head(_ i: WorkItem) throws -> String? { try ws.head(of: ws.branchRef(key: i.key)) }

    @discardableResult
    func item(_ title: String = "Do it", tier: EffortTier = .m) throws -> WorkItem {
        let n = (try store.workItems(companyId: company.id)).count + 1
        return try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: title, checkSpec: CheckSpec(command: Self.check, paths: ["src/p\(n)"]), tier: tier,
            reviewerId: rev.id, status: .ready), now: now)
    }

    /// Claim, change a file and submit through the tools.
    @discardableResult
    func claimAndSubmit(_ i: WorkItem, _ a: Agent? = nil, file: String = "src/work.txt") throws -> URL {
        let a = a ?? eng
        _ = try tools(a).call(name: "claim_lease", arguments: ["key": .string(i.key)])
        let wt = ws.worktreePath(key: i.key)
        try write(file, "work for \(i.key)", in: wt)
        _ = try tools(a).call(name: "submit_for_review", arguments: ["key": .string(i.key), "summary": .string("did the work")])
        return wt
    }

    /// An item that is claimed, submitted and has passed its engine check (awaiting the reviewer).
    func verified(_ title: String = "Do it", by author: Agent? = nil, file: String = "src/work.txt") async throws -> WorkItem {
        let i = try item(title)
        try claimAndSubmit(i, author, file: file)
        try await cycle()
        return try fresh(i)
    }

    /// The holder changes the branch and submits again; the engine check passes (awaiting the reviewer).
    func resubmit(_ i: WorkItem, by a: Agent? = nil, file: String) async throws {
        let wt = ws.worktreePath(key: i.key)
        try write(file, "second try for \(i.key)", in: wt)
        _ = try tools(a ?? eng).call(name: "submit_for_review", arguments: ["key": .string(i.key), "summary": .string("fixed it")])
        try await cycle()
    }

    @discardableResult
    func reviewTurn(_ a: Agent, _ i: WorkItem) throws -> Turn {
        let turn = try store.startTurn(agentId: a.id, now: now)
        try store.setTurnContext(turnId: turn.id, kind: .review, itemId: i.id)
        return turn
    }

    /// Approves through the real review tool; the tool's reply.
    @discardableResult
    func approve(_ i: WorkItem, flags: Bool = false) throws -> String {
        try reviewTurn(rev, i)
        return try reviewTools(rev, i).call(name: "review", arguments: [
            "key": .string(i.key), "decision": .string("approve"), "notes": .string("ok"), "approve_flags": .bool(flags)])
    }

    /// Verified, then approved through the tool: the item's merge request is queued.
    func approved(_ title: String = "Do it", by author: Agent? = nil, file: String = "src/work.txt") async throws -> WorkItem {
        let i = try await verified(title, by: author, file: file)
        try approve(i)
        return try fresh(i)
    }

    func dms(_ a: Agent) throws -> [String] {
        try store.writer.read { db in
            try Message.filter(Column("senderId") == "system").order(Column.rowID).fetchAll(db)
        }.compactMap { m in
            guard let ch = try store.writer.read({ try Channel.fetchOne($0, key: m.channelId) }),
                  ch.kind == .dm, ch.name.contains(a.name) else { return nil }
            return m.text
        }
    }
}
