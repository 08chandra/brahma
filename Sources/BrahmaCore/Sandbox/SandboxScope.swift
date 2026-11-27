import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// The sandbox is the structural wall between an agent's turn and the owner's data, the engine's database and files, the
// common git dir and the other agents. This file computes what one turn may touch (`SandboxScope.forTurn`); Task 1b
// compiles it into the Claude Code sandbox settings and Task 2 into the Seatbelt policy for checks.

// MARK: Layout

/// Where one agent's sandboxed turns live inside its company's workspace. Paths are as the workspace path names them;
/// `SandboxScope.forTurn` resolves only the workspace itself and builds every own place logically under it (never resolved:
/// a link at or above one refuses the turn).
public struct SandboxLayout: Equatable, Sendable {
    public let handle: String
    public let companySlug: String
    public let workspace: URL
    /// `<ws>/.brahma`.
    public let dotBrahma: URL
    /// `.brahma/home/<h>`: the agent's `HOME`.
    public let agentHome: URL
    /// `.brahma/labs/<h>`: the agent's scratch repository (cwd of itemless, review and audit turns).
    public let lab: URL
    /// `.brahma/home/<h>/cache`: inside the agent's home, so `.brahma/cache` itself can be write-denied (5L-2).
    public let agentCache: URL
    /// `.brahma/cache/shared`: written only by engine-run checks; read-only to agents.
    public let sharedCache: URL
    /// `.brahma/ext`: mounted extension plugin parts, read-only to agents.
    public let extLib: URL
    /// `.brahma/hooks`.
    public let hooksDir: URL
    /// `.brahma/bin/shell-<h>.sh`: the agent's Bash prefix (Task 1b).
    public let shellPrefix: URL
    /// `.brahma/notes/agents/<h>.md`: the agent's own notes file (team notes stay `.brahma/notes/<team>.md`, engine-written).
    public let notes: URL
    /// `<ws>/.git`: the common git dir.
    public let gitDir: URL
    /// An `ext try` turn's own root (Task 10b, S29: `.brahma/ext-try/<id>`): its home, lab, notes and shell prefix live there,
    /// never in the per-agent directories, so a trial's clean-up and sweep can never touch a real agent's places. Nil for agents.
    public let trialRoot: String?

    /// Workspace-relative places: `.brahma/home/<h>`, `.brahma/labs/<h>`, `.brahma/notes/agents/<h>.md`,
    /// `.brahma/bin/shell-<h>.sh` and `.brahma/trash/<h>`; for a trial `<root>/home`, `<root>/lab`, `<root>/notes/<h>.md`,
    /// `<root>/bin/shell-<h>.sh` and `<root>/trash`.
    public var homeRelative: String { trialRoot.map { "\($0)/home" } ?? ".brahma/home/\(handle)" }
    public var labRelative: String { trialRoot.map { "\($0)/lab" } ?? ".brahma/labs/\(handle)" }
    public var notesDirRelative: String { trialRoot.map { "\($0)/notes" } ?? ".brahma/notes/agents" }
    public var notesRelative: String { "\(notesDirRelative)/\(handle).md" }
    public var binDirRelative: String { trialRoot.map { "\($0)/bin" } ?? ".brahma/bin" }
    public var shellPrefixRelative: String { "\(binDirRelative)/shell-\(handle).sh" }
    public var trashRelative: String { trialRoot.map { "\($0)/trash" } ?? ".brahma/trash/\(handle)" }

