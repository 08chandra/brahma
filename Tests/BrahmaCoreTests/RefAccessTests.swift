import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan C Task C1b's world: company C (prefix ENG) with `@cto`, `@eng-1`, `@qa-2`, `@eng-3`, `#eng` {eng-1}, a DM
/// owner↔eng-1, resources F-1 (scope agent(cto), readerSet [cto]), F-2 (company) and F-3 (flagged: secret), ask A-5
/// (asked by eng-1, approver cto), a restricted kb page, an hr/perf memory entry, item ENG-1 (inReview, held by eng-3) with
/// a branch, and a workspace repository; company D beside it with objects of its own.
struct RefFixture {
    let store: Store
    let c: Company, d: Company
    let cto: Agent, eng1: Agent, qa2: Agent, eng3: Agent
    let git: GitFixture
    let item: WorkItem
    let engChannel: Channel
    let engMessage: Message, dmMessage: Message
    let hrMemory: Int
    let now = Store.now()

    init() throws {
        let s = try Store.inMemory()
        store = s
        c = try s.createCompany(name: "Eng", goal: "g", workspacesRoot: try tempDir())
        d = try s.createCompany(name: "Dco", goal: "g", workspacesRoot: try tempDir())
        #expect(Store.keyPrefix(slug: c.slug) == "ENG")
        cto = try s.hire(companyId: c.id, name: "cto", role: "cto", model: "sonnet")
        eng1 = try s.hire(companyId: c.id, name: "eng-1", role: "engineer", model: "sonnet", managerId: cto.id)
        qa2 = try s.hire(companyId: c.id, name: "qa-2", role: "engineer", model: "sonnet", managerId: cto.id)
        eng3 = try s.hire(companyId: c.id, name: "eng-3", role: "engineer", model: "sonnet", managerId: cto.id)

        // The repository: main with two files, and item/ENG-1 with a change to each plus a new one.
        git = GitFixture(existing: URL(fileURLWithPath: c.workspacePath))
        let tsx = (1...49).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try git.write("src/checkout.tsx", tsx)
        try git.write("src/a.ts", "one\ntwo\n")
        try git.write("Sources/App.swift", "let a = 1\nlet b = 2\nlet c = 3\n")
        try git.git(["add", "-A"])
        try git.git(["commit", "-q", "-m", "files"])
        item = try s.createWorkItem(companyId: c.id, by: .owner, draft: WorkItemDraft(type: .task, title: "Checkout"))
        #expect(item.key == "ENG-1")
        let (eng3Id, itemId) = (eng3.id, item.id)
        try s.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET status = 'inReview', ownerId = ? WHERE id = ?", arguments: [eng3Id, itemId])
        }
        try git.git(["checkout", "-q", "-b", "item/ENG-1"])
        try git.write("src/a.ts", "one\nTWO\nthree\n")
        try git.write("src/b.ts", "b\n")
        try git.git(["add", "-A"])
        try git.git(["commit", "-q", "-m", "item work"])
        try git.git(["checkout", "-q", "main"])

        // Labs and notes.
        try git.write(".brahma/labs/qa-2/x", "qa lab\n")
        try git.write(".brahma/labs/eng-1/mine.txt", "eng lab\n")

        // Messages.
        let router = MessageRouter(store: s)
        engChannel = try s.createChannel(companyId: c.id, name: "eng", members: [eng1.id])
        engMessage = try router.post(companyId: c.id, channel: "eng", from: .agent(eng1.id), text: "channel hello")
        dmMessage = try router.sendDM(companyId: c.id, from: .owner, to: "eng-1", text: "private hello")

