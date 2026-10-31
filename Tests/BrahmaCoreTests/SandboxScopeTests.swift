import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// A company on a file-backed store whose data home, workspaces root and "owner's home" all sit in one resolved temp dir.
private struct SandboxWorld {
    let root: URL
    let userHome: URL
    let paths: BrahmaPaths
    let store: Store
    var company: Company
    let eng: Agent
    let item: WorkItem
    let layout: SandboxLayout
    let userTemp: URL

    init(ensure: Bool = true) throws {
        root = URL(fileURLWithPath: try SandboxWorld.real(try tempDir()), isDirectory: false)
        userHome = root.appending(path: "user")
        paths = BrahmaPaths(home: root.appending(path: "data"), workspaces: root.appending(path: "wss"))
        userTemp = root.appending(path: "T")
        for dir in [userHome, paths.home, paths.workspaces, userTemp] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        store = try Store(path: paths.database.path)
        company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
        eng = try store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
        item = try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "Thing", ownerId: eng.id, status: .ready), now: Date())
        layout = SandboxLayout(paths: paths, company: company, agentHandle: "eng-1")
        if ensure { try layout.ensure() }
    }

    static func real(_ url: URL) throws -> String {
        guard let r = realpath(url.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(r) }
        return String(cString: r)
    }

    var ws: URL { URL(fileURLWithPath: company.workspacePath, isDirectory: false) }
    static func exists(_ path: String) -> Bool { var st = stat(); return lstat(path, &st) == 0 }
    var key: String { item.key }
    func p(_ relative: String) -> String { ws.appending(path: relative).path }

    func scope(_ kind: TurnKind, item: WorkItem?? = .none, company: Company? = nil, layout: SandboxLayout? = nil,
               paths: BrahmaPaths? = nil, other: [URL] = [], backup: [URL] = [], grants: GrantInputs = GrantInputs(),
               temp: URL? = nil) throws -> SandboxScope {
        let theItem: WorkItem? = item ?? self.item
        return try SandboxScope.forTurn(layout: layout ?? self.layout, paths: paths ?? self.paths, otherWorkspaces: other,
                                        backupTargets: backup, kind: kind, item: theItem, company: company ?? self.company,
                                        grants: grants, darwinUserTemp: temp ?? userTemp, userHome: userHome)
    }
}

private extension Array where Element == URL {
    var paths: [String] { map(\.path) }
}

private func expectSandboxError(_ expected: SandboxError, _ body: () throws -> Void) {
    do { try body(); Issue.record("expected \(expected), nothing was thrown") } catch let e as SandboxError {
        #expect(e == expected)
    } catch { Issue.record("expected \(expected), got \(error)") }
}

private func expectAnySandboxError(_ body: () throws -> Void, _ match: (SandboxError) -> Bool) {
    do { try body(); Issue.record("expected a SandboxError, nothing was thrown") } catch let e as SandboxError {
        #expect(match(e), "unexpected \(e)")
    } catch { Issue.record("expected a SandboxError, got \(error)") }
}

@Suite(.scratch) struct SandboxScopeTests {
    // MARK: Turn scopes