    public init(paths: BrahmaPaths, company: Company, agentHandle: String, trialRoot: String? = nil) {
        handle = agentHandle
        companySlug = company.slug
        self.trialRoot = trialRoot
        workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: false)
        dotBrahma = workspace.appending(path: ".brahma")
        let root = trialRoot
        agentHome = workspace.appending(path: root.map { "\($0)/home" } ?? ".brahma/home/\(agentHandle)")
        lab = workspace.appending(path: root.map { "\($0)/lab" } ?? ".brahma/labs/\(agentHandle)")
        agentCache = agentHome.appending(path: "cache")
        sharedCache = dotBrahma.appending(path: "cache/shared")
        extLib = dotBrahma.appending(path: "ext")
        hooksDir = dotBrahma.appending(path: "hooks")
        shellPrefix = workspace.appending(path: (root.map { "\($0)/bin" } ?? ".brahma/bin") + "/shell-\(agentHandle).sh")
        notes = workspace.appending(path: (root.map { "\($0)/notes" } ?? ".brahma/notes/agents") + "/\(agentHandle).md")
        gitDir = workspace.appending(path: ".git")
    }

    /// `.brahma/plans/<KEY>`: 3a's plan-turn directory (`Orchestrator.planDirectory`), the plan turn's cwd and `plansDirectory`.
    public func plansDir(_ key: String) -> URL { dotBrahma.appending(path: "plans/\(key)") }

    /// A handle is one safe path component: 3a's handle alphabet (`Store.hire`).
    static func validate(handle: String) throws {
        guard handle.range(of: "^[a-z0-9][a-z0-9_-]{0,31}$", options: .regularExpression) != nil
        else { throw SandboxError.invalidHandle(handle) }
    }

    /// Creates the agent's places (blocking: run it in a `Blocking` body). Every part under the workspace is walked without
    /// following a link (`EngineFiles`); a link or odd file in the way throws and nothing is written through it.
    /// - `home/<h>`, `home/<h>/cache` and `labs/<h>` at 0700;
    /// - `home/<h>/.gitconfig` (rewritten every time): `user.name <h>`, `user.email <h>@<slug>.brahma.local`;
    /// - `.git/refs/heads/item/` and `.git/logs/refs/heads/item/`, so the item turn's own ref, lock and reflog can be created;
    /// - an empty `notes/agents/<h>.md` (0600) when missing (an existing one is kept);
    /// - the lab as its own repository (`GitWorkspace.initStandaloneRepository`: `git init --template= -b main`) when it has none.
    public func ensure() throws {
        try Self.validate(handle: handle)
        // The workspace must already be a repository: creating `.git/refs/...` in a workspace without one would leave a
        // `.git` directory that `GitWorkspace.ensureRepo` then takes for a repository.
        guard SandboxPath.kind(gitDir.path) == .directory else {
            throw UnsafeEngineFile(path: gitDir.path, problem: "is not a real directory (the workspace has no repository)")
        }
        let ws = workspace
        try EngineFiles.directory(workspace: ws, homeRelative, mode: 0o700)
        try EngineFiles.directory(workspace: ws, "\(homeRelative)/cache", mode: 0o700)
        try EngineFiles.directory(workspace: ws, labRelative, mode: 0o700)
        let gitconfig = "[user]\n\tname = \(handle)\n\temail = \(handle)@\(companySlug).brahma.local\n"
        try EngineFiles.replace(Data(gitconfig.utf8), workspace: ws, dir: homeRelative, name: ".gitconfig", mode: 0o600)
        try EngineFiles.directory(workspace: ws, ".git/refs/heads/item")
        try EngineFiles.directory(workspace: ws, ".git/logs/refs/heads/item")
        if trialRoot != nil { _ = try EngineFiles.directory(workspace: ws, notesDirRelative, mode: 0o700) }
        switch try EngineFiles.entry(workspace: ws, dir: notesDirRelative, name: "\(handle).md") {
        case .regular: break
        case .missing: _ = try EngineFiles.create(Data(), workspace: ws, dir: notesDirRelative, name: "\(handle).md", mode: 0o600)
        case .unsafe(let problem): throw problem
        }
        try ensureLabRepository()
    }

    private func ensureLabRepository() throws {
        let dotGit = lab.appending(path: ".git")
        switch SandboxPath.kind(dotGit.path) {
        case .directory: return
        case .missing: break
        default: throw UnsafeEngineFile(path: dotGit.path, problem: "is not a real directory")
        }
        // The lab directory was just walked without links; git creates `.git` inside it.
        try GitWorkspace.initStandaloneRepository(at: lab)
        guard SandboxPath.kind(dotGit.path) == .directory else {
            throw UnsafeEngineFile(path: dotGit.path, problem: "was not created as a real directory")
        }
    }
}

// MARK: Network

public struct NetworkScope: Equatable, Sendable {
    /// Bash egress (the proxy's allow-list).
    public var allowedDomains: [String]
    /// WebFetch.
    public var webDomains: [String]
    public var allowLocalBinding: Bool

    public init(allowedDomains: [String], webDomains: [String], allowLocalBinding: Bool) {
        self.allowedDomains = allowedDomains; self.webDomains = webDomains; self.allowLocalBinding = allowLocalBinding
    }
}

