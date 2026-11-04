import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Task 10, live (uses subscription quota): a turn that read a web page loses its high-risk tools. Run with:
/// BRAHMA_LIVE=1 swift test --filter LiveSafetyTests
@Suite(.scratch, .enabled(if: ProcessInfo.processInfo.environment["BRAHMA_LIVE"] == "1"))
struct LiveSafetyTests {
    @Test(.timeLimit(.minutes(5)))
    func taintedTurnLosesHighRiskTools() async throws {
        let exe = Bundle.module.bundleURL.deletingLastPathComponent().appending(path: "brahma")
        try #require(FileManager.default.isExecutableFile(atPath: exe.path), "build the brahma product first")
        let root = try tempDir()
        let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let store = try Store(path: paths.database.path)
        var company = try store.createCompany(name: "Taint", goal: "Read a page, then decide.", workspacesRoot: paths.workspaces)
        company.ownerReserve = -1
        try store.updateCompany(company)
        try store.updateSandbox(companyId: company.id, SandboxPatch(profile: .workspace), userHome: root.appending(path: "user"))
        let ceo = try store.hire(companyId: company.id, name: "ceo", role: "ceo", model: "haiku")
        let eng = try store.hire(companyId: company.id, name: "eng", role: "engineer", model: "haiku", managerId: ceo.id)
        let ask = try store.propose(companyId: company.id, by: .agent(eng.id), kind: .architecture, title: "Use SQLite", summary: "why")
        let before = try #require(try store.agent(id: ceo.id)).sessionId
        _ = try MessageRouter(store: store).sendDM(companyId: company.id, from: .owner, to: ceo.name, text: """
            First use WebFetch on https://docs.swift.org and note its title. Then call decide on \(ask.ref) with approve. Then stop.
            """)
        let orchestrator = Orchestrator(store: store, runner: ClaudeProcessRunner(maxTurnDuration: .seconds(180)), paths: paths,
                                        mcpExecutable: exe.path)
        try await orchestrator.start()
        await orchestrator.tick()
        try await orchestrator.waitUntilIdle(timeout: .seconds(240))
        let dump = try store.events(afterId: 0).map(\.text).joined(separator: "\n")
        #expect(try store.ask(id: ask.id)?.status == .pendingInternal, "events:\n\(dump)")
        #expect(dump.contains("read outside content"), "events:\n\(dump)")
        #expect(try store.agent(id: ceo.id)?.sessionId != before, "the next turn's session differs")
    }
}
