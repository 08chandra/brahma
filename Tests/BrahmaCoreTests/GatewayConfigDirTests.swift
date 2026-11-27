import Testing
import Foundation
@testable import BrahmaCore

// Plan X1 Ruling 63 (X1-39): the gateway turn's config dir is checked before every gateway turn (`GatewayConfigDir.prepare`,
// which Task 14's launcher calls): anything but the CLI's own state gets it quarantined and a fresh one started with an alert;
// a link anywhere on its path refuses the turn, and the transcript capture reading it refuses a link at every component.

/// A resolved data home with one company and agent (`GoldenWorld` is the parity goldens' world).
private func world() throws -> GoldenWorld { try GoldenWorld() }

private final class Alerts: @unchecked Sendable {
    let lock = NSLock()
    var texts: [String] = []
    func record(_ text: String) { lock.withLock { texts.append(text) } }
    var all: [String] { lock.withLock { texts } }
}

private func contents(_ url: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() }

@Suite(.scratch) struct GatewayConfigDirTests {
    /// The first prepare makes an empty 0700 dir in the run area; the CLI's own state survives the next prepare untouched.
    @Test func freshDirAndCLIStateKept() throws {
        let w = try world()
        let alerts = Alerts()
        let first = try GatewayConfigDir.prepare(paths: w.paths, agentId: w.eng.id, alert: alerts.record)
        #expect(first.url.path == w.paths.runDir.appending(path: "gateway-config/\(w.eng.id)").path)
        #expect(first.quarantined == nil && first.needsFreshSession, "a dir just made holds no session")
        #expect(try contents(first.url).isEmpty)
        #expect((try FileManager.default.attributesOfItem(atPath: first.url.path)[.posixPermissions] as? Int) == 0o700)
        // What claude writes there itself.
        let fm = FileManager.default
        for d in ["projects/-x-ws", "todos", "statsig", "shell-snapshots"] {
            try fm.createDirectory(at: first.url.appending(path: d), withIntermediateDirectories: true)
        }
        for f in [".claude.json", ".claude.json.backup.1700000000", "history.jsonl", "projects/-x-ws/s.jsonl"] {
            try Data("{}".utf8).write(to: first.url.appending(path: f))
        }
        let again = try GatewayConfigDir.prepare(paths: w.paths, agentId: w.eng.id, alert: alerts.record)
        #expect(again == GatewayConfigDir.Prepared(url: first.url, needsFreshSession: false))
        // An existing dir (and run/, run/gateway-config/) left wider than 0700 is tightened.
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: first.url.path)  // exec-bit fixture: a directory's mode under test
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: first.url.deletingLastPathComponent().path)  // exec-bit fixture: a directory's mode under test
        _ = try GatewayConfigDir.prepare(paths: w.paths, agentId: w.eng.id, alert: alerts.record)
        for dir in [first.url, first.url.deletingLastPathComponent()] {
            #expect((try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int) == 0o700, "\(dir.path)")
        }
        #expect(try contents(again.url) == [".claude.json", ".claude.json.backup.1700000000", "history.jsonl", "projects", "shell-snapshots",
                                            "statsig", "todos"])
        #expect(alerts.all.isEmpty)
    }

    /// A planted settings file or hooks dir (or any other name the CLI does not write, or a link) gets the dir quarantined:
    /// the next prepare returns an empty dir, the turn must start a fresh session, and an alert is raised.
    @Test func plantedConfigQuarantined() throws {
        let w = try world()
        let fm = FileManager.default
        for planted in ["settings.json", "hooks", "settings.local.json", "agents", "commands", "plugins", "CLAUDE.md", ".mcp.json",
                        "skills", "output-styles", "link"] {
            let alerts = Alerts()
            let dir = try GatewayConfigDir.prepare(paths: w.paths, agentId: w.eng.id, alert: alerts.record).url
            try fm.createDirectory(at: dir.appending(path: "projects"), withIntermediateDirectories: true)
            let target = dir.appending(path: planted)
            switch planted {
            case "hooks", "agents", "commands", "plugins", "skills", "output-styles":
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try Data("x".utf8).write(to: target.appending(path: "x.json"))
            case "link":
                try fm.createSymbolicLink(atPath: dir.appending(path: "todos").path, withDestinationPath: w.userHome.path)
            default:
                try Data(#"{"hooks":{}}"#.utf8).write(to: target)
            }
            let prepared = try GatewayConfigDir.prepare(paths: w.paths, agentId: w.eng.id, agentName: "eng-1", alert: alerts.record)
            #expect(prepared.url == dir && prepared.needsFreshSession, "\(planted)")
            #expect(try contents(prepared.url).isEmpty, "\(planted): the next dir is empty")
            let moved = try #require(prepared.quarantined)
            #expect(moved.path.hasPrefix(w.paths.runDir.appending(path: "gateway-config-quarantine/").path))
            #expect(try contents(moved).contains(planted == "link" ? "todos" : planted), "\(planted): kept for the owner")
            #expect(alerts.all.count == 1, "\(planted)")
            #expect(alerts.all.first?.contains("@eng-1") == true && alerts.all.first?.contains(planted == "link" ? "todos (a link)" : planted) == true,
                    "\(alerts.all)")
            #expect(alerts.all.first?.contains("fresh session") == true)
        }
        // The store-backed form raises an engine alert for the agent's company.
        let dir = try GatewayConfigDir.prepare(paths: w.paths, agentId: w.eng.id) { _ in }.url
        try Data("{}".utf8).write(to: dir.appending(path: "settings.json"))
        let prepared = try GatewayConfigDir.prepare(paths: w.paths, agent: w.eng, store: w.store)
        #expect(prepared.needsFreshSession)
        let asks = try ModelGatewayTests.engineAlerts(w.store)
        #expect(asks.map(\.subjectId) == [EngineAlerts.askSubject(reason: GatewayConfigDir.alertReason)], "\(asks.map(\.title))")
    }

    /// A link as the dir, or at any component between the data home and it, refuses the turn: nothing is followed, moved or
    /// made through it. The transcript capture of a gateway turn refuses a link at every component too.
    @Test func linkedComponentsRefused() throws {
        let w = try world()
        let fm = FileManager.default
        let elsewhere = w.root.appending(path: "elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let dir = try GatewayConfigDir.directory(paths: w.paths, agentId: w.eng.id)
        let parent = dir.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        // The dir itself is a link.
        try fm.createSymbolicLink(atPath: dir.path, withDestinationPath: elsewhere.path)
        #expect(throws: GatewayConfigDir.Refusal.self) { try GatewayConfigDir.prepare(paths: w.paths, agentId: w.eng.id) { _ in } }
        try fm.removeItem(at: dir)
        // An intermediate component (`run/gateway-config`) is a link.
        try fm.removeItem(at: parent)
        try fm.createSymbolicLink(atPath: parent.path, withDestinationPath: elsewhere.path)
        #expect(throws: GatewayConfigDir.Refusal.self) { try GatewayConfigDir.prepare(paths: w.paths, agentId: w.eng.id) { _ in } }
        #expect(try contents(elsewhere).isEmpty, "nothing was made through the link")
        try fm.removeItem(at: parent)

        // Transcript capture: a session under a linked project folder, `projects/` or config dir is never read.
        let real = try GatewayConfigDir.prepare(paths: w.paths, agentId: w.eng.id) { _ in }.url
        let session = "00000000-0000-4000-8000-0000000000aa"
        let capture = TranscriptCapture(paths: w.paths, source: TranscriptSource(configDir: w.userHome)).reading(configDir: real.path)
        #expect(capture.refusesLinkedComponents && capture.source.configDir.path == real.path)
        let project = real.appending(path: "projects/-ws")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: project.appending(path: "\(session).jsonl"))
        #expect(capture.newestFile(sessionId: session) != nil, "the real layout is read")

        let outside = elsewhere.appending(path: "p")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: outside.appending(path: "\(session).jsonl"))
        try fm.removeItem(at: project)
        try fm.createSymbolicLink(atPath: project.path, withDestinationPath: outside.path)
        #expect(capture.newestFile(sessionId: session) == nil, "a linked project folder")
        try fm.removeItem(at: real.appending(path: "projects"))
        try fm.createSymbolicLink(atPath: real.appending(path: "projects").path, withDestinationPath: elsewhere.path)
        #expect(capture.newestFile(sessionId: session) == nil, "a linked projects/")
        try fm.removeItem(at: real.appending(path: "projects"))
        // A linked config dir (and a linked component above it).
        let linkedDir = w.root.appending(path: "cfg-link")
        try fm.createDirectory(at: elsewhere.appending(path: "projects/p"), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: elsewhere.appending(path: "projects/p/\(session).jsonl"))
        try fm.createSymbolicLink(atPath: linkedDir.path, withDestinationPath: elsewhere.path)
        let viaLink = TranscriptCapture(paths: w.paths, source: TranscriptSource(configDir: w.userHome)).reading(configDir: linkedDir.path)
        #expect(viaLink.newestFile(sessionId: session) == nil, "a linked config dir")
        let viaParent = TranscriptCapture(paths: w.paths, source: TranscriptSource(configDir: w.userHome))
            .reading(configDir: linkedDir.path + "/projects/..")
        #expect(viaParent.newestFile(sessionId: session) == nil)
        // `capture` raises an engine alert for a linked component (a tampering sign) and reads nothing.
        try fm.createDirectory(at: elsewhere.appending(path: "q"), withIntermediateDirectories: true)
        try fm.createDirectory(at: real.appending(path: "projects"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: real.appending(path: "projects/-ws").path, withDestinationPath: elsewhere.appending(path: "q").path)
        let turn = try w.store.startTurn(agentId: w.eng.id)
        let outcome = capture.capture(turn: turn, sessionId: session, store: w.store)
        guard case .failed(let why) = outcome else { Issue.record("\(outcome)"); return }
        #expect(why.contains("projects/-ws is a link"), "\(why)")
        let asks = try ModelGatewayTests.engineAlerts(w.store)
        #expect(asks.map(\.subjectId) == [EngineAlerts.askSubject(reason: EngineAlerts.gatewayConfigReason)], "\(asks.map(\.title))")

        // A subscription capture is unchanged: it follows the owner's own layout as before.
        #expect(!TranscriptCapture(paths: w.paths, source: TranscriptSource(configDir: linkedDir)).refusesLinkedComponents)
    }
}