public enum CompanyNetwork {
    public static let defaultRegistries = [
        "registry.npmjs.org", "registry.yarnpkg.com", "pypi.org", "files.pythonhosted.org", "crates.io", "index.crates.io",
        "static.crates.io", "proxy.golang.org", "sum.golang.org", "rubygems.org", "repo.maven.apache.org", "repo1.maven.org",
        "github.com", "codeload.github.com", "objects.githubusercontent.com",
    ]
    public static let defaultDocs = [
        "developer.apple.com", "docs.swift.org", "swift.org", "developer.mozilla.org", "nodejs.org", "docs.python.org", "docs.rs",
        "pkg.go.dev",
    ]

    /// Bash domains = registries ∪ owner-added ∪ grants; web domains = registries ∪ docs ∪ owner-added web ∪ web grants.
    /// Lowercased (a trailing dot dropped), deduped, sorted. Not validated here: `SandboxScope.validate` refuses a forbidden
    /// or invalid domain.
    public static func scope(company: Company, grantDomains: [String], grantWebDomains: [String]) -> NetworkScope {
        func set(_ lists: [String]...) -> [String] { Array(Set(lists.joined().map(SandboxDomains.normalize))).sorted() }
        return NetworkScope(allowedDomains: set(defaultRegistries, company.allowedDomains, grantDomains),
                            webDomains: set(defaultRegistries, defaultDocs, company.webDomains, grantWebDomains),
                            allowLocalBinding: company.allowLocalBinding)
    }
}

// MARK: Grants

/// What the owner's grants add to a turn (Task 9 fills it; empty until then).
public struct GrantInputs: Equatable, Sendable {
    public var domains: [String] = []
    public var webDomains: [String] = []
    public var readPaths: [URL] = []
    /// `"<publisher>/<id>"`.
    public var extensions: [String] = []

    public init(domains: [String] = [], webDomains: [String] = [], readPaths: [URL] = [], extensions: [String] = []) {
        self.domains = domains; self.webDomains = webDomains; self.readPaths = readPaths; self.extensions = extensions
    }
}

// MARK: Scope

/// What one turn may touch. `workspace` is resolved; `cwd`, `writable` and the turn's own `readable` places are built
/// logically under it and are link-free when computed (a link at or above one refuses the turn, `.linkedPath`; re-checked
/// right before spawn, `recheckBeforeSpawn`). Owner-chosen read paths are resolved. Deny entries come in both forms, as
/// built and resolved (a deny on a link holds for the link and for what it names). Writes are allowed only to `cwd` and
/// `writable`, minus `denyWrite` (a deny inside an allowed directory wins); reads are denied in `denyRead`, except `readable`.
public struct SandboxScope: Equatable, Sendable {
    /// The company workspace every writable entry must lie in.
    public var workspace: URL
    public var cwd: URL
    public var writable: [URL]
    public var readable: [URL]
    public var readOnlyDirs: [URL]
    public var denyRead: [URL]
    public var denyWrite: [URL]
    public var protected: [URL]
    public var network: NetworkScope
    /// The per-user Darwin temp dir xcrun writes (`confstr(_CS_DARWIN_USER_TEMP_DIR)`): the one writable place outside the
    /// workspace, a documented residual.
    public var toolchainTempWrite: URL?
    /// Top-level workspace entries left out of `readable` because their names hold characters no sandbox profile may carry;
    /// the caller logs them (one activity line), the turn still runs.
    public var skippedUnsafe: [String] = []
    /// The read-only places that come from the owner's grants (`readOnlyDirs` holds them too): re-pinned right before spawn.
    public var grantReadDirs: [URL] = []
    /// `<claudeTmpRoot>/<6 hex of the agent's place>`: the turn's claude keeps its temp files (its Bash `TMPDIR`) here
    /// (`CLAUDE_CODE_TMPDIR`), not in the shared `/tmp/claude-<uid>` the owner's own sessions use. Outside the workspace, so
    /// it is not a `writable` entry: the compiler grants it like `toolchainTempWrite`. Every agent's sibling is unreadable
    /// (the root is in `denyRead`).
    public var claudeTmp: URL? = nil

    /// Claude Code 2.1.312 uses `CLAUDE_CODE_TMPDIR` only when its path is at most this long (probed live: 33 bytes worked,
    /// 35 fell back to `/tmp/claude-<uid>`); the engine's own form is `/private/tmp/b-<uid>/<6 hex>`.
    public static let claudeTmpMaxLength = 33