        // Resources, the ask and the memory.
        let now = self.now
        let (cId, ctoId, eng1Id) = (c.id, cto.id, eng1.id)
        try s.writer.write { db in
            try Resource(companyId: cId, number: 1, kind: .file, displayName: "plan.pdf", ext: "pdf", bytes: 1200, scopeKind: "agent",
                         scopeId: ctoId, readerSet: [ctoId], provenance: "owner", tainted: false, addedVia: "library",
                         createdAt: now, updatedAt: now).insert(db)
            try Resource(companyId: cId, number: 2, kind: .file, displayName: "brief.md", ext: "md", bytes: 300, scopeKind: "company",
                         scopeId: nil, readerSet: nil, provenance: "owner", tainted: false, addedVia: "library",
                         createdAt: now, updatedAt: now).insert(db)
            try Resource(companyId: cId, number: 3, kind: .file, displayName: "keys.env", ext: "env", bytes: 40, scopeKind: "company",
                         scopeId: nil, readerSet: nil, provenance: "owner", tainted: false, secretScan: .flagged, addedVia: "library",
                         createdAt: now, updatedAt: now).insert(db)
            try Ask(id: UUID().uuidString, companyId: cId, number: 5, kind: .info, risk: .low, requesterId: eng1Id,
                    title: "Which API?", summary: "s", status: .pendingInternal, internalApproverId: ctoId, createdActive: 0,
                    statusSinceActive: 0, createdAt: now, updatedAt: now).insert(db)
        }
        _ = try s.kbWrite(companyId: c.id, by: .owner, path: "HR/Policies", body: "# Policies\n\nPrivate text.\n", knownValues: [])
        try s.writer.write { db in
            try db.execute(sql: "UPDATE kbPage SET restriction = ? WHERE companyId = ? AND path = 'HR/Policies'",
                           arguments: ["[\"@executive\"]", cId])
        }
        guard case .created(let entry) = try s.remember(companyId: c.id, by: eng1.id, fact: "eng-3 had a rough review",
                                                         scope: .company, knownValues: []) else {
            throw FakeError(description: "remember did not create")
        }
        hrMemory = entry.number
        try s.writer.write { db in
            try db.execute(sql: "UPDATE memoryDoc SET sensitivity = 'hr-perf' WHERE companyId = ? AND source = 'memory' AND ref = ?",
                           arguments: [cId, entry.ref])
        }
    }

    var ctx: RefContext { RefContext(companyId: c.id, keyPrefixes: ["ENG"]) }

    func ref(_ s: String) throws -> WorkRef { try #require(WorkRef.parse(s, context: ctx)) }

    func reader(_ who: Who) -> Reader {
        switch who {
        case .owner: .owner
        case .concierge: .concierge
        case .cto: .agent(cto.id)
        case .eng1: .agent(eng1.id)
        case .qa2: .agent(qa2.id)
        }
    }

    func ref(_ target: Target) throws -> WorkRef {
        switch target {
        case .f1: try ref("F-1")
        case .f2: try ref("F-2")
        case .secret: try ref("F-3")
        case .engMessage: try ref("msg:\(engMessage.id)")
        case .engThread: try ref("thread:\(engMessage.id)")
        case .dmMessage: try ref("msg:\(dmMessage.id)")
        case .a5: try ref("A-5")
        case .qa2Lab: try ref(".brahma/labs/qa-2/x")
        case .hrMemory: try ref("mem:\(hrMemory)")
        case .restrictedKB: try ref("kb:HR/Policies")
        case .item: try ref("ENG-1")
        case .file: try ref("src/a.ts")
        case .engChannel: try ref("#eng")
        case .home: try ref(".brahma/home/qa-2/t")
        }
    }

    func canRead(_ who: Who, _ target: Target) throws -> RefDecision {
        let r = try ref(target)
        let reader = reader(who)
        return try store.writer.read { db in try RefAccess.canRead(reader, r, companyId: c.id, db: db, catalog: store.catalog) }
    }

    func resolve(_ who: Who, _ ref: WorkRef) throws -> ResolvedRef {
        try store.resolveRef(ref, for: reader(who), companyId: c.id)
    }

    func head(_ branch: String = "main") throws -> String { try git.git(["rev-parse", "--verify", branch + "^{commit}"]) }

    enum Who: String, Sendable { case owner, concierge, cto, eng1, qa2 }
    enum Target: String, Sendable {
        case f1, f2, secret, engMessage, engThread, dmMessage, a5, qa2Lab, hrMemory, restrictedKB, item, file, engChannel, home
    }
}

