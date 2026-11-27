import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Ruling C5b-8 (FW-B2 items 5, 23): the live reader set (C5b-5: the lease holder, else the assignee, plus the reviewer) holds
/// at the filesystem layer too. A sandboxed turn reads another item's worktree, progress file and git admin dir only when its
/// agent is in that item's live reader set, built from the engine's lease and review records when the turn is compiled.
/// Run for real under Seatbelt with a policy mirroring each turn's scope (as the canary's model-free layer does), in a scratch
/// directory under the owner's real home, so the home denial is the real one.
@Suite(.scratch, .serialized) struct LiveReaderSandboxTests {
    struct World {
        let root: URL
        let userHome: URL
        let paths: BrahmaPaths
        let store: Store
        let company: Company
        let holder: Agent, reviewer: Agent, outsider: Agent
        let item: WorkItem
        let ws: URL
        let token = "LIVE-SECRET-\(UUID().uuidString)"

        /// `realWorktree`: the item's worktree is a real linked git worktree (3a's `addWorktree`) instead of planted files.
        init(realWorktree: Bool = false) throws {
            root = try Scratch.homeDir().resolvedForSandbox
            userHome = root.appending(path: "user")
            paths = BrahmaPaths(home: root.appending(path: "data"), workspaces: root.appending(path: "wss"))
            for dir in [userHome, paths.home, paths.workspaces] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            store = try Store(path: paths.database.path)
            company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
            holder = try store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
            reviewer = try store.hire(companyId: company.id, name: "rev-1", role: "engineer", model: "sonnet")
            outsider = try store.hire(companyId: company.id, name: "eng-2", role: "engineer", model: "sonnet")
            item = try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(
                type: .task, title: "Live", checkSpec: CheckSpec(command: "true", paths: ["src"]), ownerId: holder.id,
                reviewerId: reviewer.id, status: .ready), now: Date())
            try store.claimLease(itemId: item.id, agentId: holder.id)
            ws = URL(fileURLWithPath: company.workspacePath, isDirectory: false).resolvedForSandbox
            for agent in [holder, reviewer, outsider] {
                try SandboxLayout(paths: paths, company: company, agentHandle: agent.name).ensure()
            }
            if realWorktree { _ = try GitWorkspace(root: ws).addWorktree(key: item.key) }
            try write(".brahma/wt/\(item.key)/notes.txt", "worktree \(token)")
            try write(".brahma/progress/\(item.key).md", "progress \(token)")
            if !realWorktree { try write(".git/worktrees/\(item.key)/index", "admin \(token)") }
            try write("MAIN.md", "company main")
        }

        func write(_ relative: String, _ text: String) throws {
            let url = ws.appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func p(_ relative: String) -> String { ws.appending(path: relative).path }
        var worktreeFile: String { p(".brahma/wt/\(item.key)/notes.txt") }
        var progressFile: String { p(".brahma/progress/\(item.key).md") }
        var adminFile: String { p(".git/worktrees/\(item.key)/index") }

        /// An itemless work turn of `agent` (its lab is the cwd), or its turn on `item`, with the live keys the engine reads (or
        /// `keys`).
        func scope(_ agent: Agent, keys: Set<String>?? = .none, item: WorkItem? = nil) throws -> SandboxScope {
            let live: Set<String>? = try keys ?? store.liveReaderItemKeys(companyId: company.id, agentId: agent.id)
            return try SandboxScope.forTurn(layout: SandboxLayout(paths: paths, company: company, agentHandle: agent.name), paths: paths,
                                            otherWorkspaces: [], backupTargets: [], kind: .work, item: item, company: company,
                                            grants: GrantInputs(), darwinUserTemp: nil, userHome: userHome, liveReadKeys: live)
        }

        /// Runs `command` in the turn's cwd under Seatbelt with the turn's scope mirrored (the canary's model-free policy).
        func run(_ command: String, _ scope: SandboxScope) async throws -> (CheckOutcome, String) {
            let scratch = try tempDir().resolvedForSandbox
            var policy = SandboxPolicy(writable: [scratch, scope.cwd] + scope.writable, readable: scope.readable, network: .none, toolchain: false)
            policy.hiddenReads = scope.hiddenReads
            let places = SandboxCanary.LocalPlaces(paths: paths, workspace: ws, otherWorkspaces: [], userHome: userHome)
            let baseline = SandboxCanary.localBaseline(base: nil, places: places)
            let runner = SeatbeltRunner(baseline: { baseline }, proxies: EgressProxyPool())
            let out = scratch.appending(path: "out.log")
            let outcome = await runner.run(command: command, cwd: scope.cwd, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                                           timeout: .seconds(30), outputURL: out, policy: policy)
            return (outcome, (try? String(contentsOf: out, encoding: .utf8)) ?? "")
        }
    }