    public init(workspace: URL, cwd: URL, writable: [URL], readable: [URL], readOnlyDirs: [URL], denyRead: [URL],
                denyWrite: [URL], protected: [URL], network: NetworkScope, toolchainTempWrite: URL?) {
        self.workspace = workspace; self.cwd = cwd; self.writable = writable; self.readable = readable
        self.readOnlyDirs = readOnlyDirs; self.denyRead = denyRead; self.denyWrite = denyWrite; self.protected = protected
        self.network = network; self.toolchainTempWrite = toolchainTempWrite
    }

    /// The roots every turn is denied reading that no allowed entry may equal or contain (`denyRead` minus the other
    /// workspaces, backups and protected paths, which are checked as protected).
    private var deniedRoots: [URL] { denyRead.filter { d in !protected.contains(d) } }

    /// Throws when:
    /// - any path holds `'`, `"`, `\`, a control character, DEL or `%00` (`.unsafePathCharacter`), or is not absolute
    ///   (`.invalidPath`);
    /// - a `cwd`, `writable`, `readable`, `readOnlyDirs` (or `toolchainTempWrite`) entry equals, contains or lies inside a
    ///   `protected` entry, or equals or contains one of the denied roots (`.overlapsProtected`);
    /// - a writable entry (or `cwd`) is outside the workspace (`.writableOutsideCompany`; `toolchainTempWrite` is exempt);
    /// - a domain is Anthropic's (`.forbiddenDomain`) or not a valid pattern (`.invalidDomain`).
    public func validate() throws {
        let all = [workspace, cwd] + writable + readable + readOnlyDirs + denyRead + denyWrite + protected
            + (toolchainTempWrite.map { [$0] } ?? [])
        for url in all {
            if SandboxPath.isUnsafe(url.path) { throw SandboxError.unsafePathCharacter(url.path) }
            if !url.path.hasPrefix("/") { throw SandboxError.invalidPath(url.path) }
        }
        let allowed = [cwd] + writable + readable + readOnlyDirs + (toolchainTempWrite.map { [$0] } ?? [])
        let identities = (SandboxPath.IdentityRoots(protected), SandboxPath.IdentityRoots(deniedRoots))
        for entry in allowed {
            try SandboxPath.checkAllowed(entry, protected: protected, deniedRoots: deniedRoots, byIdentity: identities)
        }
        for entry in [cwd] + writable where !SandboxPath.isInside(entry.path, workspace.path) {
            throw SandboxError.writableOutsideCompany(path: entry.path)
        }
        for domain in network.allowedDomains + network.webDomains { try SandboxDomains.check(domain) }
    }

    /// Right before the turn's process starts (the scope may be some time old by then): the link walk again over `cwd` and
    /// every writable entry, `cwd` a real directory whose resolved path is `cwd` itself (the process is started in it, and a
    /// directory opened through a link would be the link's target), then `validate()`. A process of the agent's that outlived
    /// an earlier turn is gone by now (the runner sweeps every turn), so what this sees is what the turn starts with.
    /// `recheckBeforeSpawn`, first dropping every grant read path that is no longer pinned (`SandboxPath.isPinnedDirectory`:
    /// a link or alias was put in its place since the scope was computed). A dropped grant is not mounted this turn (the
    /// next turn's check revokes it); the turn is not refused for it. Returns the dropped paths.
    public mutating func recheckBeforeSpawnDroppingGrants() throws -> [URL] {
        let dropped = grantReadDirs.filter { !SandboxPath.isPinnedDirectory($0.path) }
        if !dropped.isEmpty {
            let gone = Set(dropped.map { SandboxPath.key($0.path) })
            readOnlyDirs.removeAll { gone.contains(SandboxPath.key($0.path)) }
            readable.removeAll { gone.contains(SandboxPath.key($0.path)) }
            grantReadDirs.removeAll { gone.contains(SandboxPath.key($0.path)) }
        }
        try recheckBeforeSpawn()
        return dropped
    }

    public func recheckBeforeSpawn() throws {
        for url in [cwd] + writable {
            if let hit = SandboxPath.linkedComponent(url.path, under: workspace.path) { throw SandboxError.linkedPath(hit) }
        }
        guard SandboxPath.kind(cwd.path) == .directory else { throw SandboxError.invalidPath(cwd.path) }
        guard SandboxPath.key(SandboxPath.resolve(cwd.path)) == SandboxPath.key(cwd.path) else { throw SandboxError.linkedPath(cwd.path) }
        try validate()
    }

    /// The `.brahma` children every turn may read (`SeatbeltProfile.readableDotBrahma`: the Seatbelt render re-allows the same set).
    static let readableDotBrahma = SeatbeltProfile.readableDotBrahma

