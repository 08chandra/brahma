import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// What the engine needs from the owner's machine to compute sandbox scopes: the owner's home (protected paths), the Darwin
/// per-user temp dir xcrun writes, and the shell the agent's Bash prefix execs. Tests pass their own.
public struct SandboxEnvironment: Sendable {
    public var userHome: URL
    public var darwinUserTemp: URL?
    public var shell: String
    /// Whether the engine can see what a sandbox allows (`ContainmentSelfTest`, once per engine); without it sandboxed turns
    /// do not start. Tests pass their own.
    public var canSeeSandboxes: @Sendable () -> Bool
    /// `/private/tmp/b-<uid>`: each sandboxed agent's claude keeps its temp files in a private directory under it (short
    /// enough for Claude Code to use: `SandboxScope.claudeTmpMaxLength`). Nil: Claude's own default.
    public var claudeTmpRoot: URL?

    public init(userHome: URL, darwinUserTemp: URL?, shell: String,
                canSeeSandboxes: @escaping @Sendable () -> Bool = { ContainmentSelfTest.passed }, claudeTmpRoot: URL? = nil) {
        self.userHome = userHome; self.darwinUserTemp = darwinUserTemp; self.shell = shell
        self.canSeeSandboxes = canSeeSandboxes; self.claudeTmpRoot = claudeTmpRoot
    }

    /// `current` with the owner's home from the account database (`getpwuid`), never `$HOME`: inside `brahma mcp` (an agent's
    /// child) `HOME` is the agent's. What grant checks use by default.
    public static var owner: SandboxEnvironment {
        var env = current
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            env.userHome = URL(fileURLWithPath: String(cString: dir), isDirectory: false)
        }
        return env
    }

    public static var current: SandboxEnvironment {
        #if canImport(Darwin)
        let temp = SandboxBaseline.darwinDirectory(_CS_DARWIN_USER_TEMP_DIR)
        #else
        let temp: URL? = nil
        #endif
        return SandboxEnvironment(userHome: FileManager.default.homeDirectoryForCurrentUser, darwinUserTemp: temp,
                                  shell: ShellPrefix.shell(), claudeTmpRoot: defaultClaudeTmpRoot)
    }

    /// `/private/tmp/b-<uid>` (`SandboxBaseline.defaultClaudeTmpRoot`).
    public static var defaultClaudeTmpRoot: URL { SandboxBaseline.defaultClaudeTmpRoot }
}

/// A sandboxed turn's prepared places.
struct SandboxedTurn: Sendable {
    var scope: SandboxScope
    var shellPrefix: URL
    /// The owner's grants compiled into `scope`; consumed only when the turn launches (`consumeSandboxGrants`).
    var grants: [Grant] = []
    /// The same scope with other grants (blocking): used when a grant was revoked or used up between preparing and launching.
    var rebuild: (@Sendable (GrantInputs) throws -> SandboxScope)? = nil
    /// The item the scope was built for.
    var item: WorkItem? = nil
    /// The turn's mach marker (`dev.brahma.turn.<id>`), compiled into its sandbox.
    var marker: String = ""
    /// The turn's kind (fix round 2, B-N4): a grant rebuild that fails repairs only what is the agent's own on this kind.
    var kind: TurnKind = .work
}

/// A turn that does not start because the agent's earlier turns are not accounted for (any profile): `earlier turn: <why>`.
struct EarlierTurnRefusal: Error, CustomStringConvertible {
    var reason: String
    var description: String { "earlier turn: \(reason)" }
}

/// A sandboxed turn that does not start (its scope was refused, or its places could not be made): `sandbox scope: <why>`.
struct SandboxRefusal: Error, CustomStringConvertible {
    var reason: String
    var description: String { "sandbox scope: \(reason)" }
}

extension Orchestrator {
    /// The profile a turn of `agent` runs under: its company's choice for its role (`Company.profile(forRole:)`, sandboxed by
    /// default), narrowed by the engine's ceiling (`brahma run --profile`), which never widens it.
    nonisolated func turnProfile(agent: Agent, company: Company) -> PermissionProfile {
        let chosen = company.profile(forRole: agent.role)
        return profileCeiling.map { PermissionProfile.narrower(chosen, $0) } ?? chosen
    }

