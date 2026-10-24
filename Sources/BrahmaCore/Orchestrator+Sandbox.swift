import Foundation
import GRDB

/// What the engine needs from the owner's machine to compute sandbox scopes: the owner's home (protected paths), the Darwin
/// per-user temp dir xcrun writes, and the shell the agent's Bash prefix execs. Tests pass their own.
public struct SandboxEnvironment: Sendable {
    public var userHome: URL
    public var darwinUserTemp: URL?
    public var shell: String

    public init(userHome: URL, darwinUserTemp: URL?, shell: String) {
        self.userHome = userHome; self.darwinUserTemp = darwinUserTemp; self.shell = shell
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
    nonisolated func prepareSandbox(agent: Agent, company: Company, kind: TurnKind, item: WorkItem?, turnId: String) async throws -> SandboxedTurn {
        let left = await runner.waitForTurnProcesses(agentId: agent.id)
        if !left.isEmpty {
            throw SandboxRefusal(reason: "processes of an earlier turn are still running (pid \(left.map(String.init).joined(separator: ", ")))")
        }
        let store = self.store, paths = self.paths, env = sandboxEnvironment, mcp = mcpExecutable
        let others = try store.companies().filter { $0.id != company.id }.map { URL(fileURLWithPath: $0.workspacePath, isDirectory: false) }
        // The owner's backup folders and WAL replica (Task 13b): protected and unreadable for every turn.
        let backups = BackupTargets.protectedFolders(store: store)
        let layout = SandboxLayout(paths: paths, company: company, agentHandle: agent.name)
        let now = clock()
        func event(_ text: String) {
            attempt {
                try store.appendEvent(ActivityEvent(companyId: company.id, agentId: agent.id, turnId: turnId, kind: .error,
                                                    text: text, createdAt: now))
            }
        }
        let turn: SandboxedTurn
        do {
            turn = try await blocking.tryRun {
                try layout.ensure()
                let prefix = try ShellPrefix.write(layout: layout, paths: paths, shell: env.shell, keepNames: [], mcpExecutable: mcp)
                let scope = try SandboxScope.forTurn(layout: layout, paths: paths, otherWorkspaces: others, backupTargets: backups,
                                                     kind: kind, item: item, company: company, grants: GrantInputs(),
                                                     darwinUserTemp: env.darwinUserTemp, userHome: env.userHome)
                return SandboxedTurn(scope: scope, shellPrefix: prefix)
            }
        } catch {
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
            if let refusal = error as? SandboxError { throw SandboxRefusal(reason: refusal.description) }
            throw SandboxRefusal(reason: "the agent's places could not be prepared: \(error)")
        }
        if !turn.scope.skippedUnsafe.isEmpty {
            let names = turn.scope.skippedUnsafe.map { Store.flat(URL(fileURLWithPath: $0).lastPathComponent, max: 80) }
            event("@\(agent.name): \(names.count) workspace \(names.count == 1 ? "entry" : "entries") left out of the sandbox "
                  + "(names no sandbox profile may carry): \(names.prefix(10).joined(separator: ", "))")
        }
        return turn
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