    /// Engine-only `.brahma` places (3a, L, 4a), write-denied on every turn even before they exist. `preview` is Plan L's
    /// (`EngineLayout.previewDir`; its runs are data-home exports, its logs are written by the engine only).
    static let engineOnlyDotBrahma = ["trash", "cache", "resources", "checks", "wt-check", "handoffs", "releases", "artifacts",
                                      "wt/.preview", "wt/.release", "wt/.merge", "ext", "ext-review", "ext-try", "hooks", "bin", "kb",
                                      "preview"]

    /// Common-git-dir internals no turn writes (3a "GitCommand hardening I2": config or attributes flipped between the
    /// engine's scan and its run), listed even before they exist.
    static let gitInternals = ["config", "config.worktree", "hooks", "info", "objects/info", "packed-refs", "HEAD", "ORIG_HEAD",
                               "FETCH_HEAD", "MERGE_HEAD", "index", "commondir", "gitdir", "shallow", "modules", "logs/HEAD",
                               "refs/heads/main", "logs/refs/heads/main", "refs/tags", "refs/remotes", "refs/notes",
                               "refs/replace", "refs/stash", "refs/original", "refs/bisect", "refs/prefetch", "logs/refs/stash"]

    private enum Shape {
        case item(String), itemless, review(String?), audit, plan(String)
    }

    /// The scope of one turn of the agent `layout` describes. `otherWorkspaces` is every other company's workspace;
    /// `backupTargets` the owner's backup folders and WAL replica (`BackupTargets.protectedFolders`); `darwinUserTemp` the xcrun temp dir.
    /// `userHome` is the owner's home (the process's by default; tests pass a temp dir). `reviewPages` are the extension review
    /// pages (`<ws>/.brahma/ext-review/A-<n>.md`) this agent is the internal reviewer of (10b, B-M9): each is readable on this
    /// turn only when it is a real file below the workspace; no other turn reads `ext-review`.
    ///
    /// - Item turn (`work`/`notice` with an item): cwd = the item worktree; writes to the agent's home, lab and cache, the
    ///   common git dir's objects, the item's admin dir, ref, ref lock and reflog, its progress file and the agent's notes.
    /// - Itemless turn (and every `show` turn, Plan C Task C4c): cwd = lab; writes to home, lab, cache and notes.
    /// - Review / audit: cwd = lab; writes to home and lab; a review also reads the worktree (read-only).
    /// - Plan (needs an item; without one it gets the audit scope): cwd = `plansDir(KEY)`; writes to home and that directory;
    ///   reads the worktree (read-only).
    public static func forTurn(layout: SandboxLayout, paths: BrahmaPaths, otherWorkspaces: [URL], backupTargets: [URL],
                               kind: TurnKind, item: WorkItem?, company: Company, grants: GrantInputs, darwinUserTemp: URL?,
                               userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                               claudeTmpRoot: URL? = nil, reviewPages: [URL] = []) throws -> SandboxScope {
        try SandboxLayout.validate(handle: layout.handle)
        if let key = item?.key, key.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) == nil {
            throw SandboxError.invalidPath(key)
        }
        // Raw inputs first: resolution would otherwise read a path cut at a NUL.
        let raws = [layout.workspace, paths.home, userHome] + otherWorkspaces + backupTargets + grants.readPaths
            + (darwinUserTemp.map { [$0] } ?? [])
        for url in raws {
            if SandboxPath.isUnsafe(url.path) { throw SandboxError.unsafePathCharacter(url.path) }
            if !url.path.hasPrefix("/") { throw SandboxError.invalidPath(url.path) }
        }
        let toolchain = try company.toolchainReadPaths.map { try SandboxPath.expand($0, userHome: userHome) }

        func r(_ url: URL) -> URL { url.resolvedForSandbox }
        // Paths are resolved for deny lists and owner-chosen places; the workspace itself may sit behind a link the owner chose.
        let ws = r(layout.workspace)
        let dataHome = r(paths.home)
        if SandboxPath.isInside(dataHome.path, ws.path) { throw SandboxError.dataHomeInsideWorkspace(dataHome.path) }
        /// Both the path as built and its resolved form: a deny on a link must hold for the link and for what it names.
        func both(_ url: URL) -> [URL] { [url, r(url)] }

