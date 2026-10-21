import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite struct AppModelEngineTests {
    @Test func tickRetriesTakeover() async throws {
        let (store, paths) = try makeHome()
        let tools = Result<EngineTools, EngineSetupError>.success(EngineTools(claudePath: "claude", mcpExecutable: "/tmp/brahma"))
        let h1 = EngineHost(paths: paths, store: store, makeRunner: { _ in StubRunner(mode: .succeed) }, tickInterval: .milliseconds(10),
                          probe: { _ in DoctorReport(cliVersion: "2.1.306", items: [], checkedAt: Date()) })
        let h2 = EngineHost(paths: paths, store: store, makeRunner: { _ in StubRunner(mode: .succeed) }, tickInterval: .milliseconds(10),
                          probe: { _ in DoctorReport(cliVersion: "2.1.306", items: [], checkedAt: Date()) })
        let model = AppModel(store: store, paths: paths)
        await h1.start(tools: tools)
        await h2.start(tools: tools)
        model.engine = h2
        #expect(h2.status == .external)
        await h1.stop()
        for _ in 0..<10 { await model.tick() }
        #expect(h2.status == .embedded)
        await h2.stop()
    }
}
