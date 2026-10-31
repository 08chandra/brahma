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

    public init(userHome: URL, darwinUserTemp: URL?, shell: String) {
        self.userHome = userHome; self.darwinUserTemp = darwinUserTemp; self.shell = shell
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
                                  shell: ShellPrefix.shell())
    }
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
    /// company's workspace.
    nonisolated func workspaceDeniedPaths(company: Company) -> [URL] {
        let others = ((try? store.companies()) ?? []).filter { $0.id != company.id }
            .map { URL(fileURLWithPath: $0.workspacePath, isDirectory: false) }
        return [paths.home] + ProtectedPaths.defaults(userHome: sandboxEnvironment.userHome) + others
    }

    /// Before a sandboxed turn: no process of an earlier turn of the agent may still run; then (blocking) the agent's places
    /// (`layout.ensure()`), its Bash prefix (`ShellPrefix.write`) and the turn's scope (`SandboxScope.forTurn`, every other
    /// company's workspace protected, no backup targets until Task 13b). Workspace entries left out of the scope are
    /// logged. (No sweep of `<cwd>/.claude`: probe (c) showed project skills and agents do not load in a sandboxed turn.) A refused scope throws `SandboxRefusal`; a link in one of the agent's own places
    /// is removed (never followed) so its next turn can start, and the owner is told the path either way.
    /// `extraDomains`: the egress the turn's mounted extensions declare (`ExtensionLibrary.agentNetwork`, Task 5a), joined to the grants'.
    nonisolated func prepareSandbox(agent: Agent, company: Company, kind: TurnKind, item: WorkItem?, turnId: String,
                                    extraDomains: [String] = []) async throws -> SandboxedTurn {
        let left = await runner.waitForTurnProcesses(agentId: agent.id)
        if !left.isEmpty {
            throw SandboxRefusal(reason: "processes of an earlier turn are still running (pid \(left.map(String.init).joined(separator: ", ")))")
        }
        let store = self.store, paths = self.paths, env = sandboxEnvironment, mcp = mcpExecutable
        let others = try store.companies().filter { $0.id != company.id }.map { URL(fileURLWithPath: $0.workspacePath, isDirectory: false) }
        let layout = SandboxLayout(paths: paths, company: company, agentHandle: agent.name)
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
                try layout.ensure()
                let prefix = try ShellPrefix.write(layout: layout, paths: paths, shell: env.shell, keepNames: [], mcpExecutable: mcp)
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
                let rebuild: @Sendable (GrantInputs) throws -> SandboxScope = { inputs in
                    var inputs = inputs
                    inputs.domains = Array(Set(inputs.domains + extraDomains)).sorted()
                    return try SandboxScope.forTurn(layout: layout, paths: paths, otherWorkspaces: others, backupTargets: backups,
                                                    kind: kind, item: item, company: company, grants: inputs,
                                                    darwinUserTemp: env.darwinUserTemp, userHome: env.userHome)
                }
                let scope = try rebuild(GrantResolver.inputs(grants))
                return (SandboxedTurn(scope: scope, shellPrefix: prefix, grants: grants, rebuild: rebuild, item: item), dropped)
            }
        } catch {
            throw await sandboxRefusal(error, agent: agent, company: company, layout: layout, item: item, now: now)
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
                                           item: item, now: clock())
            }
            turn.grants = grants
        }
    }

    /// What a scope that could not be built becomes: a link in one of the agent's own places is removed (never followed) and
    /// the owner told; the turn does not start (`SandboxRefusal`).
    nonisolated func sandboxRefusal(_ error: any Error, agent: Agent, company: Company, layout: SandboxLayout, item: WorkItem?,
                                    now: Date) async -> SandboxRefusal {
        if let refusal = error as? SandboxRefusal { return refusal }
        let linked: String?
        switch error {
        case SandboxError.linkedPath(let path): linked = path
        case let refused as UnsafeEngineFile: linked = refused.path
        default: linked = nil
        }
        if let linked {
            let repaired = await blocking.run { Self.repairOwnPlace(linked, layout: layout, item: item) }
            noteLinkedPlace(linked, agent: agent, company: company, repaired: repaired, now: now)
        }
        if let refusal = error as? SandboxError { return SandboxRefusal(reason: refusal.description) }
        return SandboxRefusal(reason: "the agent's places could not be prepared: \(error)")
    }

    /// When `path` is one of the agent's own places (its home, cache, lab or notes, or the turn's progress file), removes the
    /// link there (never what it names) and recreates the places. Returns whether it did. Blocking.
    nonisolated static func repairOwnPlace(_ path: String, layout: SandboxLayout, item: WorkItem?) -> Bool {
        let h = layout.handle
        var own = [".brahma/home/\(h)", ".brahma/home/\(h)/cache", ".brahma/labs/\(h)", ".brahma/notes/agents/\(h).md"]
        if let key = item?.key { own.append(".brahma/progress/\(key).md") }
        let roots = [layout.workspace, layout.workspace.resolvedForSandbox]
        guard let relative = own.first(where: { rel in roots.contains { SandboxPath.key($0.appending(path: rel).path) == SandboxPath.key(path) } })
        else { return false }
        let ws = layout.workspace.resolvedForSandbox
        guard SandboxPath.kind(ws.appending(path: relative).path) == .link else { return false }
        guard case .removed? = try? EngineFiles.removeNoFollow(ws.appending(path: relative), under: ws) else { return false }
        try? layout.ensure()
        return true
    }

    /// The owner hears of a link where the sandbox expects one of a turn's real places, once per path while that alert is open.
    nonisolated func noteLinkedPlace(_ path: String, agent: Agent, company: Company, repaired: Bool, now: Date) {
        let reason = "sandbox-link:\(company.id):\(StableHash.fnv1a64(path))"
        let text = "A turn of @\(agent.name) in \(company.name) did not start: \(Store.flat(path, max: 400)) is a symbolic link where "
            + "the sandbox expects a real file or directory. "
            + (repaired ? "It was one of the agent's own places: Brahma removed the link (not what it pointed to) and recreated the "
                          + "place, so the next turn starts normally."
                        : "Brahma did not touch it. Check what put it there, then replace the link with the real file or directory.")
        attempt {
            try store.writer.write { db in
                let open = try Ask.filter(Column("companyId") == company.id && Column("kind") == AskKind.engineAlert
                                          && Column("status") == AskStatus.pendingOwner.rawValue
                                          && Column("subjectId") == Store.engineAlertKey(reason)).fetchCount(db)
                if open == 0 {
                    try EngineAlerts.raise(store: store, db: db, text: text, now: now, reason: reason, companyId: company.id)
                } else {
                    try ActivityEvent(companyId: company.id, agentId: agent.id, turnId: nil, kind: .error, text: try store.redact(text),
                                      createdAt: now).insert(db)
                }
            }
        }
    }
}