        // What the turn runs in, writes, or reads of its own is built logically under the resolved workspace, never resolved:
        // an agent can replace any of its writable places with a link, and following one would grant whatever it names. A
        // link at or above such a place (below the workspace) refuses the turn.
        func l(_ relative: String) -> URL { ws.appending(path: relative) }
        func checked(_ url: URL) throws -> URL {
            if let hit = SandboxPath.linkedComponent(url.path, under: ws.path) { throw SandboxError.linkedPath(hit) }
            return url
        }
        func own(_ relative: String) throws -> URL { try checked(l(relative)) }
        let h = layout.handle
        let dot = l(".brahma")
        let git = l(".git")
        let home = try own(layout.homeRelative)
        let lab = try own(layout.labRelative)
        let notes = try own(layout.notesRelative)
        let shellPrefix = try own(layout.shellPrefixRelative)
        let cache = try own("\(layout.homeRelative)/cache")
        // 3a's item worktree (`GitWorkspace.worktreePath`: `<ws>/.brahma/wt/<KEY>`).
        func worktree(_ key: String) throws -> URL { try own(".brahma/wt/\(key)") }

        let shape: Shape
        switch kind {
        case .work, .notice: shape = item.map { .item($0.key) } ?? .itemless
        case .review: shape = .review(item?.key)
        case .audit: shape = .audit
        case .plan: shape = item.map { .plan($0.key) } ?? .audit
        // Plan C Task C4c: a show turn is itemless whatever the agent holds: the lab, never a worktree.
        case .show: shape = .itemless
        }

        let cwd: URL
        var writable: [URL]
        var readOnly: [URL] = []
        switch shape {
        case .item(let key):
            cwd = try worktree(key)
            writable = [home, lab, cache, try own(".git/objects"), try own(".git/worktrees/\(key)"),
                        try own(".git/refs/heads/item/\(key)"), try own(".git/refs/heads/item/\(key).lock"),
                        try own(".git/logs/refs/heads/item/\(key)"), try checked(ProgressFile.path(workspace: ws, key: key)), notes]
        case .itemless:
            cwd = lab
            writable = [home, lab, cache, notes]
        case .review(let key):
            cwd = lab
            writable = [home, lab]
            if let key { readOnly.append(try worktree(key)) }
        case .audit:
            // Audit digests quote merged diffs; no worktree is mounted.
            cwd = lab
            writable = [home, lab]
        case .plan(let key):
            // 3a's plan directory (`Orchestrator.planDirectory`, `layout.plansDir`), built under the resolved workspace.
            cwd = try own(".brahma/plans/\(key)")
            writable = [home, cwd]
            readOnly.append(try worktree(key))
        }

        // Protected and denied (each in both forms).
        var protected = ProtectedPaths.defaults(userHome: userHome).flatMap(both) + both(paths.home)
        protected += otherWorkspaces.flatMap(both) + backupTargets.flatMap(both)
        protected = dedupe(protected)
        // The per-user Darwin folder (`/private/var/folders/<a>/<b>`, which holds T, C and 0: every app's temporary files) is
        // unreadable like the home, except the toolchain's own entries below (the turn-side twin of Task 2 A-I1).
        let darwinUserDir = darwinUserTemp.flatMap { $0.lastPathComponent == "T" ? r($0).deletingLastPathComponent() : nil }
        // Claude Code's shared temp places: the owner's own sessions' outputs live there (same uid).
        let claudeShared = ["claude-\(getuid())", "claude-tool-results"].flatMap { name in
            ["/private/tmp/\(name)", "/tmp/\(name)"].map { URL(fileURLWithPath: $0, isDirectory: false) }
        }
        let tmpRoot = claudeTmpRoot.map(r)
        // Final review I2: the Claude temp places and every agent's private temp root (the default one whatever this scope's
        // is) are denied roots too, so no grant or toolchain read path may equal or contain them (a read allowance would
        // otherwise win over their read deny).
        let deniedRoots = dedupe(both(userHome) + both(paths.home) + both(URL(fileURLWithPath: "/Volumes", isDirectory: false))
                                 + both(dot) + (darwinUserDir.map(both) ?? []) + claudeShared + (tmpRoot.map(both) ?? [])
                                 + both(SandboxEnvironment.defaultClaudeTmpRoot))
        let denyRead = dedupe(deniedRoots + protected)