    @Test func readerSetComesFromTheEngineRecords() throws {
        let w = try World()
        #expect(try w.store.liveReaderItemKeys(companyId: w.company.id, agentId: w.holder.id) == [w.item.key])
        #expect(try w.store.liveReaderItemKeys(companyId: w.company.id, agentId: w.reviewer.id) == [w.item.key])
        #expect(try w.store.liveReaderItemKeys(companyId: w.company.id, agentId: w.outsider.id).isEmpty)
        // The lease decides over the assignee (C5b-5): the outsider holding the lease is the reader, the assignee no longer is.
        try w.store.writer.write { db in try db.execute(sql: "UPDATE workLease SET agentId = ? WHERE itemId = ?", arguments: [w.outsider.id, w.item.id]) }
        #expect(try w.store.liveReaderItemKeys(companyId: w.company.id, agentId: w.outsider.id) == [w.item.key])
        #expect(try w.store.liveReaderItemKeys(companyId: w.company.id, agentId: w.holder.id).isEmpty)
    }

    @Test func scopeMountsOnlyTheReadersLivePlaces() throws {
        let w = try World()
        let live = [".brahma/wt/\(w.item.key)", ".brahma/progress/\(w.item.key).md", ".git/worktrees/\(w.item.key)"].map(w.p)
        for reader in [w.holder, w.reviewer] {
            let s = try w.scope(reader)
            for place in live { #expect(s.readable.map(\.path).contains(place), "\(reader.name): \(place)") }
        }
        for s in [try w.scope(w.outsider), try w.scope(w.holder, keys: .some(nil))] {
            for place in live { #expect(!s.readable.contains { SandboxPath.isInside(place, $0.path) }, "\(place) is readable") }
            // Never the whole `.git`, `.brahma/wt` or `.brahma/progress`; `.git/worktrees` is a read-denied root.
            #expect(!s.readable.map(\.path).contains(w.p(".git")))
            #expect(!s.readable.map(\.path).contains(w.p(".brahma/wt")) && !s.readable.map(\.path).contains(w.p(".brahma/progress")))
            #expect(s.denyRead.map(\.path).contains(w.p(".git/worktrees")) && s.hiddenReads.map(\.path).contains(w.p(".git/worktrees")))
            #expect(s.readable.map(\.path).contains(w.p(".git/objects")) && s.readable.map(\.path).contains(w.p(".git/HEAD")))
            #expect(s.readable.map(\.path).contains(w.p("MAIN.md")))
            // The compiled settings say the same: nothing re-allows another item's live places.
            let settings = ClaudeSettingsCompiler.compile(scope: s, profile: .sandboxed, mode: nil, mounts: [], postToolHook: nil, preToolHook: nil)
            let allow = settings.sandbox?.filesystem?.allowRead ?? [], deny = settings.sandbox?.filesystem?.denyRead ?? []
            for place in live {
                #expect(!allow.contains { SandboxPath.isInside(place, $0) }, "allowRead re-opens \(place)")
                #expect(deny.contains { SandboxPath.isInside(place, $0) }, "denyRead misses \(place)")
            }
        }
    }

    /// A live place replaced by a link (to another item's worktree) is never mounted, whatever the keys say.
    @Test func linkedLivePlaceIsNotMounted() throws {
        let w = try World()
        try FileManager.default.createSymbolicLink(atPath: w.p(".brahma/wt/LINKED-1"), withDestinationPath: w.p(".brahma/wt/\(w.item.key)"))
        try FileManager.default.createSymbolicLink(atPath: w.p(".git/worktrees/LINKED-1"), withDestinationPath: w.p(".git/worktrees/\(w.item.key)"))
        let s = try w.scope(w.outsider, keys: .some(["LINKED-1"]))
        #expect(!s.readable.contains { $0.path.contains("LINKED-1") })
        // A key that is not an item key is never a path.
        let odd = try w.scope(w.outsider, keys: .some(["../\(w.item.key)", "a/b"]))
        #expect(!odd.readable.contains { $0.path.contains("/.brahma/wt/") || $0.path.contains("/.git/worktrees/") })
    }

    /// The sandbox test the ruling asks for: a non-reader's `cat` of another item's worktree file, progress file and git admin
    /// dir is denied (directly and through a link it planted in its own lab), while the holder and the reviewer read them;
    /// company main stays readable to everyone. Unreadable records (no keys) deny the holder too.
    @Test(.enabled(if: Toolchain.seatbeltAvailable, "no /usr/bin/sandbox-exec"))
    func nonReaderIsDeniedWhileHolderAndReviewerRead() async throws {
        let w = try World()
        let files = [w.worktreeFile, w.progressFile, w.adminFile]
        for denied in [try w.scope(w.outsider), try w.scope(w.holder, keys: .some(nil))] {
            for file in files {
                let (out, text) = try await w.run("/bin/cat '\(file)'", denied)
                #expect(out.exitCode != 0, "\(file) was readable: \(text)")
                #expect(!text.contains(w.token), "\(file) leaked")
            }
            let lab = denied.cwd.path
            let (linked, linkedText) = try await w.run("/bin/ln -s '\(w.worktreeFile)' '\(lab)/via' && /bin/cat '\(lab)/via'", denied)
            #expect(linked.exitCode != 0 && !linkedText.contains(w.token), "a link in the lab reached the worktree: \(linkedText)")
            try? FileManager.default.removeItem(atPath: "\(lab)/via")
            let (listed, listText) = try await w.run("/bin/ls '\(w.p(".brahma/wt"))' '\(w.p(".git/worktrees"))'", denied)
            #expect(listed.exitCode != 0, "the live directories could be listed: \(listText)")
            let (main, mainText) = try await w.run("/bin/cat '\(w.p("MAIN.md"))'", denied)
            #expect(main.exitCode == 0 && mainText.contains("company main"), "company main: \(mainText)")
        }
        for reader in [w.holder, w.reviewer] {
            let s = try w.scope(reader)
            let (out, text) = try await w.run(files.map { "/bin/cat '\($0)'" }.joined(separator: " && "), s)
            #expect(out.exitCode == 0, "\(reader.name) could not read its item's live places: \(text)")
            #expect(text.contains("worktree \(w.token)") && text.contains("progress \(w.token)") && text.contains("admin \(w.token)"))
        }
        // git over the company's repository still works for a non-reader (the common git dir is mounted by its children).
        let gitBinary = Toolchain.developerDir + "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: gitBinary) else { return }
        let (git, gitText) = try await w.run("'\(gitBinary)' --git-dir='\(w.p(".git"))' log -1 --format=%s main", try w.scope(w.outsider))
        #expect(git.exitCode == 0, "git under the turn's read scope: \(gitText)")
    }

    /// The holder's own item turn still works with git under the narrowed read scope: status, add and commit in its worktree
    /// (its admin dir is its own; `.git/worktrees` as a whole is hidden, so git sees no other worktree).
    @Test(.enabled(if: Toolchain.seatbeltAvailable, "no /usr/bin/sandbox-exec"))
    func holdersItemTurnStillCommits() async throws {
        let gitBinary = Toolchain.developerDir + "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: gitBinary) else { return }
        let w = try World(realWorktree: true)
        let s = try w.scope(w.holder, item: w.item)
        #expect(s.cwd.path == w.p(".brahma/wt/\(w.item.key)"))
        let git = "'\(gitBinary)' -c user.name=eng-1 -c user.email=eng-1@acme.brahma.local"
        let (out, text) = try await w.run("\(git) status --porcelain && echo change > change.txt && \(git) add change.txt notes.txt "
                                          + "&& \(git) commit -q -m 'holder commit' && \(git) log -1 --format=%s", s)
        #expect(out.exitCode == 0, "\(text)")
        #expect(text.contains("holder commit"), "\(text)")
        // The outsider still reads none of it (its admin dir included).
        let (denied, deniedText) = try await w.run("/bin/cat '\(w.p(".git/worktrees/\(w.item.key)/HEAD"))'", try w.scope(w.outsider))
        #expect(denied.exitCode != 0, "\(deniedText)")
    }

    /// The canary's built-in probe "read another item's worktree" (C5b-8): its probes name the planted places, and they are
    /// part of every canary key, so a pass recorded before them (the old key form) no longer unlocks a sandboxed turn.
    @Test func builtInProbesAreInTheCanaryKey() {
        #expect(CanaryProbes.builtIn.allSatisfy(\.builtin) && CanaryProbes.builtIn.map(\.label).first == "built-in 1")
        for variable in [CanaryProbes.otherItemWorktreeVariable, CanaryProbes.otherItemProgressVariable, CanaryProbes.otherItemGitDirVariable] {
            #expect(CanaryProbes.builtIn.contains { $0.text.contains("$\(variable)") }, "\(variable)")
            #expect(CanaryProbes.variables.contains(variable))
        }
        let before = StableHash.fnv1a64("cli" + "\u{0}" + "probes")
        #expect(CanaryProbes.keyFingerprint(cli: "cli", probes: "probes") != before, "a pre-FW-B2 canary pass would still match")
    }
}