extension RefFixture {
    /// 4a's `AR-<number>` row, inserted as is (C's tests need titles no publish accepts). In C its source checks out clean
    /// (ruling 16): `art/<number>/index.html` committed on `main` at the recorded head, and a copy of the same 12 bytes in its
    /// folder. In another company it is a row only.
    @discardableResult
    func seedArtifact(_ number: Int, title: String, companyId: String? = nil, tainted: Bool = false, taintReason: String? = nil,
                      publishedById: String = "owner") throws -> Artifact {
        let company = companyId ?? c.id
        let body = String(format: "<p>%06d</p>", number)
        var source = "/seeded/index.html"
        if company == c.id {
            try git.write("art/\(number)/index.html", body)
            try git.git(["add", "--", "art/\(number)/index.html"])
            try git.git(["commit", "-q", "-m", "art \(number)"])
            let main = try head()
            try store.writer.write { db in try db.execute(sql: "UPDATE company SET mainCommit = ? WHERE id = ?", arguments: [main, company]) }
            try git.write(".brahma/artifacts/\(number)-seeded/index.html", body)
            source = (Store.realPath(c.workspacePath) ?? c.workspacePath) + "/art/\(number)"
        }
        let a = Artifact(id: UUID().uuidString, companyId: company, number: number, title: title, kind: .html,
                         storedPath: ".brahma/artifacts/\(number)-seeded", entryFile: "index.html", sourcePath: source,
                         publishedById: publishedById, itemId: nil, bytes: 12, createdAt: now, tainted: tainted, taintReason: taintReason)
        try store.writer.write { db in try a.insert(db) }
        return a
    }
}

enum AccessFixture {
    struct Row: Sendable, CustomTestStringConvertible {
        var who: RefFixture.Who
        var target: RefFixture.Target
        var expected: RefDecision
        var testDescription: String { "\(who.rawValue)·\(target.rawValue)" }
    }

    static let rows: [Row] = [
        Row(who: .owner, target: .f1, expected: .allowed(.privateToAgent)),
        Row(who: .eng1, target: .f1, expected: .locked(approverRole: "owner")),
        Row(who: .cto, target: .f1, expected: .allowed(.privateToAgent)),
        Row(who: .eng1, target: .f2, expected: .allowed(.company)),
        Row(who: .qa2, target: .engMessage, expected: .locked(approverRole: "owner")),
        Row(who: .qa2, target: .engThread, expected: .locked(approverRole: "owner")),
        Row(who: .eng1, target: .engMessage, expected: .allowed(.channel)),
        Row(who: .qa2, target: .dmMessage, expected: .refused),
        Row(who: .eng1, target: .dmMessage, expected: .allowed(.dm)),
        Row(who: .owner, target: .dmMessage, expected: .allowed(.dm)),
        Row(who: .qa2, target: .a5, expected: .refused),
        Row(who: .eng1, target: .a5, expected: .allowed(.agent)),
        Row(who: .cto, target: .a5, expected: .allowed(.agent)),
        Row(who: .eng1, target: .qa2Lab, expected: .refused),
        Row(who: .qa2, target: .qa2Lab, expected: .allowed(.privateToAgent)),
        Row(who: .owner, target: .qa2Lab, expected: .allowed(.privateToAgent)),
        Row(who: .eng1, target: .hrMemory, expected: .refused),
        Row(who: .owner, target: .hrMemory, expected: .allowed(.hrPerf)),
        Row(who: .concierge, target: .f1, expected: .allowed(.privateToAgent)),
        Row(who: .concierge, target: .secret, expected: .refused),
        Row(who: .eng1, target: .secret, expected: .refused),
        Row(who: .owner, target: .secret, expected: .allowed(.secret)),
        Row(who: .eng1, target: .restrictedKB, expected: .locked(approverRole: "owner")),
        Row(who: .owner, target: .restrictedKB, expected: .allowed(.restricted)),
        Row(who: .qa2, target: .item, expected: .allowed(.company)),
        Row(who: .qa2, target: .file, expected: .allowed(.company)),
        Row(who: .eng1, target: .engChannel, expected: .allowed(.channel)),
        Row(who: .qa2, target: .engChannel, expected: .locked(approverRole: "owner")),
        Row(who: .qa2, target: .home, expected: .refused),
        Row(who: .owner, target: .home, expected: .refused),
    ]
}