        // Read paths the owner or a grant added are checked whether or not they exist yet; only existing ones are mounted.
        // None may reach into `.brahma` (other agents' labs, homes and notes, the engine's files).
        // A grant's path is used as stored, and only while it is pinned (`SandboxPath.isPinnedDirectory`: it resolves to itself
        // through real directories only); one that no longer is (a link or alias was put in its place) is left out of the turn,
        // never followed and never a reason to refuse the turn.
        let grantReads = grants.readPaths.filter { SandboxPath.isPinnedDirectory($0.path) }
        let extraReads = toolchain.map(r) + grantReads
        // Nor into the Claude temp places or any agent's private temp directory (final review I2): inside them, not only
        // equal to or containing them.
        let claudeTemps = claudeShared + (tmpRoot.map(both) ?? []) + both(SandboxEnvironment.defaultClaudeTmpRoot)
        for path in extraReads {
            try SandboxPath.checkAllowed(path, protected: protected + both(dot) + claudeTemps, deniedRoots: deniedRoots)
        }
        let existingExtra = extraReads.filter { SandboxPath.kind($0.path) != .missing }

        // Readable, by enumeration (5L-1), recomputed every turn. A top-level link is not followed into a re-allowed read (its
        // target keeps its own rules); a name no profile may carry is left out and reported, never fatal.
        var readable: [URL] = []
        var skipped: [String] = []
        for name in SandboxPath.entries(ws.path) where name != ".brahma" {
            let entry = l(name)
            if SandboxPath.isUnsafe(name) { skipped.append(entry.path); continue }
            guard SandboxPath.kind(entry.path) != .link else { continue }
            readable.append(entry)
        }
        // Engine places, mounted only when they are real (no link at or above them).
        func engineChild(_ child: String) -> URL? {
            let url = l(".brahma/\(child)")
            let kind = SandboxPath.kind(url.path)
            guard kind == .directory || kind == .file, SandboxPath.linkedComponent(url.path, under: ws.path) == nil else { return nil }
            return url
        }
        readable += readableDotBrahma.compactMap(engineChild)
        // The review pages of the asks this agent pre-checks (B-M9): exactly those files, real and unlinked, never the directory.
        for page in reviewPages {
            let parts = page.pathComponents.suffix(3)
            guard parts.count == 3, Array(parts.prefix(2)) == [".brahma", "ext-review"],
                  let name = parts.last, name.range(of: "^A-[0-9]{1,9}\\.md$", options: .regularExpression) != nil,
                  let url = engineChild("ext-review/\(name)"), SandboxPath.kind(url.path) == .file else { continue }
            readable.append(url)
        }
        readable += [home, lab, notes, shellPrefix]
        readable += existingExtra
        if let darwinUserDir {
            // What the toolchain reads in the Darwin folder: xcrun's cache, Foundation's atomic-write staging (SwiftPM,
            // xcodebuild; Claude's settings take paths, not Task 2's exact name patterns: a documented residual), Xcode's
            // cached build specifications.
            readable += ["T/xcrun_db", "T/TemporaryItems", "C/com.apple.DeveloperTools"].map { darwinUserDir.appending(path: $0) }
        }
        // Whatever the turn runs in or writes it can read.
        readable += [cwd] + writable

        for child in ["resources/company", "kb"] {
            if let url = engineChild(child), SandboxPath.kind(url.path) == .directory { readOnly.append(url) }
        }
        readOnly += grantReads.filter { SandboxPath.kind($0.path) != .missing }
        readOnly = dedupe(readOnly)
        readable = dedupe(readable + readOnly)

