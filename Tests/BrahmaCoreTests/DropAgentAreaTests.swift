import Testing
import Foundation
@testable import BrahmaCore

/// Final-review I-1: a file the owner drops from where agents write (any company workspace, the workspaces root, the Brahma
/// data home) defaults to EXTERNAL whatever its type, size or quarantine flag, so dropping it is never a silent vouch. A
/// link or `..` in the dropped path does not dodge the check; an ordinary file from elsewhere keeps its usual default.
@Suite(.scratch) struct DropAgentAreaTests {
    typealias W = ResourceStoreTests.W
    private let fm = FileManager.default
    private let reason = "from a company workspace or Brahma's data folder (agents write there)"

    private func write(_ text: String, _ url: URL) throws -> URL {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func inspect(_ w: W, _ urls: URL...) throws -> DropPlan {
        try ResourceIntake.inspect(urls: urls, knownValues: [], agentAreas: try w.store.agentAreas(paths: w.paths))
    }

    @Test func workspaceAndDataHomeFilesDefaultTainted() throws {
        let w = try W()
        // A second company whose workspace is outside the workspaces root: every company's workspace counts.
        let elsewhere = try tempDir()
        let other = try w.store.createCompany(name: "Globex", goal: "g", workspacesRoot: elsewhere)
        let inWorkspace = try write("# design\nby eng-1\n", w.ws.appending(path: "docs/design.md"))
        let inOther = try write("notes\n", URL(fileURLWithPath: other.workspacePath).appending(path: "notes.txt"))
        let inHome = try write("export\n", w.paths.home.appending(path: "tmp/summary.md"))
        let inRoot = try write("loose\n", w.paths.workspaces.appending(path: "loose.md"))
        let outside = try write("# my own notes\n", w.drops.appending(path: "mine.md"))

        let plan = try inspect(w, inWorkspace, inOther, inHome, inRoot, outside)
        #expect(plan.refusals.isEmpty, "\(plan.refusals)")
        #expect(plan.items.map(\.displayName) == ["design.md", "notes.txt", "summary.md", "loose.md", "mine.md"])
        for item in plan.items.prefix(4) {
            #expect(item.tainted, "\(item.displayName)")
            #expect(item.provenance == .external("agent-workspace"), "\(item.displayName)")
            #expect(item.taintReason == reason, "\(item.displayName)")
        }
        // The ordinary file outside keeps the unchanged default: FROM YOU.
        let mine = try #require(plan.items.last)
        #expect(!mine.tainted); #expect(mine.provenance == .owner); #expect(mine.taintReason == nil)
        // The same file with no areas (the rule is the areas, not the file).
        let bare = try ResourceIntake.inspect(urls: [inWorkspace], knownValues: [], agentAreas: .none)
        #expect(bare.items.first?.tainted == false)

        // Stored as detected: tainted, never mirrored, announced without its name. An explicit vouch still clears it.
        let rows = try w.add(plan, ResourceDrop(context: .library))
        #expect(rows.prefix(4).allSatisfy { $0.tainted && $0.mirrorPath == nil && $0.taintReason == reason })
        #expect(!rows[4].tainted); #expect(rows[4].mirrorPath != nil)
        let vouched = try #require(try w.add(try inspect(w, inWorkspace), ResourceDrop(trust: .vouched)).first)
        #expect(!vouched.tainted); #expect(vouched.vouchedAt != nil)
    }

    @Test func anyTypeSizeOrQuarantineInWorkspaceIsTainted() throws {
        let w = try W()
        // A small code file and a PNG: FROM YOU when dropped from elsewhere, EXTERNAL from the workspace.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52])
        let code = try write("let x = 1\n", w.ws.appending(path: "src/x.swift"))
        let image = w.ws.appending(path: "shot.png")
        try png.write(to: image)
        let plan = try inspect(w, code, image)
        #expect(plan.items.count == 2, "\(plan.refusals)")
        #expect(plan.items.allSatisfy { $0.tainted && $0.provenance == .external("agent-workspace") })
        // The rule comes before every other one, whatever they say.
        for (ext, bytes, quarantined) in [("swift", Int64(10), false), ("pdf", 10, false), ("md", 1 << 20, true)] {
            let t = DropTrust.defaultProvenance(ext: ext, bytes: bytes, quarantined: quarantined, inAgentArea: true)
            #expect(t.tainted && t.provenance == .external("agent-workspace") && t.reason == reason, "\(ext)")
        }
    }

    @Test func linkOrDotDotCannotDodgeTheCheck() throws {
        let w = try W()
        let target = try write("# plan\n", w.ws.appending(path: "docs/plan.md"))
        // A link outside that points into the workspace: the parent is opened through it, and its identity is the workspace's.
        let elsewhere = try tempDir()
        let link = elsewhere.appending(path: "shortcut")
        try fm.createSymbolicLink(at: link, withDestinationURL: w.ws.appending(path: "docs"))
        // `..` that climbs out of an outside folder and back into the workspace.
        let climb = URL(fileURLWithPath: w.drops.path + "/../ws/" + URL(fileURLWithPath: w.company.workspacePath).lastPathComponent
                        + "/docs/plan.md")
        #expect(fm.fileExists(atPath: climb.path))
        let plan = try inspect(w, link.appending(path: "plan.md"), climb)
        #expect(plan.refusals.isEmpty, "\(plan.refusals)")
        #expect(plan.items.count == 2)
        #expect(plan.items.allSatisfy { $0.tainted && $0.taintReason == reason })
        _ = target

        // A folder from inside the data home: every file in it.
        let kit = w.paths.home.appending(path: "exports/kit", directoryHint: .isDirectory)
        _ = try write("a\n", kit.appending(path: "a.md")); _ = try write("b\n", kit.appending(path: "sub/b.md"))
        let folder = try inspect(w, kit)
        #expect(folder.items.map(\.relativePath) == ["kit/a.md", "kit/sub/b.md"])
        #expect(folder.items.allSatisfy { $0.tainted && $0.taintReason == reason })
        // Dropping an area folder itself (its parent is not one).
        let area = try tempDir().appending(path: "area", directoryHint: .isDirectory)
        _ = try write("c\n", area.appending(path: "c.md"))
        let whole = try ResourceIntake.inspect(urls: [area], knownValues: [], agentAreas: AgentAreas(urls: [area]))
        #expect(whole.items.map(\.relativePath) == ["area/c.md"]); #expect(whole.items.allSatisfy { $0.tainted })
        // An area given with `..` and a trailing slash is the same directory.
        let spelled = URL(fileURLWithPath: area.path + "/../area/")
        #expect(try ResourceIntake.inspect(urls: [area.appending(path: "c.md")], knownValues: [],
                                           agentAreas: AgentAreas(urls: [spelled])).items.first?.tainted == true)
        // An outside folder holding a link into the workspace: the link is skipped, never followed; its own files are FROM YOU.
        let mixed = w.drops.appending(path: "mixed", directoryHint: .isDirectory)
        _ = try write("mine\n", mixed.appending(path: "mine.md"))
        try fm.createSymbolicLink(at: mixed.appending(path: "ws"), withDestinationURL: w.ws)
        let m = try inspect(w, mixed)
        #expect(m.items.map(\.relativePath) == ["mixed/mine.md"]); #expect(m.items.allSatisfy { !$0.tainted })
        #expect(m.skipped == ["mixed/ws"])
    }

    /// The owner CLI's `resource add` uses the data home's areas: a workspace file is added EXTERNAL; `--vouch` overrides.
    @Test func cliAddFromWorkspaceIsExternal() throws {
        let owner = try OwnerTestHome()
        let paths = ownerPaths(owner.url)
        let workspace: URL
        do {
            let store = try Store(path: paths.database.path)
            let c = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
            workspace = URL(fileURLWithPath: c.workspacePath, isDirectory: true)
            try store.close()
        }
        let file = try write("# eng-1's design\n", workspace.appending(path: "design.md"))
        let outside = try write("# mine\n", try tempDir().appending(path: "mine.md"))
        let add = try runBrahma(["resource", "Acme", "add", file.path], home: owner.url)
        #expect(add.status == 0, "\(add.stderr)")
        #expect(add.stdout.contains("F-1") && add.stdout.contains("EXTERNAL (\(reason))"), "\(add.stdout)")
        let mine = try runBrahma(["resource", "Acme", "add", outside.path], home: owner.url)
        #expect(mine.status == 0, "\(mine.stderr)"); #expect(mine.stdout.contains("F-2") && mine.stdout.contains("FROM YOU"), "\(mine.stdout)")
        let vouched = try runBrahma(["resource", "Acme", "add", file.path, "--vouch"], home: owner.url)
        #expect(vouched.status == 0, "\(vouched.stderr)"); #expect(vouched.stdout.contains("FROM YOU"), "\(vouched.stdout)")
    }
}