/// Plan C Task C1b: `RefAccess.canRead`, the design §4.2 class table decided through ML's one access engine.
@Suite(.scratch) struct RefAccessTests {
    @Test(arguments: AccessFixture.rows) func accessMatrix(_ row: AccessFixture.Row) throws {
        let fx = try RefFixture()
        #expect(try fx.canRead(row.who, row.target) == row.expected)
    }

    /// An agent of another company, and an unknown object, are refused alike.
    @Test func otherCompanyReaderRefused() throws {
        let fx = try RefFixture()
        let outsider = try fx.store.hire(companyId: fx.d.id, name: "spy", role: "engineer", model: "sonnet")
        let ref = try fx.ref("F-2")
        let decision = try fx.store.writer.read { db in try RefAccess.canRead(.agent(outsider.id), ref, companyId: fx.c.id, db: db, catalog: fx.store.catalog) }
        #expect(decision == .refused)
        let missing = try fx.ref("F-99")
        #expect(try fx.store.writer.read { db in try RefAccess.canRead(.owner, missing, companyId: fx.c.id, db: db, catalog: fx.store.catalog) } == .refused)
    }

    /// D's object of every kind, resolved for a C reader, is `.missing` with nothing in it: the same as an id no company has.
    @Test(arguments: WorkRefKind.allCases.filter { $0 != .fact }) func crossCompanyForbiddenAllKinds(_ k: WorkRefKind) throws {
        let fx = try RefFixture()
        let foreign = try CrossCompany.foreignRef(k, fx)
        let unknown = CrossCompany.unknownRef(k)
        for who in [RefFixture.Who.owner, .eng1] {
            let a = try fx.resolve(who, foreign)
            let b = try fx.resolve(who, unknown)
            for r in [a, b] {
                #expect(r.visibility == .missing, "\(k) \(who)")
                #expect(r.title == "" && r.subtitle == "" && r.bytes == nil, "\(k) \(who)")
                #expect(r.ref.id == "" && r.ref.branch == nil && r.ref.rev == nil && r.ref.range == nil && r.ref.params.isEmpty)
                #expect(r.ref.kind == k)
                #expect(!r.opaqueId.isEmpty)
                #expect(r.newer == nil)
            }
            var (x, y) = (a, b)
            x.opaqueId = ""; y.opaqueId = ""
            #expect(x == y, "\(k) \(who)")
            // And D's own reader sees it (it exists).
            let own = try fx.store.resolveRef(foreign, for: .owner, companyId: fx.d.id)
            #expect(own.visibility == .full, "\(k) in D")
        }
    }
}

