import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite(.scratch) struct LaunchOptionsTests {
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
        #expect(SelectTarget("backups") == .backups)
        #expect(SelectTarget("grants") == .grants && SelectTarget("digest") == .digest && SelectTarget("settings") == .companySettings)
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
    @Test func mapFlags() {
        let a = LaunchOptions.parse(["/x", "--map-demo", "--map-demo-agents=120", "--map-bench=20"])
        #expect(a.mapDemo)
        #expect(a.mapDemoAgents == 120)
        #expect(a.mapBench == 20)
        let d = LaunchOptions()
        #expect(!d.mapDemo && d.mapDemoAgents == 300 && d.mapBench == nil)
        #expect(LaunchOptions.parse(["/x", "--map-demo-agents=9000"]).mapDemoAgents == 500)
        #expect(LaunchOptions.parse(["/x", "--map-demo-agents=1"]).mapDemoAgents == 5)
        #expect(LaunchOptions.parse(["/x", "--map-demo-agents=lots"]).mapDemoAgents == 300)
        #expect(LaunchOptions.parse(["/x", "--map-bench=soon"]).mapBench == nil)
        #expect(LaunchOptions.parse(["/x", "--select", "map"]).select == .map)
        #expect(SelectTarget("map") == .map)
    }

    @Test func mapSkin() {
        #expect(LaunchOptions.parse(["/x", "--map-skin=office"]).mapSkin == .office)
        #expect(LaunchOptions.parse(["/x", "--map-skin=org"]).mapSkin == .org)
        #expect(LaunchOptions.parse(["/x", "--map-skin=hive"]).mapSkin == nil)
        #expect(LaunchOptions.parse(["/x", "--map-skin="]).mapSkin == nil)
        #expect(LaunchOptions.parse(["/x"]).mapSkin == nil)
        // `--map-skin` implies nothing else.
        var expected = LaunchOptions()
        expected.mapSkin = .office
        #expect(LaunchOptions.parse(["/x", "--map-skin=office"]) == expected)
    }

    /// `--ui-snapshot=<path>`: the form `scripts/map-demo.sh` can pass (it puts `--map-demo-agents=<n>` first, and AppKit
    /// mis-parses a `--flag value` pair after a bare `--flag=value` as a file to open).
    @Test func uiSnapshotEqualsForm() {
        #expect(LaunchOptions.parse(["/x", "--map-demo-agents=50", "--ui-snapshot=.superpowers/ui/a.png"]).snapshotPath
                == ".superpowers/ui/a.png")
        #expect(LaunchOptions.parse(["/x", "--ui-snapshot="]).snapshotPath == nil)
        #expect(LaunchOptions.parse(["/x", "--ui-snapshot=/tmp/b.png"]).isHarness)
    }

    @Test func isHarness() {
        #expect(!LaunchOptions().isHarness)
        #expect(!LaunchOptions.parse(["/x", "-psn_0_123", "--company", "Acme", "--select", "map"]).isHarness)
        #expect(!LaunchOptions.parse(["/x", "--map-skin=office"]).isHarness)
        #expect(LaunchOptions.parse(["/x", "--smoke-test"]).isHarness)
        #expect(LaunchOptions.parse(["/x", "--ui-snapshot", "/tmp/a.png"]).isHarness)
        #expect(LaunchOptions.parse(["/x", "--map-demo"]).isHarness)
        #expect(LaunchOptions.parse(["/x", "--map-bench=20"]).isHarness)
    }

    @Test func applyMapSelectsMissionControlAndEnsuresTheController() async throws {
        let (store, paths) = try makeHome()
        let seeded = try seedAcme(store, paths)
        let model = AppModel(store: store, paths: paths)
        await model.load()
        model.apply(.agents)
        model.apply(.map)
        #expect(model.sidebarSelection == .missionControl)
        #expect(model.mapController?.companyId == seeded.0.id)
    }
}