    /// What a Workspace turn's settings deny reading and editing: the data home, the owner's protected paths and every other
    /// company's workspace, each as given and resolved. A company list that cannot be read fails the turn (M6). Task 10b
    /// (B-M9): the owner's `ext try` copies, and every extension review page that is not one `agent` pre-checks (the whole
    /// `ext-review` directory when it reviews none: a deny always beats an allow, so its own pages are never carved out of
    /// one). Workspace Bash is unsandboxed, so these are rules for Claude's file tools, not a wall.
    nonisolated func workspaceDeniedPaths(company: Company, agent: Agent) throws -> [URL] {
        let others = try store.companies().filter { $0.id != company.id }
            .map { URL(fileURLWithPath: $0.workspacePath, isDirectory: false) }
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: false)
        var extensionPlaces = [workspace.appending(path: ".brahma/ext-try")]
        let reviewDir = workspace.appending(path: ExtensionLibrary.reviewDir)
        let own = Set(try store.extensionReviewPages(reviewerId: agent.id))
        if own.isEmpty {
            extensionPlaces.append(reviewDir)
        } else {
            for name in try SandboxScope.listedEntries(reviewDir.resolvedForSandbox.path) where !own.contains("\(ExtensionLibrary.reviewDir)/\(name)") {
                extensionPlaces.append(reviewDir.appending(path: name))
            }
        }
        // Final review M4: the owner's backup folders and WAL replica too (a database error fails the turn).
        let backups = try BackupTargets.requiredProtectedFolders(store: store)
        var seen = Set<String>()
        return ([paths.home] + ProtectedPaths.defaults(userHome: sandboxEnvironment.userHome) + others + extensionPlaces + backups)
            .flatMap { [$0, $0.resolvedForSandbox] }
            .filter { seen.insert(SandboxPath.key($0.path)).inserted }
    }

    /// `<runDir>/turns`: where every turn's leader is recorded (`TurnRecords`).
    nonisolated var turnRecordDirectory: URL { paths.runDir.appending(path: "turns", directoryHint: .isDirectory) }

    /// Every turn, every profile, first (M1): waits until the agent's earlier turns are swept and kills what they, or an earlier
    /// engine's turns, left. What it killed is logged (M4); anything that would not die refuses the turn and tells the owner.
    nonisolated func settleEarlierTurns(agent: Agent, company: Company, turnId: String) async throws {
        let left: TurnLeftovers
        do {
            left = try await runner.waitForTurnProcesses(agentId: agent.id, records: turnRecordDirectory)
        } catch {
            // A deadline, a cancellation, or a record that could not be read (it is quarantined, so it cannot block the agent
            // forever): the owner hears of it once (fix round 2, B-N5).
            let what: String
            if let corrupt = error as? TurnRecords.Corrupt {
                what = "the record of its earlier turns (\(corrupt.path)) could not be read and was moved to \(corrupt.quarantinedTo); "
                    + "processes that turn left may still be running"
            } else {
                what = "its earlier turns' processes could not be accounted for (\(error))"
            }
            alertOnce(reason: "turn-wait:\(agent.id)", company: company, agent: agent, now: clock(),
                      text: "A turn of @\(agent.name) in \(company.name) did not start: \(what). Check `ps` for strays.")
            throw EarlierTurnRefusal(reason: what)
        }
        let now = clock()
        if !left.killed.isEmpty {
            attempt {
                try store.appendEvent(ActivityEvent(
                    companyId: company.id, agentId: agent.id, turnId: turnId, kind: .error,
                    text: "@\(agent.name): \(left.killed.count) process(es) left over from an earlier turn were killed "
                        + "(pid \(left.killed.map(String.init).joined(separator: ", ")))", createdAt: now))
            }
        }
        guard left.survivors.isEmpty else {
            let pids = left.survivors.map(String.init).joined(separator: ", ")
            alertOnce(reason: "turn-leftovers:\(agent.id)", company: company, agent: agent, now: now,
                      text: "@\(agent.name)'s turns do not start in \(company.name): processes of an earlier turn are still running "
                        + "and could not be killed, or could not be told apart (pid \(pids); -1: the process table could not be "
                        + "read; a pid may be an unrelated process the kernel could not classify). Check them (`ps -p \(pids)`).")
            throw EarlierTurnRefusal(reason: "processes of an earlier turn are still running (pid \(pids))")
        }
    }

    /// Raises an owner alert once while one with the same reason is open; afterwards only an activity line.
    nonisolated func alertOnce(reason: String, company: Company, agent: Agent, now: Date, text: String) {
        attempt {
            try store.writer.write { db in
                let open = try Ask.filter(Column("companyId") == company.id && Column("kind") == AskKind.engineAlert
                                          && Column("status") == AskStatus.pendingOwner.rawValue
                                          && Column("subjectId") == Store.engineAlertKey(reason)).fetchCount(db)
                if open == 0 {
                    try EngineAlerts.raise(store: store, db: db, text: text, now: now, reason: reason, scope: .company(company.id))
                } else {
                    try ActivityEvent(companyId: company.id, agentId: agent.id, turnId: nil, kind: .error, text: try store.redact(text),
                                      createdAt: now).insert(db)
                }
            }
        }
    }

    /// Before a sandboxed turn: no process of an earlier turn of the agent may still run; then (blocking) the agent's places
    /// (`layout.ensure()`), its Bash prefix (`ShellPrefix.write`) and the turn's scope (`SandboxScope.forTurn`, every other
    /// company's workspace protected, no backup targets until Task 13b). Workspace entries left out of the scope are
    /// logged. (No sweep of `<cwd>/.claude`: probe (c) showed project skills and agents do not load in a sandboxed turn.) A refused scope throws `SandboxRefusal`; a link in one of the agent's own places
    /// is removed (never followed) so its next turn can start, and the owner is told the path either way.
    /// `extraDomains`: the egress the turn's mounted extensions declare (`ExtensionLibrary.agentNetwork`, Task 5a), joined to the grants'.
    nonisolated func prepareSandbox(agent: Agent, company: Company, kind: TurnKind, item: WorkItem?, turnId: String,
                                    extraDomains: [String] = [], trialRoot: String? = nil) async throws -> SandboxedTurn {
        // The containment of a sandboxed turn finds its processes by their sandbox; blind, it could not (B-I2).
        let env = sandboxEnvironment
        guard await blocking.run({ env.canSeeSandboxes() }) else {
            // Retried after a backoff (`ContainmentSelfTest`); the owner hears of it once (fix round 2, B-N6).
            alertOnce(reason: "containment-self-test", company: company, agent: agent, now: clock(),
                      text: "Sandboxed turns in \(company.name) do not start: Brahma cannot see sandboxed processes on this Mac (its "
                        + "containment self-test failed), so it could not make sure nothing of a turn outlives it. It retries "
                        + "shortly; if this stays, run `brahma doctor`.")
            throw SandboxRefusal(reason: "cannot see sandboxed processes on this Mac (the containment self-test failed), so no "
                                 + "sandboxed turn starts")
        }
        let store = self.store, paths = self.paths, mcp = mcpExecutable
        let others = try store.companies().filter { $0.id != company.id }.map { URL(fileURLWithPath: $0.workspacePath, isDirectory: false) }
        let layout = SandboxLayout(paths: paths, company: company, agentHandle: agent.name, trialRoot: trialRoot)
        let now = clock()
        func event(_ text: String) {
            attempt {
                try store.appendEvent(ActivityEvent(companyId: company.id, agentId: agent.id, turnId: turnId, kind: .error,
                                                    text: text, createdAt: now))
            }
        }
        let turn: SandboxedTurn
        let droppedGrants: [(ref: String, state: Grants.PathState)]
        do {
            (turn, droppedGrants) = try await blocking.tryRun {
                // The owner's backup folders and WAL replica (Task 13b): protected and unreadable for every turn. Read in the
                // blocking body (INT-M1); a database error refuses the turn rather than leave the backups unprotected (INT-I1).
                let backups = try BackupTargets.requiredProtectedFolders(store: store)
                // The prefix's backstop, re-asserted before every sandboxed turn (M4).
                try Sentinel.write(paths: paths)
                try layout.ensure()
                // The Bash prefix scrubs secret-looking variables except the test keys this work turn gets (`use_secret`, Task
                // 4-wire): the same names the runner injects. Names only; a database error refuses the turn.
                let keep = kind == .work ? try item.map { try store.injectableSecretNames(agentId: agent.id, itemId: $0.id) } ?? [] : []
                let prefix = try ShellPrefix.write(layout: layout, paths: paths, shell: env.shell, keepNames: keep,
                                                   mcpServer: ShellPrefix.MCPServer(executable: mcp, database: paths.database.path,
                                                                                    companyId: company.id, agentId: agent.id,
                                                                                    ownerHome: env.userHome.path))
                // The owner's grants that apply to this turn (Task 9). A read path that no longer is what was approved (a link,
                // an alias or a file is where the directory was) is revoked and the owner told; one that is missing for now or
                // newly overlaps a protected place is only left out of this turn. The turn runs either way.
                var grants = try store.activeGrants(agent: agent, itemId: item?.id, kind: kind)
                var dropped: [(ref: String, state: Grants.PathState)] = []
                for g in grants {
                    let state = Grants.pathState(g, company: company, paths: paths, environment: env, otherWorkspaces: others,
                                                 backupTargets: backups)
                    guard state != .ok else { continue }
                    dropped.append((g.ref, state))
                    if state == .changed { try store.revokeChangedPathGrant(g, now: now) }
                }
                grants.removeAll { g in dropped.contains { $0.ref == g.ref } }
                // B-M9 (10b): the review pages of the extension asks this agent pre-checks; no other turn reads `ext-review`.
                let resolved = layout.workspace.resolvedForSandbox
                let reviewPages = kind == .work || kind == .notice || kind == .plan
                    ? try store.extensionReviewPages(reviewerId: agent.id).map { resolved.appending(path: $0) } : []
                let rebuild: @Sendable (GrantInputs) throws -> SandboxScope = { inputs in
                    var inputs = inputs
                    inputs.domains = Array(Set(inputs.domains + extraDomains)).sorted()
                    return try SandboxScope.forTurn(layout: layout, paths: paths, otherWorkspaces: others, backupTargets: backups,
                                                    kind: kind, item: item, company: company, grants: inputs,
                                                    darwinUserTemp: env.darwinUserTemp, userHome: env.userHome,
                                                    claudeTmpRoot: env.claudeTmpRoot, reviewPages: reviewPages)
                }
                let scope = try rebuild(GrantResolver.inputs(grants))
                if let tmp = scope.claudeTmp { try ClaudeTmp.ensure(tmp) }
                return (SandboxedTurn(scope: scope, shellPrefix: prefix, grants: grants, rebuild: rebuild, item: item,
                                      marker: TurnProfileCompiler.containmentMarkerPrefix + UUID().uuidString.lowercased(), kind: kind), dropped)
            }
        } catch {
            throw await sandboxRefusal(error, agent: agent, company: company, layout: layout, item: item, kind: kind, now: now)
        }
        for (ref, state) in droppedGrants {
            let why: String
            switch state {
            case .changed: why = "revoked: a link or alias is where the approved directory was"
            case .missing: why = "left out of this turn: the directory is missing"
            case .refused: why = "left out of this turn: the path now overlaps a protected place"
            case .ok: continue
            }
            event("@\(agent.name): read-path grant \(ref) \(why)")
        }
        if !turn.scope.skippedUnsafe.isEmpty {
            let names = turn.scope.skippedUnsafe.map { Store.flat(URL(fileURLWithPath: $0).lastPathComponent, max: 80) }
            event("@\(agent.name): \(names.count) workspace \(names.count == 1 ? "entry" : "entries") left out of the sandbox "
                  + "(names no sandbox profile may carry): \(names.prefix(10).joined(separator: ", "))")
        }
        return turn
    }

    /// When the turn launches (after the mode's no-launch checks): counts one use of each grant it got, all or nothing. A grant
    /// revoked or used up since `prepareSandbox` (another turn took a one-use grant) is left out and the scope rebuilt without
    /// it, so the turn neither refuses nor spends the others for nothing.
    /// A rebuild error is handled like `prepareSandbox`'s (`sandboxRefusal`).
    nonisolated func consumeSandboxGrants(_ turn: inout SandboxedTurn, agent: Agent, company: Company, item: WorkItem?,
                                          turnId: String) async throws {
        var grants = turn.grants
        while true {
            let lost = try store.consumeGrants(ids: grants.map(\.id), turnId: turnId, now: clock())
            if lost.isEmpty { break }
            grants.removeAll { lost.contains($0.id) }
            guard let rebuild = turn.rebuild else { throw SandboxRefusal(reason: "a grant changed while the turn was prepared") }
            let inputs = GrantResolver.inputs(grants)
            do {
                turn.scope = try await blocking.tryRun { try rebuild(inputs) }
            } catch {
                throw await sandboxRefusal(error, agent: agent, company: company,
                                           layout: SandboxLayout(paths: paths, company: company, agentHandle: agent.name),
                                           item: item, kind: turn.kind, now: clock())
            }
            turn.grants = grants
        }
    }

    /// What a scope that could not be built becomes: a link or an odd entry in one of the agent's own places is repaired (B-I4,
    /// `repairOwnPlace`) and the owner told what was there; the turn does not start (`SandboxRefusal`).
    nonisolated func sandboxRefusal(_ error: any Error, agent: Agent, company: Company, layout: SandboxLayout, item: WorkItem?,
                                    kind: TurnKind, now: Date) async -> SandboxRefusal {
        if let refusal = error as? SandboxRefusal { return refusal }
        let problem: (path: String, what: String)?
        switch error {
        case SandboxError.linkedPath(let path): problem = (path, "is a symbolic link")
        case let refused as UnsafeEngineFile: problem = (refused.path, refused.problem)
        default: problem = nil
        }
        if let problem {
            // Only a work or plan turn's own item places count as the agent's (M10).
            let own = kind == .work || kind == .notice || kind == .plan ? item : nil
            let repaired = await blocking.run { Self.repairOwnPlace(problem.path, layout: layout, item: own, plan: kind == .plan) }
            notePlaceProblem(problem.path, what: problem.what, agent: agent, company: company, repaired: repaired, now: now)
        }
        if let refusal = error as? SandboxError { return SandboxRefusal(reason: refusal.description) }
        return SandboxRefusal(reason: "the agent's places could not be prepared: \(error)")
    }

    /// The agent's own places (B-I4): its home and lab subtrees, its notes file, and on its own item turns the progress file
    /// (and on a plan turn the plan directory). When `path` lies at or below one of them, what is at `path` is removed if it is
    /// a link (never followed) or else moved into the engine-only `.brahma/trash/<h>/` (nothing is lost), and the places are
    /// recreated. Returns whether it did. Blocking.
    nonisolated static func repairOwnPlace(_ path: String, layout: SandboxLayout, item: WorkItem?, plan: Bool = false) -> Bool {
        var own = [layout.homeRelative, layout.labRelative, layout.notesRelative]
        if let key = item?.key {
            own.append(".brahma/progress/\(key).md")
            if plan { own.append(".brahma/plans/\(key)") }
        }
        let ws = layout.workspace.resolvedForSandbox
        let roots = [layout.workspace, ws]
        // `path` as a path under the resolved workspace, whichever spelling reported it.
        guard let relative = roots.lazy.compactMap({ root -> String? in
            let base = SandboxPath.key(root.path) + "/", p = SandboxPath.key(path)
            return p.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
        }).first else { return false }
        guard own.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) else { return false }
        let target = ws.appending(path: relative)
        let removal: EngineFiles.Removal?
        switch SandboxPath.kind(target.path) {
        case .missing:
            removal = nil
        case .link:
            removal = try? EngineFiles.removeNoFollow(target, under: ws)
        default:
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let name = "\(stamp)-\(UUID().uuidString.prefix(8))-\(target.lastPathComponent)"
            removal = try? EngineFiles.moveNoFollow(target, under: ws, toDirectory: layout.trashRelative, name: name)
        }
        guard case .removed? = removal else { return false }
        try? layout.ensure()
        return true
    }

    /// The owner hears of an odd entry where the sandbox expects one of a turn's real places, once per path while that alert is
    /// open (`alertOnce`), in the words of the actual problem.
    nonisolated func notePlaceProblem(_ path: String, what: String, agent: Agent, company: Company, repaired: Bool, now: Date) {
        let text = "A turn of @\(agent.name) in \(company.name) did not start: \(Store.flat(path, max: 400)) \(Store.flat(what, max: 200)) "
            + "where the sandbox expects a real file or directory. "
            + (repaired ? "It was in one of the agent's own places: Brahma repaired it (a link removed, not what it pointed to; "
                          + "anything else moved to .brahma/trash/\(agent.name)), so the next turn starts normally."
                        : "Brahma did not touch it. Check what put it there, then replace it with the real file or directory.")
        alertOnce(reason: "sandbox-link:\(company.id):\(StableHash.fnv1a64(path))", company: company, agent: agent, now: now, text: text)
    }
}

/// The private directory a sandboxed agent's claude keeps its temp files in (`SandboxScope.claudeTmp`): it and its root are
/// created 0700 without following a link; a root that is not this user's own directory refuses the turn.
enum ClaudeTmp {
    static func ensure(_ dir: URL) throws {
        let root = dir.deletingLastPathComponent()
        try EngineFiles.directory(workspace: root.deletingLastPathComponent(), root.lastPathComponent, mode: 0o700)
        try EngineFiles.directory(workspace: root, dir.lastPathComponent, mode: 0o700)
        var st = stat()
        guard lstat(root.path, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else {
            throw UnsafeEngineFile(path: root.path, problem: "is not this user's private directory")
        }
    }
}