/// D's objects, one per kind, each named the way a C ref would name it (and absent from C).
enum CrossCompany {
    static func foreignRef(_ k: WorkRefKind, _ fx: RefFixture) throws -> WorkRef {
        let s = fx.store, d = fx.d
        let now = fx.now
        let dGit = GitFixture(existing: URL(fileURLWithPath: d.workspacePath))
        let agent = try s.hire(companyId: d.id, name: "dagent", role: "engineer", model: "sonnet")
        try dGit.write("d-only.txt", "d\n")
        try dGit.git(["add", "-A"])
        try dGit.git(["commit", "-q", "-m", "d"])
        let dItem = try s.createWorkItem(companyId: d.id, by: .owner, draft: WorkItemDraft(type: .task, title: "D item"))
        try dGit.git(["checkout", "-q", "-b", "item/\(dItem.key)"])
        try dGit.write("d-item.txt", "x\n")
        try dGit.git(["add", "-A"])
        try dGit.git(["commit", "-q", "-m", "d item"])
        try dGit.git(["checkout", "-q", "main"])
        let dHead = try dGit.git(["rev-parse", "main"])
        func ref(_ kind: WorkRefKind, _ id: String, params: [String: String] = [:]) -> WorkRef {
            WorkRef(kind: kind, id: id, params: params)
        }
        switch k {
        case .file: return ref(.file, "d-only.txt")
        case .diff: return ref(.diff, dItem.key)
        case .commit: return ref(.commit, dHead)
        case .item: return ref(.item, dItem.key)
        case .ask:
            try s.writer.write { db in
                try Ask(id: UUID().uuidString, companyId: d.id, number: 50, kind: .info, risk: .low, requesterId: agent.id,
                        title: "D ask", summary: "s", status: .pendingOwner, createdActive: 0, statusSinceActive: 0,
                        createdAt: now, updatedAt: now).insert(db)
            }
            return ref(.ask, "50")
        case .kb:
            _ = try s.kbWrite(companyId: d.id, by: .owner, path: "Dept/Only", body: "# Only\n\nd\n", knownValues: [])
            return ref(.kb, "Dept/Only")
        case .memory:
            guard case .created(let entry) = try s.remember(companyId: d.id, by: agent.id, fact: "d fact", scope: .company,
                                                             knownValues: []) else { throw FakeError(description: "remember") }
            try s.writer.write { db in
                try db.execute(sql: "UPDATE memoryEntry SET number = 50 WHERE id = ?", arguments: [entry.id])
                try db.execute(sql: "UPDATE memoryDoc SET ref = 'mem:50' WHERE companyId = ? AND ref = ?", arguments: [d.id, entry.ref])
            }
            return ref(.memory, "50")
        case .artifact:
            try fx.seedArtifact(1, title: "D page", companyId: d.id)
            return ref(.artifact, "1")
        case .resource:
            try s.writer.write { db in
                try Resource(companyId: d.id, number: 50, kind: .file, displayName: "d.pdf", ext: "pdf", bytes: 9, scopeKind: "company",
                             scopeId: nil, readerSet: nil, provenance: "owner", tainted: false, addedVia: "library",
                             createdAt: now, updatedAt: now).insert(db)
            }
            return ref(.resource, "50")
        case .preview:
            try s.writer.write { db in
                try PreviewSurface(id: UUID().uuidString, companyId: d.id, name: "dweb", position: 0, build: nil, run: "npm start",
                                   url: "http://127.0.0.1:{port}/", setById: agent.id, createdAt: now, updatedAt: now).insert(db)
            }
            return ref(.preview, "dweb")
        case .run:
            try s.writer.write { db in
                try VerificationRun(id: "drun", companyId: d.id, itemId: dItem.id, checkRevision: 0, scriptHash: "h", commit: dHead,
                                    command: "true", workingDirectory: ".", timeoutSeconds: 60, purpose: .submit, status: .passed,
                                    exitCode: 0, createdAt: now).insert(db)
            }
            return ref(.run, "drun")
        case .release:
            try s.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO release (id, companyId, number, version, status, provider, project, "commit", plan, commandsHash,
                      rollbackPlan, proposedById, createdAt) VALUES (?, ?, 50, '1.0', 'deployed', 'p', 'p', ?, '{}', 'h', '{}', ?, ?)
                    """, arguments: [UUID().uuidString, d.id, dHead, agent.id, now])
            }
            return ref(.release, "50")
        case .message, .thread:
            let m = try MessageRouter(store: s).post(companyId: d.id, channel: "general", from: .owner, text: "d hello")
            return ref(k, m.id)
        case .agent: return ref(.agent, "dagent")
        case .channel:
            _ = try s.createChannel(companyId: d.id, name: "dchan", members: [agent.id])
            return ref(.channel, "dchan")
        case .sprint:
            try s.writer.write { db in
                try Sprint(id: UUID().uuidString, companyId: d.id, number: 50, team: nil, goal: "g", cadence: .sprint, status: .active,
                           createdAt: now).insert(db)
            }
            return ref(.sprint, "50")
        case .fact: return ref(.fact, "x")
        }
    }

    /// An id no company has, of the same kind.
    static func unknownRef(_ k: WorkRefKind) -> WorkRef {
        switch k {
        case .file: WorkRef(kind: .file, id: "nowhere.txt")
        case .diff, .item: WorkRef(kind: k, id: "ENG-999")
        case .commit: WorkRef(kind: .commit, id: "abcdef1234567")
        case .ask, .artifact, .resource, .memory, .release, .sprint: WorkRef(kind: k, id: "999")
        case .kb: WorkRef(kind: .kb, id: "Nowhere/Page")
        case .preview: WorkRef(kind: .preview, id: "nosuch")
        case .run, .message, .thread: WorkRef(kind: k, id: "no-such-id")
        case .agent: WorkRef(kind: .agent, id: "nobody")
        case .channel: WorkRef(kind: .channel, id: "nochan")
        case .fact: WorkRef(kind: .fact, id: "x")
        }
    }
}
