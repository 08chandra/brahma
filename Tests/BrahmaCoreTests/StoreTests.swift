import Testing
import Foundation
import GRDB
@testable import BrahmaCore

@Test func walModeAndBusyTimeout() throws {
    let dir = try tempDir(); let s = try Store(path: dir.appending(path: "t.sqlite").path)
    #expect(try s.pragma("journal_mode") == "wal")
    #expect(try s.pragma("busy_timeout") == "5000")
}

@Test func createCompanyMakesWorkspaceAndDefaults() throws {
    let root = try tempDir(); let s = try Store.inMemory()
    let c = try s.createCompany(name: "Acme Labs", goal: "Build a todo app", workspacesRoot: root)
    #expect(c.slug == "acme-labs"); #expect(c.status == .running)
    #expect(c.usageMode == .low); #expect(c.priorityWeight == 1)
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "acme-labs").path))
    #expect(try s.company(id: c.id) == c)
    #expect(try s.companies().count == 1)
}

@Test func duplicateNamesGetDistinctSlugsAndWorkspaces() throws {
    let root = try tempDir(); let s = try Store.inMemory()
    let a = try s.createCompany(name: "Acme", goal: "g", workspacesRoot: root)
    let b = try s.createCompany(name: "Acme", goal: "g", workspacesRoot: root)
    #expect(a.slug == "acme"); #expect(b.slug == "acme-2")
    #expect(a.workspacePath != b.workspacePath)
    #expect(FileManager.default.fileExists(atPath: b.workspacePath))
}

@Test func emptySlugFallsBackToCompany() throws {
    let root = try tempDir(); let s = try Store.inMemory()
    for name in ["日本", "!!!"] {
        let c = try s.createCompany(name: name, goal: "g", workspacesRoot: root)
        #expect(c.slug.hasPrefix("company"))
        #expect(URL(fileURLWithPath: c.workspacePath).standardizedFileURL != root.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: c.workspacePath))
    }
    #expect(try s.companies().map(\.slug) == ["company", "company-2"])
}

@Test func failedWorkspaceCreationLeavesNoRow() throws {
    let root = try tempDir(); let s = try Store.inMemory()
    let blocker = root.appending(path: "file")
    try Data().write(to: blocker)
    #expect(throws: (any Error).self) { try s.createCompany(name: "X", goal: "g", workspacesRoot: blocker) }
    #expect(try s.companies().isEmpty)
}

@Test func updateCompanyPersists() throws {
    let s = try Store.inMemory()
    var c = try s.createCompany(name: "A", goal: "g", workspacesRoot: try tempDir())
    c.status = .paused; c.usageMode = .max; c.priorityWeight = 3
    try s.updateCompany(c)
    #expect(try s.company(id: c.id) == c)
}

@Test func hireStartsSleepingWithFreshSession() throws {
    let s = try Store.inMemory(); let c = try s.createCompany(name: "A", goal: "g", workspacesRoot: try tempDir())
    let a = try s.hire(companyId: c.id, name: "ceo", role: "ceo", model: "opus")
    #expect(a.state == .sleeping); #expect(a.sessionStarted == false); #expect(UUID(uuidString: a.sessionId) != nil)
    #expect(throws: StoreError.duplicateName) { try s.hire(companyId: c.id, name: "ceo", role: "cto", model: "opus") }
}

@Test func agentQueries() throws {
    let s = try Store.inMemory(); let root = try tempDir()
    let c1 = try s.createCompany(name: "One", goal: "g", workspacesRoot: root)
    let c2 = try s.createCompany(name: "Two", goal: "g", workspacesRoot: root)
    let a = try s.hire(companyId: c1.id, name: "ceo", role: "ceo", model: "opus")
    var b = try s.hire(companyId: c1.id, name: "dev", role: "dev", model: "sonnet")
    _ = try s.hire(companyId: c2.id, name: "ceo", role: "ceo", model: "opus")
    b.state = .ready; try s.save(b)
    #expect(try s.agent(id: a.id) == a)
    #expect(try s.agent(companyId: c1.id, name: "dev") == b)
    #expect(try s.agent(companyId: c1.id, name: "nope") == nil)
    #expect(try s.agents().count == 3)
    #expect(try s.agents(companyId: c1.id).count == 2)
    #expect(try s.agents(states: [.ready]).map(\.id) == [b.id])
    #expect(try s.agents(companyId: c2.id, states: [.ready]).isEmpty)
}

@Test func blockerRoundTripsThroughJSON() throws {
    let s = try Store.inMemory(); let c = try s.createCompany(name: "A", goal: "g", workspacesRoot: try tempDir())
    var a = try s.hire(companyId: c.id, name: "ceo", role: "ceo", model: "opus")
    let until = Date(timeIntervalSince1970: 1_800_000_000.5)
    let blockers: [Blocker] = [.agent("x"), .owner(reason: "need key"), .usageLimit(until: until),
                               .turnBudget(until: until), .retry(until: until, failures: 2)]
    for b in blockers {
        a.state = .blocked; a.blocker = b; a.requestedBlocker = b; try s.save(a)
        let r = try #require(try s.agent(id: a.id))
        #expect(r.blocker == b); #expect(r.requestedBlocker == b); #expect(r == a)
    }
    a.blocker = nil; a.requestedBlocker = nil; try s.save(a)
    #expect(try s.agent(id: a.id)?.blocker == nil)
}

@Test func pathsHonorEnvironment() {
    let p = BrahmaPaths.from(environment: ["BRAHMA_HOME": "/x", "BRAHMA_WORKSPACES": "/w"])
    #expect(p.home.path == "/x"); #expect(p.database.path == "/x/brahma.sqlite")
    #expect(p.workspaces.path == "/w"); #expect(p.runDir.path == "/x/run")
    let d = BrahmaPaths.from(environment: [:])
    #expect(d.home.path.hasSuffix("Library/Application Support/Brahma"))
    #expect(d.workspaces.path.hasSuffix("Brahma"))
}

@Test func createChannelRejectsReservedNames() throws {
    let store = try Store.inMemory()
    let c = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
    for bad in ["dm:a:b", "a b", "", "#", "x:y", "-x", String(repeating: "a", count: 65)] {
        #expect(throws: StoreError.invalidName, "\(bad)") { try store.createChannel(companyId: c.id, name: bad, members: []) }
    }
    #expect(try store.createChannel(companyId: c.id, name: "#Eng_1-x", members: []).name == "eng_1-x")
}

@Test func hireRejectsOwnerAndBadHandles() throws {
    let store = try Store.inMemory()
    let c = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
    for bad in ["owner", "OWNER", "a b", "", "@x", "x:y", "-x", String(repeating: "a", count: 33)] {
        #expect(throws: StoreError.invalidName, "\(bad)") { try store.hire(companyId: c.id, name: bad, role: "r", model: "m") }
    }
    #expect(try store.hire(companyId: c.id, name: "Eng-1", role: "r", model: "m").name == "eng-1")
}

@Test func activityEventFeedUsesCompanyIdIndex() throws {
    let s = try Store.inMemory()
    let plan: [String] = try s.writer.read { db in
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT * FROM activityEvent WHERE companyId = 'c' AND id > 5 ORDER BY id")
            .map { $0["detail"] as String? ?? "" }
    }
    #expect(plan.joined(separator: " ").contains("activityEvent_company_id"), "\(plan)")
}
