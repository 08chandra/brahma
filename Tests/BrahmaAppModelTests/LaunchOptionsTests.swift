import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite struct LaunchOptionsTests {
    @Test func parsesSmokeAndSnapshot() {
        let a = LaunchOptions.parse(["/x/Brahma", "--smoke-test", "--smoke-hold", "8", "--smoke-close-window"])
        #expect(a.smokeTest)
        #expect(a.smokeHold == 8)
        #expect(a.smokeCloseWindow)
        let b = LaunchOptions.parse(["/x", "--ui-snapshot", "/tmp/a.png", "--select", "channel:general"])
        #expect(b.snapshotPath == "/tmp/a.png")
        #expect(b.select == .channel(name: "general"))
        #expect(!b.smokeTest)
    }

    @Test func parsesEqualsFormSmokeHold() {
        let a = LaunchOptions.parse(["/x/Brahma", "--smoke-test", "--smoke-hold=14"])
        #expect(a.smokeTest)
        #expect(a.smokeHold == 14)
        #expect(a.smokeRelease == nil)
        let b = LaunchOptions.parse(["/x/Brahma", "--smoke-test", "--smoke-hold=90", "--smoke-release=/tmp/x/release-a"])
        #expect(b.smokeHold == 90)
        #expect(b.smokeRelease == "/tmp/x/release-a")
    }

    @Test func ignoresUnknownAndPsnArgs() {
        #expect(LaunchOptions.parse(["/x", "-psn_0_123", "-NSDocumentRevisionsDebugMode", "YES"]) == LaunchOptions())
    }

    @Test func selectTargets() {
        #expect(SelectTarget("mission") == .missionControl)
        #expect(SelectTarget("activity") == .activity)
        #expect(SelectTarget("agents") == .agents)
        #expect(SelectTarget("agent:CTO") == .agent(handle: "cto"))
        #expect(SelectTarget("channel:General") == .channel(name: "general"))
        #expect(SelectTarget("dm:CEO") == .dm(handle: "ceo"))
        #expect(SelectTarget("search:stripe hooks") == .search("stripe hooks"))
        #expect(SelectTarget("hire") == .sheet(.hire))
        #expect(SelectTarget("new-company") == .sheet(.newCompany))
        #expect(SelectTarget("bogus") == nil)
        #expect(SelectTarget("channel:") == nil)
    }

    @Test func applyResolvesChannelByName() async throws {
        let (store, paths) = try makeHome()
        try seedAcme(store, paths)
        let model = AppModel(store: store, paths: paths)
        await model.load()
        let general = try #require(model.snapshot.channels.first { $0.name == "general" })
        model.apply(.channel(name: "general"))
        #expect(model.sidebarSelection == .channel(id: general.id))
        model.apply(.channel(name: "nope"))
        #expect(model.sidebarSelection == .channel(id: general.id))
        #expect(model.errorMessage == "No channel #nope")
    }

    @Test func applyAgentAndSheet() async throws {
        let (store, paths) = try makeHome()
        let seeded = try seedAcme(store, paths)
        let model = AppModel(store: store, paths: paths)
        await model.load()
        model.apply(.agent(handle: "cto"))
        #expect(model.sidebarSelection == .agents)
        #expect(model.selectedAgentId == seeded.cto.id)
        model.apply(.sheet(.newCompany))
        #expect(model.presentedSheet == .newCompany)
    }
}