        // Write denials.
        var denyWrite = protected
        denyWrite += [cwd.appending(path: ".claude"), cwd.appending(path: ".mcp.json"), lab.appending(path: ".claude"),
                      lab.appending(path: ".mcp.json")].flatMap(both)
        // A trial (S29) writes its own `.brahma/ext-try/<id>/{home,lab,notes}`: every other trial, and its own plugin copy and
        // shell prefix, stay write-denied.
        let trialId = layout.trialRoot.map { URL(fileURLWithPath: $0).lastPathComponent }
        denyWrite += engineOnlyDotBrahma.filter { trialId == nil || $0 != "ext-try" }.map { l(".brahma/\($0)") }.flatMap(both)
        if let root = layout.trialRoot, let trialId {
            try denyEntries(of: l(".brahma/ext-try"), keeping: [trialId], carveOut: true)
            denyWrite += [l("\(root)/plugin"), l(layout.binDirRelative)].flatMap(both)
        }
        var ownKey: String?
        if case .item(let key) = shape { ownKey = key }
        // Every existing entry of `dir` but the turn's own, plus the whole directory when the turn has no carve-out there. A
        // name no profile may carry denies the whole directory instead; where the turn's own carve-out shares it, only this
        // turn is refused.
        func denyEntries(of dir: URL, keeping keep: Set<String>, carveOut: Bool) throws {
            let names = SandboxPath.entries(dir.path).filter { !keep.contains($0) }
            if !carveOut { denyWrite += both(dir) }
            if let bad = names.first(where: SandboxPath.isUnsafe) {
                if carveOut { throw SandboxError.unsafePathCharacter(dir.appending(path: bad).path) }
                return
            }
            for name in names { denyWrite += both(dir.appending(path: name)) }
        }
        func denySiblings(_ relative: String, keeping own: String?) throws {
            try denyEntries(of: l(".brahma/\(relative)"), keeping: own.map { [$0] } ?? [], carveOut: own != nil)
        }
        let writesNotes = writable.contains(notes) && layout.trialRoot == nil
        let agentPlaces = layout.trialRoot == nil
        try denySiblings("notes", keeping: writesNotes ? "agents" : nil)
        try denySiblings("notes/agents", keeping: writesNotes ? "\(h).md" : nil)
        try denySiblings("home", keeping: agentPlaces ? h : nil)
        try denySiblings("labs", keeping: agentPlaces ? h : nil)
        try denySiblings("progress", keeping: ownKey.map { "\($0).md" })
        try denySiblings("wt", keeping: ownKey)
        if case .plan(let key) = shape { try denySiblings("plans", keeping: key) } else { try denySiblings("plans", keeping: nil) }
        // The common git dir.
        denyWrite += gitInternals.map { l(".git/\($0)") }.flatMap(both)
        if let key = item?.key {
            denyWrite += ["config.worktree", "commondir", "gitdir"].map { l(".git/worktrees/\(key)/\($0)") }.flatMap(both)
        }
        try denyEntries(of: l(".git/worktrees"), keeping: ownKey.map { [$0] } ?? [], carveOut: ownKey != nil)
        for dir in [".git/refs/heads/item", ".git/logs/refs/heads/item"] {
            try denyEntries(of: l(dir), keeping: ownKey.map { [$0, "\($0).lock"] } ?? [], carveOut: ownKey != nil)
        }
        if case .item = shape {
            // The worktree's link to its admin dir.
            denyWrite += both(cwd.appending(path: ".git"))
        } else {
            // A turn without an item writes nothing in the common git dir.
            denyWrite += both(git)
        }
        // Claude Code's shared temp places (its default write grant has them): never written by a turn either, so it cannot
        // plant files the owner's own sessions later read (fix round 2, B-N3).
        denyWrite += claudeShared + ["/private/tmp/claude", "/tmp/claude"].map { URL(fileURLWithPath: $0, isDirectory: false) }
        denyWrite = dedupe(denyWrite)

        let network = CompanyNetwork.scope(company: company, grantDomains: grants.domains, grantWebDomains: grants.webDomains)
        var scope = SandboxScope(workspace: ws, cwd: cwd, writable: writable, readable: readable, readOnlyDirs: readOnly,
                                 denyRead: denyRead, denyWrite: denyWrite, protected: protected, network: network,
                                 toolchainTempWrite: darwinUserTemp.map(r))
        scope.skippedUnsafe = skipped
        scope.grantReadDirs = grantReads
        if let tmpRoot {
            let tmp = tmpRoot.appending(path: String(StableHash.fnv1a64(SandboxPath.key(ws.path) + "\u{0}" + h).prefix(6)))
            guard tmp.path.utf8.count <= claudeTmpMaxLength else {
                throw SandboxError.invalidPath("\(tmp.path) is too long for Claude Code's temp directory (\(claudeTmpMaxLength) bytes)")
            }
            try SandboxPath.checkAllowed(tmp, protected: protected, deniedRoots: deniedRoots)
            scope.claudeTmp = tmp
        }
        try scope.validate()
        return scope
    }

    private static func dedupe(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert(SandboxPath.key($0.path)).inserted }
    }
}

// MARK: Engine bridges to the kernel

extension SandboxBaseline {
    /// `current(engineHome:otherWorkspaces:backupTargets:)` with `paths.home` as the engine home.
    public static func current(paths: BrahmaPaths, otherWorkspaces: [URL], backupTargets: [URL]) -> SandboxBaseline {
        current(engineHome: paths.home, otherWorkspaces: otherWorkspaces, backupTargets: backupTargets)
    }
}
