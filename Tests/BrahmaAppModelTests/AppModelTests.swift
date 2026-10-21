import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite struct AppModelTests {
    func world() throws -> (model: AppModel, store: Store, paths: BrahmaPaths, acme: Company, ceo: Agent, cto: Agent) {
        let (store, paths) = try makeHome()
        let (acme, ceo, cto, _) = try seedAcme(store, paths)
        return (AppModel(store: store, paths: paths), store, paths, acme, ceo, cto)
    }
    func second(_ paths: BrahmaPaths) throws -> Store { try Store(path: paths.database.path) }
    func addEvents(_ s: Store, _ c: Company, _ n: Int) throws {
        for i in 0..<n {
            try s.appendEvent(ActivityEvent(companyId: c.id, agentId: nil, turnId: nil, kind: .message, text: "e\(i)", createdAt: .now))
        }
    }

    @Test func loadSelectsFirstCompanyAndCountsStates() async throws {
        let w = try world()
        await w.model.load()
        #expect(w.model.loaded)
        #expect(w.model.snapshot.companies.count == 2)
        #expect(w.model.selectedCompanyId == w.acme.id)
        #expect(w.model.selectedCompany?.counts.line == "0 running · 1 ready · 1 blocked · 1 sleeping")
        #expect(w.model.selectedCompany?.waitingOnOwner == 1)
    }

    @Test func pollSeesCrossProcessWrites() async throws {
        let w = try world()
        await w.model.load()
        let other = try second(w.paths)
        _ = try MessageRouter(store: other).post(companyId: w.acme.id, channel: "general", from: .agent(w.ceo.id), text: "hello from mcp")
        await w.model.tick()
        #expect(w.model.activity.last?.text.contains("hello from mcp") == true)
        #expect(w.model.selectedCompany?.unread == 1)
    }

    @Test func snapshotRefreshesWithoutEventsWithin4Ticks() async throws {
        let w = try world()
        await w.model.load()
        try second(w.paths).updateCompany(id: w.acme.id) { $0.priorityWeight = 5 }
        for _ in 0..<4 { await w.model.tick() }
        #expect(w.model.selectedCompany?.company.priorityWeight == 5)
    }

    @Test func eventsCursorNeverDuplicates() async throws {
        let w = try world()
        await w.model.load()
        await w.model.tick(); await w.model.tick()
        let n = w.model.activity.count
        try addEvents(w.store, w.acme, 3)
        await w.model.tick()
        await w.model.tick()
        #expect(w.model.activity.count == n + 3)
    }

    @Test func activityCappedAt500() async throws {
        let w = try world()
        await w.model.load()
        try addEvents(w.store, w.acme, 520)
        await w.model.tick()
        #expect(w.model.activity.count == 500)
        #expect(w.model.activity.last?.id == (try w.store.maxEventId()))
    }

    @Test func otherCompanyEventsStayOutOfFeed() async throws {
        let w = try world()
        await w.model.load()
        let globex = try #require(try w.store.companies().first { $0.name == "Globex" })
        try addEvents(w.store, globex, 2)
        await w.model.tick()
        #expect(!w.model.activity.contains { $0.companyId == globex.id })
    }

    @Test func selectCompanyLoadsItsRecentActivity() async throws {
        let w = try world()
        await w.model.load()
        let globex = try #require(try w.store.companies().first { $0.name == "Globex" })
        try addEvents(w.store, globex, 3)
        w.model.select(.agents)
        await w.model.selectCompany(globex.id)
        #expect(w.model.activity.count == 3)
        #expect(w.model.sidebarSelection == .missionControl)
        #expect(w.model.selectedCompanyId == globex.id)
    }

    @Test func tickInterleavedWithSelectCompanyStaysConsistent() async throws {
        let w = try world()
        await w.model.load()
        let globex = try #require(try w.store.companies().first { $0.name == "Globex" })
        try addEvents(w.store, w.acme, 5)
        try addEvents(w.store, globex, 3)
        async let t: Void = w.model.tick()
        await w.model.selectCompany(globex.id)
        await t
        await w.model.tick()
        await w.model.tick()
        #expect(w.model.activity.count == 3)
        #expect(w.model.activity.allSatisfy { $0.companyId == globex.id })
        #expect(Set(w.model.activity.compactMap(\.id)).count == w.model.activity.count)
        #expect(w.model.selectedCompany?.id == globex.id)
        #expect(w.model.snapshot.agents.isEmpty)
    }

    @Test func createCompanySelectsIt() async throws {
        let w = try world()
        await w.model.load()
        let c = try await w.model.createCompany(CompanyForm(name: " New Co ", goal: "Ship"))
        #expect(c.name == "New Co")
        #expect(w.model.selectedCompanyId == c.id)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: w.paths.workspaces.appending(path: "new-co").path, isDirectory: &isDir) && isDir.boolValue)
    }

    @Test func createCompanyRejectsBlank() async throws {
        let w = try world()
        await w.model.load()
        await #expect(throws: FormError.invalid("Name is required")) {
            _ = try await w.model.createCompany(CompanyForm(name: " ", goal: "g"))
        }
        await #expect(throws: FormError.invalid("Goal is required")) {
            _ = try await w.model.createCompany(CompanyForm(name: "n", goal: " "))
        }
    }

    @Test func setUsageModeKeepsFreshFields() async throws {
        let w = try world()
        await w.model.load()
        try second(w.paths).updateCompany(id: w.acme.id) { $0.priorityWeight = 4 }
        await w.model.setUsageMode(.max)
        let c = try #require(try w.store.company(id: w.acme.id))
        #expect(c.usageMode == .max)
        #expect(c.priorityWeight == 4)
    }

    @Test func pauseAndResumeCompany() async throws {
        let w = try world()
        await w.model.load()
        await w.model.setCompanyRunning(false, companyId: w.acme.id)
        #expect(try w.store.company(id: w.acme.id)?.status == .paused)
        #expect(w.model.selectedCompany?.company.status == .paused)
        await w.model.setCompanyRunning(true, companyId: w.acme.id)
        #expect(w.model.selectedCompany?.company.status == .running)
    }

    @Test func sidebarSectionsGroupChannels() async throws {
        let w = try world()
        _ = try w.store.createChannel(companyId: w.acme.id, name: "architecture", members: [w.ceo.id])
        let router = MessageRouter(store: w.store)
        _ = try router.sendDM(companyId: w.acme.id, from: .agent(w.ceo.id), to: "owner", text: "hi")
        _ = try router.sendDM(companyId: w.acme.id, from: .agent(w.ceo.id), to: "cto", text: "yo")
        await w.model.load()
        let sb = w.model.sidebar
        #expect(sb.channels.map(\.title) == ["#general", "#architecture"])
        #expect(sb.directMessages == [SidebarRow(item: .dm(handle: "ceo"), title: "@ceo", unread: 1)])
        #expect(sb.agentConversations.map(\.title) == ["@ceo · @cto"])
        let dmChannel = try #require(try w.store.channel(companyId: w.acme.id, name: "dm:ceo:cto"))
        #expect(sb.agentConversations.first?.item == .channel(id: dmChannel.id))
    }

    @Test func persistentDBErrorAlertsOncePerStreak() async throws {
        struct Broken: Error {}
        let w = try world()
        w.model.report(Broken())
        let first = try #require(w.model.errorMessage)
        #expect(first.hasPrefix("Couldn't read the Brahma database"))
        w.model.errorMessage = nil  // the owner dismisses the alert
        w.model.report(Broken())    // the next 500 ms tick fails the same way
        #expect(w.model.errorMessage == nil)
        await w.model.tick()        // a successful read ends the streak
        #expect(w.model.errorMessage == nil)
        w.model.report(Broken())
        #expect(w.model.errorMessage == first)
    }
}