    @Test func itemTurnScopes() throws {
        let w = try SandboxWorld()
        let s = try w.scope(.work)
        let k = w.key
        #expect(s.cwd.path == w.p(".brahma/wt/\(k)"))
        #expect(s.cwd.resolvedForSandbox.path == GitWorkspace(root: w.ws).worktreePath(key: k).resolvedForSandbox.path)
        #expect(s.writable.paths == [
            w.p(".brahma/home/eng-1"), w.p(".brahma/labs/eng-1"), w.p(".brahma/home/eng-1/cache"), w.p(".git/objects"),
            w.p(".git/worktrees/\(k)"), w.p(".git/refs/heads/item/\(k)"), w.p(".git/refs/heads/item/\(k).lock"),
            w.p(".git/logs/refs/heads/item/\(k)"), w.p(".brahma/progress/\(k).md"), w.p(".brahma/notes/agents/eng-1.md"),
        ])
        #expect(!s.writable.paths.contains(w.p(".git/refs/heads/item")))
        #expect(!s.writable.paths.contains(w.p(".git/logs/refs/heads/item")))
        #expect(s.denyWrite.paths.contains(w.p(".brahma/checks")))
        #expect(s.denyWrite.paths.contains(w.p(".brahma/wt-check")))
        #expect(s.toolchainTempWrite?.path == w.userTemp.path)
        try s.validate()
    }

    @Test func noticeTurnWithItemUsesItemScope() throws {
        let w = try SandboxWorld()
        #expect(try w.scope(.notice) == (try w.scope(.work)))
    }

    @Test func itemlessTurnRunsInLab() throws {
        let w = try SandboxWorld()
        for kind in [TurnKind.work, .notice] {
            let s = try w.scope(kind, item: .some(nil))
            #expect(s.cwd.path == w.p(".brahma/labs/eng-1"))
            #expect(s.writable.paths == [w.p(".brahma/home/eng-1"), w.p(".brahma/labs/eng-1"), w.p(".brahma/home/eng-1/cache"),
                                         w.p(".brahma/notes/agents/eng-1.md")])
            #expect(!s.writable.paths.contains { $0.contains("/.git/") || $0.hasSuffix("/.git") })
        }
    }

    @Test func reviewTurnIsReadOnlyOnWorktree() throws {
        let w = try SandboxWorld()
        let s = try w.scope(.review)
        #expect(s.cwd.path == w.p(".brahma/labs/eng-1"))
        #expect(s.writable.paths == [w.p(".brahma/home/eng-1"), w.p(".brahma/labs/eng-1")])
        #expect(s.readOnlyDirs.paths.contains(w.p(".brahma/wt/\(w.key)")))
        #expect(!s.writable.paths.contains { $0.hasPrefix(w.p(".brahma/wt")) })
    }

    @Test func auditTurnMountsNoWorktree() throws {
        let w = try SandboxWorld()
        let s = try w.scope(.audit)
        #expect(s.cwd.path == w.p(".brahma/labs/eng-1"))
        #expect(s.writable.paths == [w.p(".brahma/home/eng-1"), w.p(".brahma/labs/eng-1")])
        #expect(!s.readOnlyDirs.paths.contains { $0.hasPrefix(w.p(".brahma/wt")) })
    }

    @Test func planTurnScope() throws {
        let w = try SandboxWorld()
        let s = try w.scope(.plan)
        #expect(s.cwd.path == w.p(".brahma/plans/\(w.key)"))
        #expect(s.cwd == w.layout.plansDir(w.key).resolvedForSandbox)
        #expect(s.readOnlyDirs.paths.contains(w.p(".brahma/wt/\(w.key)")))
        #expect(s.writable.paths == [w.p(".brahma/home/eng-1"), w.p(".brahma/plans/\(w.key)")])
        // The plan directory matches 3a's (`Orchestrator.planDirectory`).
        let built = try #require(Orchestrator.planDirectory(workspace: w.ws, key: w.key))
        #expect(built.resolvedForSandbox == s.cwd)
    }

    @Test func planTurnWithoutItemGetsTheNarrowestScope() throws {
        let w = try SandboxWorld()
        let s = try w.scope(.plan, item: .some(nil))
        #expect(s.cwd.path == w.p(".brahma/labs/eng-1"))
        #expect(s.writable.paths == [w.p(".brahma/home/eng-1"), w.p(".brahma/labs/eng-1")])
    }

    @Test func projectConfigPathsNotWritable() throws {
        let w = try SandboxWorld()
        for kind in TurnKind.allCases {
            let s = try w.scope(kind)
            let lab = w.p(".brahma/labs/eng-1")
            for path in [s.cwd.path + "/.claude", s.cwd.path + "/.mcp.json", lab + "/.claude", lab + "/.mcp.json"] {
                #expect(s.denyWrite.paths.contains(path), "\(kind) lacks \(path)")
            }
        }
    }

    // MARK: Protected paths and validation

    @Test func protectedDefaultsInOrder() {
        let home = URL(fileURLWithPath: "/Users/o", isDirectory: false)
        let names = ProtectedPaths.defaults(userHome: home).map { String($0.path.dropFirst("/Users/o/".count)) }
        #expect(names.prefix(3) == [".ssh", ".aws", ".config/gh"])
        #expect(names.contains("Library/Keychains"))
        #expect(names.contains("Library/Application Support/1Password"))
        #expect(names.last == "Library/Application Support/Code")
        #expect(names.count == 20 + 7 + 9)
    }

    @Test func overlappingReadPathRefused() throws {
        var w = try SandboxWorld()
        for path in ["~", "~/Library", "/Volumes"] {
            w.company.toolchainReadPaths = [path]
            expectAnySandboxError({ _ = try w.scope(.work) }) { if case .overlapsProtected = $0 { true } else { false } }
        }
        let nvm = w.userHome.appending(path: ".nvm")
        try FileManager.default.createDirectory(at: nvm, withIntermediateDirectories: true)
        w.company.toolchainReadPaths = ["~/.nvm"]
        let s = try w.scope(.work)
        #expect(s.readable.paths.contains(nvm.path))
        // A read path inside a protected one, and one that contains the data home, are refused too.
        for path in ["~/.ssh/keys", w.root.path] {
            w.company.toolchainReadPaths = [path]
            expectAnySandboxError({ _ = try w.scope(.work) }) { if case .overlapsProtected = $0 { true } else { false } }
        }
    }

    @Test func readPathIntoDotBrahmaRefused() throws {
        var w = try SandboxWorld()
        try SandboxLayout(paths: w.paths, company: w.company, agentHandle: "eng-2").ensure()
        for path in [".brahma/labs/eng-2", ".brahma/notes", ".brahma"] {
            w.company.toolchainReadPaths = [w.p(path)]
            expectAnySandboxError({ _ = try w.scope(.work) }) { if case .overlapsProtected = $0 { true } else { false } }
            w.company.toolchainReadPaths = []
            let grant = URL(fileURLWithPath: w.p(path), isDirectory: false)
            expectAnySandboxError({ _ = try w.scope(.work, grants: GrantInputs(readPaths: [grant])) }) {
                if case .overlapsProtected = $0 { true } else { false }
            }
        }
        #expect(throws: SandboxError.self) {
            try w.store.updateSandbox(companyId: w.company.id, SandboxPatch(toolchainReadPaths: [w.p(".brahma/home/eng-2")]))
        }
    }

    @Test func relativeReadPathRefused() throws {
        var w = try SandboxWorld()
        for path in ["relative/dir", "~other/x", ""] {
            w.company.toolchainReadPaths = [path]
            expectAnySandboxError({ _ = try w.scope(.work) }) { if case .invalidPath = $0 { true } else { false } }
        }
    }

    @Test func backupTargetIsProtected() throws {
        var w = try SandboxWorld()
        let backup = URL(fileURLWithPath: "/Volumes/Backup/Brahma", isDirectory: false)
        let s = try w.scope(.work, backup: [backup])
        #expect(s.denyRead.paths.contains(backup.path))
        #expect(s.protected.paths.contains(backup.path))
        w.company.toolchainReadPaths = ["/Volumes/Backup/Brahma/toolchain"]
        expectAnySandboxError({ _ = try w.scope(.work, backup: [backup]) }) {
            if case .overlapsProtected(_, let p) = $0 { p == backup.path || p == "/Volumes" } else { false }
        }
    }

    @Test func dataHomeInsideWorkspaceRefused() throws {
        let w = try SandboxWorld()
        let inside = BrahmaPaths(home: w.ws.appending(path: "data"), workspaces: w.paths.workspaces)
        expectSandboxError(.dataHomeInsideWorkspace(w.ws.appending(path: "data").path)) { _ = try w.scope(.work, paths: inside) }
    }

    @Test func otherCompaniesDenied() throws {
        let w = try SandboxWorld()
        let b = try w.store.createCompany(name: "Beta", goal: "g", workspacesRoot: w.paths.workspaces)
        let other = URL(fileURLWithPath: b.workspacePath, isDirectory: false)
        let s = try w.scope(.work, other: [other])
        #expect(s.denyRead.paths.contains(other.path))
        #expect(s.protected.paths.contains(other.path))
        #expect(!s.readable.paths.contains { $0 == other.path || $0.hasPrefix(other.path + "/") })
        #expect(!s.writable.paths.contains { $0.hasPrefix(other.path + "/") })
        // A read path into the other company is refused.
        var c = w.company
        c.toolchainReadPaths = [other.appending(path: "src").path]
        expectAnySandboxError({ _ = try w.scope(.work, company: c, other: [other]) }) {
            if case .overlapsProtected = $0 { true } else { false }
        }
    }

    @Test func symlinkedPathsAreResolved() throws {
        let w = try SandboxWorld()
        let link = w.root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: w.paths.workspaces)
        var viaLink = w.company
        viaLink.workspacePath = link.appending(path: w.company.slug).path
        let layout = SandboxLayout(paths: w.paths, company: viaLink, agentHandle: "eng-1")
        // The Darwin temp dir behind a link too (not `/tmp` itself: it holds Claude's shared temp dirs, unreadable to turns).
        let tempLink = w.root.appending(path: "tlink")
        try FileManager.default.createSymbolicLink(at: tempLink, withDestinationURL: w.userTemp)
        let s = try w.scope(.work, company: viaLink, layout: layout, temp: tempLink)
        #expect(s.cwd.path == w.p(".brahma/wt/\(w.key)"))
        let all = [s.cwd] + s.writable + s.readable + s.readOnlyDirs + s.denyRead + s.denyWrite + s.protected
        #expect(!all.contains { $0.path.hasPrefix(link.path) })
        #expect(s.toolchainTempWrite?.path == w.userTemp.resolvedForSandbox.path)
        #expect(URL(fileURLWithPath: "/tmp/x/y", isDirectory: false).resolvedForSandbox.path == "/private/tmp/x/y")
    }

    @Test func unsafePathCharactersRefused() throws {
        let w = try SandboxWorld()
        for bad in ["it's", "a\"b", "line\nbreak"] {
            var c = w.company
            c.workspacePath = w.paths.workspaces.appending(path: bad).path
            let layout = SandboxLayout(paths: w.paths, company: c, agentHandle: "eng-1")
            expectAnySandboxError({ _ = try w.scope(.work, company: c, layout: layout) }) {
                if case .unsafePathCharacter = $0 { true } else { false }
            }
        }
        var c = w.company
        c.toolchainReadPaths = ["/opt/it's"]
        expectAnySandboxError({ _ = try w.scope(.work, company: c) }) { if case .unsafePathCharacter = $0 { true } else { false } }
        var scope = try w.scope(.work)
        scope.readable.append(URL(fileURLWithPath: "/opt/nul\u{0}x", isDirectory: false))
        expectAnySandboxError({ try scope.validate() }) { if case .unsafePathCharacter = $0 { true } else { false } }
    }

    @Test func writableOutsideCompanyRefused() throws {
        let w = try SandboxWorld()
        var scope = try w.scope(.work)
        scope.writable.append(w.root.appending(path: "elsewhere"))
        expectSandboxError(.writableOutsideCompany(path: w.root.appending(path: "elsewhere").path)) { try scope.validate() }
        // The xcrun temp is the one exemption.
        var ok = try w.scope(.work)
        ok.toolchainTempWrite = w.root.appending(path: "T")
        try ok.validate()
    }

    @Test func handleMustBeASafePathComponent() throws {
        let w = try SandboxWorld()
        for handle in ["../x", "a/b", "", "Eng", "it's", "a\\b"] {
            let layout = SandboxLayout(paths: w.paths, company: w.company, agentHandle: handle)
            expectSandboxError(.invalidHandle(handle)) { _ = try w.scope(.work, layout: layout) }
            expectSandboxError(.invalidHandle(handle)) { try layout.ensure() }
        }
        // Agent notes live in `notes/agents/`, so handles that name a team's notes file are fine now.
        for handle in ["company", "team-1", "core"] {
            let layout = SandboxLayout(paths: w.paths, company: w.company, agentHandle: handle)
            try layout.ensure()
            let s = try w.scope(.work, layout: layout)
            #expect(s.writable.paths.contains(w.p(".brahma/notes/agents/\(handle).md")))
            #expect(!s.writable.paths.contains(w.p(".brahma/notes/\(handle).md")))
        }
    }

    @Test func teamNotesNeverWritable() throws {
        let w = try SandboxWorld()
        _ = try NotesFile.append(workspace: w.ws, team: "team-1", heading: "retro", lines: ["x"])
        _ = try NotesFile.append(workspace: w.ws, team: "eng-1", heading: "retro", lines: ["x"])
        for kind in TurnKind.allCases {
            let s = try w.scope(kind)
            for team in [".brahma/notes/team-1.md", ".brahma/notes/eng-1.md"] {
                #expect(s.denyWrite.paths.contains(w.p(team)), "\(kind) \(team)")
                #expect(!s.writable.paths.contains(w.p(team)))
            }
            #expect(!s.writable.paths.contains(w.p(".brahma/notes")) && !s.writable.paths.contains(w.p(".brahma/notes/agents")))
        }
    }

    // MARK: Agent-planted links (fix round 1, C1)

    private func expectLinked(_ body: () throws -> Void) {
        expectAnySandboxError(body) { if case .linkedPath = $0 { true } else { false } }
    }

    private func link(_ w: SandboxWorld, _ relative: String, to target: String) throws {
        let path = w.p(relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if SandboxWorld.exists(path) { try FileManager.default.removeItem(atPath: path) }
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
    }

    @Test func progressFileLinkedToAFutureItemRefRefused() throws {
        let w = try SandboxWorld()
        try link(w, ".brahma/progress/\(w.key).md", to: "../../.git/refs/heads/item/FUTURE-9")
        expectLinked { _ = try w.scope(.work) }
    }

    @Test func progressFileLinkedToTeamNotesRefused() throws {
        let w = try SandboxWorld()
        try link(w, ".brahma/progress/\(w.key).md", to: w.p(".brahma/notes/team-1.md"))
        expectLinked { _ = try w.scope(.work) }
    }

    /// A link at an intermediate component, not the leaf (1a re-review): `.brahma/progress` itself pointing into the item refs,
    /// `.brahma/labs` pointing elsewhere. The walk names the linked component.
    @Test func linkAtAnIntermediateComponentRefused() throws {
        let w = try SandboxWorld()
        let progress = w.p(".brahma/progress")
        try? FileManager.default.removeItem(atPath: progress)
        try FileManager.default.createSymbolicLink(atPath: progress, withDestinationPath: w.p(".git/refs/heads/item"))
        expectSandboxError(.linkedPath(progress)) { _ = try w.scope(.work) }
        // The itemless scope has no progress file: it is not refused for it.
        _ = try w.scope(.work, item: .some(nil))

        let v = try SandboxWorld()
        let labs = v.p(".brahma/labs")
        let elsewhere = try tempDir()
        try FileManager.default.moveItem(atPath: labs, toPath: elsewhere.appending(path: "labs").path)
        try FileManager.default.createSymbolicLink(atPath: labs, withDestinationPath: elsewhere.appending(path: "labs").path)
        for kind in TurnKind.allCases {
            expectSandboxError(.linkedPath(labs)) { _ = try v.scope(kind) }
        }
    }

    @Test func ownItemRefAsLinkRefused() throws {
        let w = try SandboxWorld()
        try link(w, ".git/refs/heads/item/\(w.key)", to: "../main")
        expectLinked { _ = try w.scope(.work) }
        let v = try SandboxWorld()
        try link(v, ".git/refs/heads/item/\(v.key).lock", to: v.p(".git/refs/heads/main"))
        expectLinked { _ = try v.scope(.work) }
        let u = try SandboxWorld()
        try link(u, ".git/logs/refs/heads/item/\(u.key)", to: u.p(".git/logs/HEAD"))
        expectLinked { _ = try u.scope(.work) }
    }

    @Test func adminDirAsLinkRefused() throws {
        let w = try SandboxWorld()
        try FileManager.default.createDirectory(atPath: w.p(".git/worktrees/FUTURE-9"), withIntermediateDirectories: true)
        try link(w, ".git/worktrees/\(w.key)", to: w.p(".git/worktrees/FUTURE-9"))
        expectLinked { _ = try w.scope(.work) }
    }

    @Test func worktreeCwdAsLinkRefused() throws {
        let w = try SandboxWorld()
        try SandboxLayout(paths: w.paths, company: w.company, agentHandle: "eng-2").ensure()
        try link(w, ".brahma/wt/\(w.key)", to: w.p(".brahma/labs/eng-2"))
        expectLinked { _ = try w.scope(.work) }
        // A review mounts the same worktree read-only: refused too.
        expectLinked { _ = try w.scope(.review) }
    }

    @Test func plansCwdAsLinkRefused() throws {
        let w = try SandboxWorld()
        try link(w, ".brahma/plans/\(w.key)", to: w.p(".brahma/plans/FUTURE-9"))
        expectLinked { _ = try w.scope(.plan) }
    }

    @Test func labHomeCacheAndNotesAsLinksRefused() throws {
        for (relative, kinds) in [(".brahma/labs/eng-1", TurnKind.allCases), (".brahma/home/eng-1", TurnKind.allCases),
                                  (".brahma/home/eng-1/cache", [TurnKind.work, .notice]),
                                  (".brahma/notes/agents/eng-1.md", [TurnKind.work, .notice])] {
            let w = try SandboxWorld(ensure: false)
            try SandboxLayout(paths: w.paths, company: w.company, agentHandle: "eng-2").ensure()
            if relative.hasSuffix("/cache") {
                try FileManager.default.createDirectory(atPath: w.p(".brahma/home/eng-1"), withIntermediateDirectories: true)
            }
            try link(w, relative, to: w.p(".brahma/labs/eng-2"))
            for kind in kinds {
                expectLinked { _ = try w.scope(kind, item: .some(nil)) }
                expectLinked { _ = try w.scope(kind) }
            }
        }
    }

    @Test func shellPrefixLinkRefused() throws {
        let w = try SandboxWorld()
        try link(w, ".brahma/bin/shell-eng-1.sh", to: w.p(".brahma/labs/eng-2"))
        expectLinked { _ = try w.scope(.work) }
    }

    @Test func linkedAllowlistedChildIsNotReadable() throws {
        let w = try SandboxWorld()
        try SandboxLayout(paths: w.paths, company: w.company, agentHandle: "eng-2").ensure()
        try link(w, ".brahma/kb", to: w.p(".brahma/labs/eng-2"))
        try FileManager.default.createDirectory(atPath: w.p(".brahma/resources"), withIntermediateDirectories: true)
        try link(w, ".brahma/resources/company", to: w.p(".brahma/home/eng-2"))
        let s = try w.scope(.work)
        let shown = s.readable.paths + s.readOnlyDirs.paths
        #expect(!shown.contains { $0.hasPrefix(w.p(".brahma/labs/eng-2")) || $0.hasPrefix(w.p(".brahma/home/eng-2")) })
        #expect(!shown.contains(w.p(".brahma/kb")) && !shown.contains(w.p(".brahma/resources/company")))
    }

    // MARK: Unsafe names and deny forms (fix round 1, M1–M3)

    @Test func unsafeTopLevelNameIsSkippedNotFatal() throws {
        let w = try SandboxWorld()
        for name in ["it's", "tab\tname", "back\\slash"] {
            FileManager.default.createFile(atPath: w.p(name), contents: Data())
        }
        try FileManager.default.createDirectory(atPath: w.p("docs"), withIntermediateDirectories: true)
        for kind in TurnKind.allCases {
            let s = try w.scope(kind)
            #expect(s.readable.paths.contains(w.p("docs")))
            #expect(!s.readable.paths.contains { $0.contains("it's") || $0.contains("\t") || $0.contains("\\") })
            #expect(Set(s.skippedUnsafe) == Set(["it's", "tab\tname", "back\\slash"].map(w.p)), "\(kind)")
        }
    }

    @Test func unsafeSiblingNameDeniesTheParent() throws {
        let w = try SandboxWorld()
        try FileManager.default.createDirectory(atPath: w.p(".brahma/plans/x'y"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: w.p(".brahma/wt/a\"b"), withIntermediateDirectories: true)
        // No carve-out in `plans` or `wt` on a review turn: the parent is denied whole, the turn runs.
        let review = try w.scope(.review)
        #expect(review.denyWrite.paths.contains(w.p(".brahma/plans")))
        #expect(review.denyWrite.paths.contains(w.p(".brahma/wt")))
        #expect(!review.denyWrite.paths.contains { $0.contains("x'y") || $0.contains("a\"b") })
        // A turn whose own carve-out shares that parent fails alone.
        expectAnySandboxError({ _ = try w.scope(.plan) }) { if case .unsafePathCharacter = $0 { true } else { false } }
        expectAnySandboxError({ _ = try w.scope(.work) }) { if case .unsafePathCharacter = $0 { true } else { false } }
        _ = try w.scope(.work, item: .some(nil))
    }

    @Test func backslashAndControlCharactersRefused() throws {
        let w = try SandboxWorld()
        for bad in ["back\\slash", "tab\there", "esc\u{1B}x", "del\u{7F}x", "cr\rx"] {
            var c = w.company
            c.workspacePath = w.paths.workspaces.appending(path: bad).path
            let layout = SandboxLayout(paths: w.paths, company: c, agentHandle: "eng-1")
            expectAnySandboxError({ _ = try w.scope(.work, company: c, layout: layout) }) {
                if case .unsafePathCharacter = $0 { true } else { false }
            }
            c = w.company
            c.toolchainReadPaths = ["/opt/\(bad)"]
            expectAnySandboxError({ _ = try w.scope(.work, company: c) }) { if case .unsafePathCharacter = $0 { true } else { false } }
        }
    }

    @Test func linkedDenyEntryIsDeniedInBothForms() throws {
        let w = try SandboxWorld()
        let wt = w.p(".brahma/wt/\(w.key)")
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        let target = w.root.appending(path: "elsewhere-claude").path
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: wt + "/.claude", withDestinationPath: target)
        let s = try w.scope(.work)
        #expect(s.denyWrite.paths.contains(wt + "/.claude"))
        #expect(s.denyWrite.paths.contains(target))
    }

    // MARK: Company settings

    @Test func roleOverrideWins() throws {
        let w = try SandboxWorld()
        var c = w.company
        #expect(c.permissionProfile == .sandboxed)
        #expect(c.profile(forRole: "engineer") == .sandboxed)
        c.roleProfiles = ["engineer": .full, "qa": .workspace]
        #expect(c.profile(forRole: "engineer") == .full)
        #expect(c.profile(forRole: "qa") == .workspace)
        #expect(c.profile(forRole: "ceo") == .sandboxed)
        c.permissionProfile = .workspace
        #expect(c.profile(forRole: "ceo") == .workspace)
    }

    @Test func companyDefaultsAfterMigration() throws {
        let w = try SandboxWorld()
        let c = try #require(try w.store.company(id: w.company.id))
        #expect(c.permissionProfile == .sandboxed)
        #expect(c.roleProfiles.isEmpty)
        #expect(c.allowedDomains.isEmpty && c.webDomains.isEmpty && c.toolchainReadPaths.isEmpty)
        #expect(c.allowLocalBinding)
        let raw = try w.store.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT permissionProfile, roleProfiles, allowedDomains, webDomains, allowLocalBinding, toolchainReadPaths FROM company")
        }
        let row = try #require(raw)
        #expect(row["permissionProfile"] as String? == "sandboxed")
        #expect(row["roleProfiles"] as String? == "{}")
        #expect(row["allowedDomains"] as String? == "[]")
        #expect(row["allowLocalBinding"] as Bool? == true)
    }

    /// M8: an owner's list edit is applied to the stored company inside the write, so two edits made from stale copies both
    /// land (no lost update).
    @Test func sandboxListEditsApplyToTheStoredCompany() throws {
        let w = try SandboxWorld()
        let stale = w.company
        try w.store.editSandbox(companyId: stale.id, userHome: w.userHome) { try .domains(.add("one.example.com"), web: false, company: $0) }
        try w.store.editSandbox(companyId: stale.id, userHome: w.userHome) { try .domains(.add("two.example.com"), web: false, company: $0) }
        try w.store.editSandbox(companyId: stale.id, userHome: w.userHome) { try .toolchain(.add("/opt/tool-a"), company: $0) }
        try w.store.editSandbox(companyId: stale.id, userHome: w.userHome) { try .toolchain(.add("/opt/tool-b"), company: $0) }
        let c = try #require(try w.store.company(id: stale.id))
        #expect(c.allowedDomains == ["one.example.com", "two.example.com"])
        #expect(c.toolchainReadPaths == ["/opt/tool-a", "/opt/tool-b"])
        // A refused edit changes nothing.
        #expect(throws: (any Error).self) {
            try w.store.editSandbox(companyId: stale.id, userHome: w.userHome) { try .domains(.add("api.anthropic.com"), web: false, company: $0) }
        }
        #expect(try w.store.company(id: stale.id)?.allowedDomains == ["one.example.com", "two.example.com"])
    }

    @Test func updateSandboxPersistsAndValidates() throws {
        let w = try SandboxWorld()
        try w.store.updateSandbox(companyId: w.company.id, SandboxPatch(
            profile: .workspace, roleProfiles: ["engineer": .full], allowedDomains: ["API.Stripe.com", "*.stripe.com"],
            webDomains: ["docs.example.org"], allowLocalBinding: false, toolchainReadPaths: ["/opt/homebrew"]))
        let c = try #require(try w.store.company(id: w.company.id))
        #expect(c.permissionProfile == .workspace)
        #expect(c.roleProfiles == ["engineer": .full])
        #expect(c.allowedDomains == ["*.stripe.com", "api.stripe.com"])
        #expect(c.webDomains == ["docs.example.org"])
        #expect(!c.allowLocalBinding)
        #expect(c.toolchainReadPaths == ["/opt/homebrew"])
        // Nil fields are left alone.
        try w.store.updateSandbox(companyId: w.company.id, SandboxPatch(allowLocalBinding: true))
        let again = try #require(try w.store.company(id: w.company.id))
        #expect(again.allowedDomains == c.allowedDomains && again.allowLocalBinding)

        for bad in ["*", "localhost", "127.0.0.1", "*.com", "*.co.uk", "*.github.io", "nodot", "a b.com", "-"] {
            #expect(throws: (any Error).self, "\(bad)") {
                try w.store.updateSandbox(companyId: w.company.id, SandboxPatch(allowedDomains: [bad]))
            }
            #expect(throws: (any Error).self, "\(bad)") {
                try w.store.updateSandbox(companyId: w.company.id, SandboxPatch(webDomains: [bad]))
            }
        }
        for bad in ["~", "~/Library", "/Volumes", "relative", w.paths.home.path, "/opt/it's"] {
            #expect(throws: SandboxError.self, "\(bad)") {
                try w.store.updateSandbox(companyId: w.company.id, SandboxPatch(toolchainReadPaths: [bad]))
            }
        }
        // A refused patch changes nothing.
        #expect(try w.store.company(id: w.company.id) == again)
        #expect(throws: (any Error).self) { try w.store.updateSandbox(companyId: "nope", SandboxPatch(allowLocalBinding: true)) }
    }

    @Test func updateCompanyKeepsSandboxSettings() throws {
        let w = try SandboxWorld()
        try w.store.updateSandbox(companyId: w.company.id, SandboxPatch(allowedDomains: ["api.stripe.com"]))
        var stale = w.company
        stale.allowedDomains = ["evil.example.com"]
        stale.permissionProfile = .full
        stale.goal = "new goal"
        try w.store.updateCompany(stale)
        let c = try #require(try w.store.company(id: w.company.id))
        #expect(c.goal == "new goal")
        #expect(c.allowedDomains == ["api.stripe.com"])
        #expect(c.permissionProfile == .sandboxed)
    }

    // MARK: Network

    @Test func networkDefaultsAndOwnerDomains() throws {
        var w = try SandboxWorld()
        w.company.allowedDomains = ["API.Stripe.com", "registry.npmjs.org"]
        w.company.webDomains = ["Docs.Example.org"]
        let n = CompanyNetwork.scope(company: w.company, grantDomains: ["grant.example.com"], grantWebDomains: ["web.grant.io"])
        #expect(n.allowedDomains == Array(Set(CompanyNetwork.defaultRegistries + ["api.stripe.com", "grant.example.com"])).sorted())
        #expect(n.webDomains == Array(Set(CompanyNetwork.defaultRegistries + CompanyNetwork.defaultDocs
                                          + ["docs.example.org", "web.grant.io"])).sorted())
        #expect(!n.allowedDomains.contains("developer.apple.com"))
        #expect(n.allowLocalBinding)
        #expect(CompanyNetwork.defaultRegistries.count == 15 && CompanyNetwork.defaultDocs.count == 8)
        let s = try w.scope(.work, grants: GrantInputs(domains: ["grant.example.com"], webDomains: ["web.grant.io"]))
        #expect(s.network == n)
    }

    @Test(arguments: ["api.anthropic.com", "*.anthropic.com", "claude.ai", "claude.com", "claude.ai.", "x.claude.ai", "x.claude.com",
                      "*.claude.com", "*.ai"])
    func anthropicDomainsRefused(_ d: String) throws {
        var w = try SandboxWorld()
        let shown = SandboxDomains.normalize(d)
        w.company.allowedDomains = [d]
        expectSandboxError(.forbiddenDomain(shown)) { _ = try w.scope(.work) }
        w.company.allowedDomains = []
        w.company.webDomains = [d.uppercased()]
        expectSandboxError(.forbiddenDomain(shown)) { _ = try w.scope(.work) }
        w.company.webDomains = []
        expectSandboxError(.forbiddenDomain(shown)) { _ = try w.scope(.work, grants: GrantInputs(domains: [d])) }
        expectSandboxError(.forbiddenDomain(shown)) { _ = try w.scope(.work, grants: GrantInputs(webDomains: [d])) }
        expectSandboxError(.forbiddenDomain(shown)) {
            try w.store.updateSandbox(companyId: w.company.id, SandboxPatch(allowedDomains: [d]))
        }
        expectSandboxError(.forbiddenDomain(shown)) {
            try w.store.updateSandbox(companyId: w.company.id, SandboxPatch(webDomains: [d]))
        }
    }

    // MARK: Readability (5L-1)

    @Test func otherAgentLabNotReadable() throws {
        let w = try SandboxWorld()
        try SandboxLayout(paths: w.paths, company: w.company, agentHandle: "eng-2").ensure()
        for kind in TurnKind.allCases {
            let s = try w.scope(kind)
            let shown = s.readable.paths + s.readOnlyDirs.paths + s.writable.paths + [s.cwd.path]
            for other in [w.p(".brahma/labs/eng-2"), w.p(".brahma/home/eng-2"), w.p(".brahma/notes/agents/eng-2.md")] {
                #expect(!shown.contains { $0 == other || $0.hasPrefix(other + "/") }, "\(kind) shows \(other)")
            }
            // Nothing shown contains another agent's place either.
            #expect(!shown.contains { $0 == w.p(".brahma/labs") || $0 == w.p(".brahma/home") || $0 == w.p(".brahma/notes") || $0 == w.p(".brahma/notes/agents") })
            #expect(s.denyRead.paths.contains(w.p(".brahma")))
        }
    }

    @Test func ownLabReadable() throws {
        let w = try SandboxWorld()
        let s = try w.scope(.work)
        for own in [".brahma/labs/eng-1", ".brahma/home/eng-1", ".brahma/notes/agents/eng-1.md", ".brahma/bin/shell-eng-1.sh"] {
            #expect(s.readable.paths.contains(w.p(own)), "\(own)")
        }
    }

    @Test func allowlistedDotBrahmaChildrenReadableWhenTheyExist() throws {
        let w = try SandboxWorld()
        let children = ["wt", "artifacts", "progress", "handoffs", "releases", "resources/company", "kb", "ext",
                        "hooks", "cache/shared"]
        // B-M9 (10b): `ext-review` and `ext-try` are not among them (the reviewer's pages and the owner's try turn only).
        for reviewerOnly in ["ext-review", "ext-try"] {
            try FileManager.default.createDirectory(atPath: w.p(".brahma/\(reviewerOnly)"), withIntermediateDirectories: true)
        }
        for child in children { try FileManager.default.createDirectory(atPath: w.p(".brahma/\(child)"), withIntermediateDirectories: true) }
        for engineOnly in ["checks", "wt-check", "plans/X-9", "resources/secret", "cache/other"] {
            try FileManager.default.createDirectory(atPath: w.p(".brahma/\(engineOnly)"), withIntermediateDirectories: true)
        }
        let s = try w.scope(.work)
        for child in children { #expect(s.readable.paths.contains(w.p(".brahma/\(child)")), "\(child)") }
        for engineOnly in ["checks", "wt-check", "plans", "resources", "cache", "resources/secret", "cache/other", "ext-review", "ext-try"] {
            #expect(!s.readable.paths.contains(w.p(".brahma/\(engineOnly)")), "\(engineOnly)")
        }
        #expect(s.readOnlyDirs.paths.contains(w.p(".brahma/resources/company")))
        #expect(s.readOnlyDirs.paths.contains(w.p(".brahma/kb")))
    }

    @Test func newTopLevelEntryPickedUpNextTurn() throws {
        let w = try SandboxWorld()
        let first = try w.scope(.work)
        #expect(!first.readable.paths.contains(w.p("docs")))
        try FileManager.default.createDirectory(atPath: w.p("docs"), withIntermediateDirectories: true)
        let second = try w.scope(.work)
        #expect(second.readable.paths.contains(w.p("docs")))
        #expect(second.readable.paths.contains(w.p(".git")))
        for s in [first, second] {
            #expect(!s.readable.paths.contains(w.p(".brahma")))
            #expect(!s.readable.paths.contains(w.ws.path))
        }
    }

    @Test func writableIsAlwaysReadable() throws {
        let w = try SandboxWorld()
        for kind in TurnKind.allCases {
            let s = try w.scope(kind)
            for entry in s.writable + [s.cwd] {
                #expect(s.readable.contains { entry.path == $0.path || entry.path.hasPrefix($0.path + "/") }, "\(kind) \(entry.path)")
            }
        }
    }

    @Test func grantReadPathsAreReadOnly() throws {
        let w = try SandboxWorld()
        let docs = w.root.appending(path: "shared-docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let s = try w.scope(.work, grants: GrantInputs(readPaths: [docs]))
        #expect(s.readable.paths.contains(docs.path))
        #expect(s.readOnlyDirs.paths.contains(docs.path))
        #expect(!s.writable.paths.contains(docs.path))
        expectAnySandboxError({ _ = try w.scope(.work, grants: GrantInputs(readPaths: [w.paths.home])) }) {
            if case .overlapsProtected = $0 { true } else { false }
        }
    }

    // MARK: Write denials (5L-2 and the 3a carry-overs)

    @Test func cacheAndResourcesWriteDenied() throws {
        let w = try SandboxWorld()
        for kind in TurnKind.allCases {
            let s = try w.scope(kind)
            #expect(s.denyWrite.paths.contains(w.p(".brahma/cache")))
            #expect(s.denyWrite.paths.contains(w.p(".brahma/resources")))
        }
        #expect(w.layout.agentCache.path.hasPrefix(w.layout.agentHome.path + "/"))
        #expect(w.layout.sharedCache.path == w.ws.appending(path: ".brahma/cache/shared").path)
    }

    @Test func commonGitDirInternalsNotWritable() throws {
        let w = try SandboxWorld()
        try FileManager.default.createDirectory(atPath: w.p(".git/worktrees/OTHER-2"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: w.p(".git/refs/heads/item/OTHER-2"), contents: Data())
        FileManager.default.createFile(atPath: w.p(".git/logs/refs/heads/item/OTHER-2"), contents: Data())
        let k = w.key
        let internals = [".git/config", ".git/config.worktree", ".git/hooks", ".git/info", ".git/objects/info", ".git/packed-refs",
                         ".git/HEAD", ".git/logs/HEAD", ".git/modules", ".git/commondir", ".git/refs/heads/main", ".git/refs/tags",
                         ".git/refs/remotes", ".git/refs/replace", ".git/refs/notes", ".git/refs/stash",
                         ".git/worktrees/\(k)/config.worktree", ".git/worktrees/\(k)/commondir", ".git/worktrees/\(k)/gitdir",
                         ".git/worktrees/OTHER-2", ".git/refs/heads/item/OTHER-2", ".git/logs/refs/heads/item/OTHER-2"]
        let own = Set([".git/refs/heads/item/\(k)", ".git/refs/heads/item/\(k).lock", ".git/logs/refs/heads/item/\(k)"].map(w.p))
        for kind in TurnKind.allCases {
            let s = try w.scope(kind)
            for path in internals.map(w.p) {
                #expect(s.denyWrite.paths.contains(path), "\(kind) lacks deny \(path)")
                // No writable entry is that path or inside it; an allowed parent is fine only because the deny wins.
                #expect(!s.writable.paths.contains { $0 == path || $0.hasPrefix(path + "/") }, "\(kind) writes \(path)")
            }
            // The only refs a turn writes are its own item's ref, lock and reflog.
            let refs = s.writable.paths.filter { $0.hasPrefix(w.p(".git/refs")) || $0.hasPrefix(w.p(".git/logs")) }
            #expect(Set(refs).isSubset(of: own), "\(kind) writes \(refs)")
            // Nothing writable contains the common git dir's own files.
            #expect(!s.writable.paths.contains { $0 == w.p(".git") || $0 == w.p(".git/refs") || $0 == w.p(".git/worktrees") })
        }
        // The item worktree's own `.git` file (its link to the admin dir) is not writable either.
        #expect(try w.scope(.work).denyWrite.paths.contains(w.p(".brahma/wt/\(k)/.git")))
    }

    @Test func engineDotBrahmaAndDataHomeNotWritable() throws {
        let w = try SandboxWorld()
        try SandboxLayout(paths: w.paths, company: w.company, agentHandle: "eng-2").ensure()
        try FileManager.default.createDirectory(atPath: w.p(".brahma/plans/OTHER-2"), withIntermediateDirectories: true)
        _ = try NotesFile.append(workspace: w.ws, team: nil, heading: "retro", lines: ["x"])
        try FileManager.default.createDirectory(atPath: w.p(".brahma/progress"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: w.p(".brahma/progress/OTHER-2.md"), contents: Data())
        let engineOnly = [".brahma/checks", ".brahma/wt-check", ".brahma/releases", ".brahma/artifacts", ".brahma/handoffs",
                          ".brahma/resources", ".brahma/cache", ".brahma/ext", ".brahma/ext-review", ".brahma/hooks", ".brahma/bin",
                          ".brahma/wt/.preview", ".brahma/wt/.release", ".brahma/wt/.merge", ".brahma/home/eng-2",
                          ".brahma/labs/eng-2", ".brahma/notes/agents/eng-2.md", ".brahma/notes/company.md",
                          ".brahma/progress/OTHER-2.md"]
        for kind in TurnKind.allCases {
            let s = try w.scope(kind)
            #expect(s.denyWrite.paths.contains(w.paths.home.path), "\(kind)")
            #expect(s.denyRead.paths.contains(w.paths.home.path), "\(kind)")
            #expect(s.protected.paths.contains(w.paths.home.path), "\(kind)")
            for path in engineOnly.map(w.p) {
                #expect(s.denyWrite.paths.contains(path), "\(kind) lacks deny \(path)")
                #expect(!s.writable.paths.contains { $0 == path || $0.hasPrefix(path + "/") }, "\(kind) writes \(path)")
            }
            if kind == .plan {
                #expect(s.denyWrite.paths.contains(w.p(".brahma/plans/OTHER-2")))
                #expect(!s.denyWrite.paths.contains(w.p(".brahma/plans")))
            } else {
                #expect(s.denyWrite.paths.contains(w.p(".brahma/plans")))
            }
            if s.writable.paths.contains(w.p(".brahma/progress/\(w.key).md")) {
                #expect(!s.denyWrite.paths.contains(w.p(".brahma/progress")))
            } else {
                #expect(s.denyWrite.paths.contains(w.p(".brahma/progress")))
            }
            #expect(!s.writable.paths.contains { $0.hasPrefix(w.paths.home.path + "/") || $0 == w.paths.home.path })
            #expect(!s.writable.paths.contains(w.p(".brahma")))
            // Every deny that matters is not undone by a writable entry equal to it.
            #expect(Set(s.writable.paths).isDisjoint(with: Set(s.denyWrite.paths)), "\(kind)")
        }
    }

    /// Plan L (PR-7): `.brahma/preview` is engine-only (write-denied on every turn, even before it exists); its `logs` are
    /// readable when they exist (the failure DM points the setter at the log), and nothing else of it is.
    @Test func previewDirIsEngineOnlyAndItsLogsReadable() throws {
        let w = try SandboxWorld()
        let before = try w.scope(.work)
        #expect(before.denyWrite.paths.contains(w.p(".brahma/preview")))
        #expect(!before.readable.paths.contains(w.p(".brahma/preview/logs")), "not mounted while missing")
        let l = EngineLayout(workspace: w.ws)
        try FileManager.default.createDirectory(at: l.previewLogs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: l.previewDir.appending(path: "other"), withIntermediateDirectories: true)
        for kind in TurnKind.allCases {
            let s = try w.scope(kind)
            #expect(s.denyWrite.paths.contains(w.p(".brahma/preview")), "\(kind)")
            #expect(s.readable.paths.contains(w.p(".brahma/preview/logs")), "\(kind)")
            #expect(!s.readable.paths.contains(w.p(".brahma/preview")) && !s.readable.paths.contains(w.p(".brahma/preview/other")), "\(kind)")
            #expect(!s.writable.paths.contains { $0 == w.p(".brahma/preview") || $0.hasPrefix(w.p(".brahma/preview") + "/") }, "\(kind)")
        }
        #expect(l.previewLogs.path == w.p(".brahma/preview/logs"))
    }

    @Test func mergeRepoNotReachable() throws {
        let w = try SandboxWorld()
        let git = w.store.gitWorkspace(root: w.ws, companyId: w.company.id)
        let repo = git.mergeRepositoryPath.resolvedForSandbox.path
        let checkouts = w.paths.checkoutDir(runId: "r1").resolvedForSandbox.path
        let home = w.paths.home.resolvedForSandbox.path
        // 3a keeps the merge repository and submission checkouts under the data home, which every turn denies.
        #expect(repo.hasPrefix(home + "/"))
        #expect(checkouts.hasPrefix(home + "/"))
        #expect(!repo.hasPrefix(w.ws.path + "/"))
        for kind in TurnKind.allCases {
            let s = try w.scope(kind)
            #expect(s.denyRead.paths.contains(home) && s.denyWrite.paths.contains(home))
            let shown = s.readable.paths + s.readOnlyDirs.paths + s.writable.paths + [s.cwd.path]
            for engine in [repo, checkouts] {
                #expect(!shown.contains { engine == $0 || engine.hasPrefix($0 + "/") }, "\(kind) reaches \(engine)")
            }
            // The legacy in-workspace merge checkout stays write-denied.
            #expect(s.denyWrite.paths.contains(w.p(".brahma/wt/.merge")))
        }
    }

    // MARK: Layout

    @Test func labIsGitRepo() throws {
        let w = try SandboxWorld()
        let lab = w.layout.lab
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: lab.appending(path: ".git").path, isDirectory: &isDir) && isDir.boolValue)
        #expect(try GitFixture.plainGit(["symbolic-ref", "HEAD"], in: lab) == "refs/heads/main")
        // No template: no sample hooks.
        let hooks = (try? FileManager.default.contentsOfDirectory(atPath: lab.appending(path: ".git/hooks").path)) ?? []
        #expect(hooks.isEmpty)
        // Idempotent: a second ensure keeps the repo and its commits.
        try "x".write(to: lab.appending(path: "f.txt"), atomically: true, encoding: .utf8)
        try GitFixture.plainGit(["add", "f.txt"], in: lab)
        try GitFixture.plainGit(["commit", "-qm", "one"], in: lab)
        try w.layout.ensure()
        #expect(try GitFixture.plainGit(["log", "--format=%s"], in: lab) == "one")
    }

    @Test func layoutPathsAndEnsure() throws {
        let w = try SandboxWorld()
        let l = w.layout
        let ws = w.ws.path
        #expect(l.workspace.path == ws)
        #expect(l.dotBrahma.path == ws + "/.brahma")
        #expect(l.agentHome.path == ws + "/.brahma/home/eng-1")
        #expect(l.lab.path == ws + "/.brahma/labs/eng-1")
        #expect(l.agentCache.path == ws + "/.brahma/home/eng-1/cache")
        #expect(l.extLib.path == ws + "/.brahma/ext")
        #expect(l.hooksDir.path == ws + "/.brahma/hooks")
        #expect(l.shellPrefix.path == ws + "/.brahma/bin/shell-eng-1.sh")
        #expect(l.notes.path == ws + "/.brahma/notes/agents/eng-1.md")
        #expect(!FileManager.default.fileExists(atPath: ws + "/.brahma/notes/eng-1.md"))
        #expect(l.plansDir("ACME-3").path == ws + "/.brahma/plans/ACME-3")
        #expect(l.gitDir.path == ws + "/.git")
        func mode(_ url: URL) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        for dir in [l.agentHome, l.lab, l.agentCache] { #expect(try mode(dir) == 0o700, "\(dir.path)") }
        #expect(try mode(l.notes) == 0o600)
        #expect(try Data(contentsOf: l.notes).isEmpty)
        let gitconfig = try String(contentsOf: l.agentHome.appending(path: ".gitconfig"), encoding: .utf8)
        #expect(gitconfig.contains("name = eng-1"))
        #expect(gitconfig.contains("email = eng-1@\(w.company.slug).brahma.local"))
        for dir in [".git/refs/heads/item", ".git/logs/refs/heads/item"] {
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: w.p(dir), isDirectory: &isDir) && isDir.boolValue)
        }
        // An existing notes file is kept.
        try "mine".write(to: l.notes, atomically: true, encoding: .utf8)
        try l.ensure()
        #expect(try String(contentsOf: l.notes, encoding: .utf8) == "mine")
    }

    @Test func ensureRefusesALinkedNotesFileAndAMissingRepo() throws {
        let w = try SandboxWorld(ensure: false)
        try FileManager.default.createDirectory(atPath: w.p(".brahma/notes/agents"), withIntermediateDirectories: true)
        let target = w.root.appending(path: "outside.md")
        try "owner".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: w.p(".brahma/notes/agents/eng-1.md"), withDestinationPath: target.path)
        #expect(throws: (any Error).self) { try w.layout.ensure() }
        #expect(try String(contentsOf: target, encoding: .utf8) == "owner")

        var bare = w.company
        bare.workspacePath = w.root.appending(path: "norepo").path
        try FileManager.default.createDirectory(atPath: bare.workspacePath, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try SandboxLayout(paths: w.paths, company: bare, agentHandle: "eng-1").ensure() }
        #expect(!FileManager.default.fileExists(atPath: bare.workspacePath + "/.git"))
    }

    @Test func sentinelAndExtensionPaths() throws {
        let paths = BrahmaPaths(home: URL(fileURLWithPath: "/h", isDirectory: true), workspaces: URL(fileURLWithPath: "/w", isDirectory: true))
        #expect(paths.sentinel.path == "/h/run/.sentinel")
        #expect(paths.extensionsDir.root.path == "/h/extensions")
        #expect(paths.extensionsDir.store.path == "/h/extensions/store")
        #expect(paths.extensionsDir.staging.path == "/h/extensions/staging")
        #expect(paths.extensionsDir.state.path == "/h/extensions/state")
    }
}
