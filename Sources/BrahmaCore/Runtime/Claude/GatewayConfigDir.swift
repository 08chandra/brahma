import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Plan X1 Ruling 63 (X1-39): the gateway turn's `CLAUDE_CONFIG_DIR`. Persistent per agent (Ruling 62 keeps `--resume`), so it
// lives in the engine's private run area — `<data home>/run/gateway-config/<agentId>`, beside the engine's other per-agent
// state (`run/taint/<agentId>`) — never under the agent home, a worktree, the agent's Claude temp dir or any other place a
// sandboxed turn can write. The data home is a protected root of every sandboxed turn (denyRead, denyWrite and the Read/Edit
// deny rules), and `ClaudeGatewayCompile.settings` names this dir in the deny lists again.
//
// Before every gateway turn the launcher (Task 14) calls `prepare`: the dir must be a real directory owned by the engine user,
// no component below the data home may be a link, and it may hold only the CLI's own state. Anything else (settings, hooks,
// agents, commands, plugins, skills, output styles, a CLAUDE.md, an .mcp.json, a link, an unknown name) gets the dir moved to
// the quarantine area and a fresh empty one started (so a fresh session), with an engine alert.
//
// Nothing here fails open (`GatewayFailOpenLintTests` covers `Runtime/`): no `try?`, no `?? true` / `?? false`, no empty `catch`.

public enum GatewayConfigDir {
    /// What `claude` itself keeps in its config dir: the only names `prepare` accepts. Kept tight on purpose; a name the CLI
    /// starts writing that is not here costs a quarantine (a fresh session and an alert), never an unchecked file.
    public static let cliDirectories: Set<String> = [
        "projects", "todos", "statsig", "shell-snapshots", "session-env", "file-history", "plans", "debug", "paste-cache", "cache",
        "telemetry", "backups",
    ]
    public static let cliFiles: Set<String> = [".claude.json", "history.jsonl"]
    /// The CLI's own backups and atomic-write temporaries of its state file.
    public static let cliFilePrefixes = [".claude.json.backup", ".claude.json.tmp"]

    /// The reason keying the engine alert of a quarantine.
    public static let alertReason = EngineAlerts.gatewayConfigReason

    public struct Prepared: Equatable, Sendable {
        /// The dir to hand to the turn (`GatewayLaunch.configDir`): empty when it was just made.
        public var url: URL
        /// Where the previous dir went, when it was quarantined: the agent's next turn must start a fresh session.
        public var quarantined: URL?
        /// What was found there, for the alert.
        public var reason: String?

        public var needsFreshSession: Bool { quarantined != nil }
    }

    /// Why `prepare` refused (the turn must not start): a link in the path, a component that is not a directory or not the
    /// engine user's, an id that is not one path component, or a filesystem failure.
    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public let reason: String
        public var description: String { "gateway config dir: \(reason)" }
    }

    /// The data home as the filesystem resolves it (the owner's choice, outside every sandbox), so no component of what is
    /// below it can be a link the engine follows.
    static func resolvedHome(_ paths: BrahmaPaths) throws(Refusal) -> URL {
        guard let real = realpath(paths.home.path, nil) else { throw Refusal(reason: "the data home cannot be resolved (errno \(errno))") }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }

    /// `<resolved data home>/run/gateway-config/<agentId>`.
    public static func directory(paths: BrahmaPaths, agentId: String) throws(Refusal) -> URL {
        guard TaintFlag.isSafeId(agentId) else { throw Refusal(reason: "agent id \(agentId.prefix(80)) is not one path component") }
        return try resolvedHome(paths).appending(path: "run/gateway-config/\(agentId)", directoryHint: .isDirectory)
    }

    /// `<resolved data home>/run/gateway-config-quarantine`.
    public static func quarantineArea(paths: BrahmaPaths) throws(Refusal) -> URL {
        try resolvedHome(paths).appending(path: "run/gateway-config-quarantine", directoryHint: .isDirectory)
    }

    /// The agent's dir, checked (or made, empty, 0700): see the file comment. `alert` gets the text of a quarantine (the
    /// production one is `prepare(paths:agent:store:now:)`'s engine alert); a failed alert does not undo the quarantine.
    /// Throws `Refusal` when the turn must not start.
    public static func prepare(paths: BrahmaPaths, agentId: String, agentName: String? = nil, now: Date = Date(),
                               alert: (String) throws -> Void) throws(Refusal) -> Prepared {
        let home = try resolvedHome(paths)
        let dir = try directory(paths: paths, agentId: agentId)
        let quarantine = try quarantineArea(paths: paths)
        for place in [home.appending(path: "run"), dir.deletingLastPathComponent(), quarantine] {
            try ensurePrivateDirectory(place, under: home)
        }
        try requireRealDirectories(from: home, to: dir.deletingLastPathComponent())
        var st = stat()
        if lstat(dir.path, &st) != 0 {
            guard errno == ENOENT else { throw Refusal(reason: "cannot examine \(dir.path) (errno \(errno))") }
            try makePrivateDirectory(dir)
            return Prepared(url: dir, quarantined: nil, reason: nil)
        }
        try requireOwnDirectory(st, dir)
        let found = try unexpectedEntries(in: dir)
        guard !found.isEmpty else { return Prepared(url: dir, quarantined: nil, reason: nil) }
        let stamp = Int(now.timeIntervalSince1970)
        let moved = quarantine.appending(path: "\(agentId)-\(stamp)-\(UUID().uuidString.prefix(8).lowercased())", directoryHint: .isDirectory)
        guard rename(dir.path, moved.path) == 0 else {
            throw Refusal(reason: "cannot move \(dir.path) to quarantine (errno \(errno))")
        }
        try makePrivateDirectory(dir)
        let reason = found.prefix(8).joined(separator: ", ") + (found.count > 8 ? ", …" : "")
        let who = agentName.map { "@\($0)" } ?? "agent \(agentId)"
        do {
            try alert("The gateway config dir of \(who) held \(reason), which is not Claude Code's own state. It was moved to "
                      + "\(moved.path) and \(who) starts a fresh session. Something wrote into the engine's run area; check it.")
        } catch {
            // The quarantine stands whatever the alert did; its failure rides in `reason` for the caller to log.
            return Prepared(url: dir, quarantined: moved, reason: reason + " (alert not written: \(error))")
        }
        return Prepared(url: dir, quarantined: moved, reason: reason)
    }

    /// `prepare` with the engine alert for the agent's company (`EngineAlerts.raise`, reason `alertReason`).
    public static func prepare(paths: BrahmaPaths, agent: Agent, store: Store, now: Date = Date()) throws(Refusal) -> Prepared {
        try prepare(paths: paths, agentId: agent.id, agentName: agent.name, now: now) { text in
            try EngineAlerts.raise(store: store, text: text, now: now, reason: alertReason, companyId: agent.companyId)
        }
    }

    /// The names in `dir` that are not the CLI's own state, sorted: an unknown name, a link, or anything but a regular file or
    /// a directory.
    static func unexpectedEntries(in dir: URL) throws(Refusal) -> [String] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        } catch {
            throw Refusal(reason: "cannot list \(dir.path): \(error)")
        }
        var found: [String] = []
        for name in names.sorted() {
            var st = stat()
            guard lstat(dir.appending(path: name).path, &st) == 0 else { found.append(name); continue }
            let kind = st.st_mode & S_IFMT
            let known = (kind == S_IFDIR && cliDirectories.contains(name))
                || (kind == S_IFREG && (cliFiles.contains(name) || cliFilePrefixes.contains { name.hasPrefix($0) }))
            if !known { found.append(kind == S_IFLNK ? "\(name) (a link)" : name) }
        }
        return found
    }

    /// Every component from `home` (exclusive) to `leaf` (inclusive) is a real directory (never a link) owned by this user.
    /// Paths are taken as written (never standardized, which on macOS swaps `/private/var` for the link `/var`).
    static func requireRealDirectories(from home: URL, to leaf: URL) throws(Refusal) {
        let base = home.path.count > 1 && home.path.hasSuffix("/") ? String(home.path.dropLast()) : home.path
        let target = leaf.path.count > 1 && leaf.path.hasSuffix("/") ? String(leaf.path.dropLast()) : leaf.path
        guard target == base || target.hasPrefix(base + "/") else { throw Refusal(reason: "\(target) is outside the data home") }
        var current = URL(fileURLWithPath: base, isDirectory: true)
        for part in target.dropFirst(base.count).split(separator: "/") {
            guard part != ".", part != ".." else { throw Refusal(reason: "\(target) has a . or .. component") }
            current = current.appending(path: String(part), directoryHint: .isDirectory)
            var st = stat()
            guard lstat(current.path, &st) == 0 else { throw Refusal(reason: "cannot examine \(current.path) (errno \(errno))") }
            try requireOwnDirectory(st, current)
        }
    }

    static func requireOwnDirectory(_ st: stat, _ url: URL) throws(Refusal) {
        let kind = st.st_mode & S_IFMT
        if kind == S_IFLNK { throw Refusal(reason: "\(url.path) is a link") }
        guard kind == S_IFDIR else { throw Refusal(reason: "\(url.path) is not a directory") }
        guard st.st_uid == geteuid() else { throw Refusal(reason: "\(url.path) is not owned by the engine's user") }
    }

    /// `url` as a 0700 directory, made when missing; a link or a non-directory there is refused (never followed).
    static func ensurePrivateDirectory(_ url: URL, under home: URL) throws(Refusal) {
        var st = stat()
        if lstat(url.path, &st) == 0 {
            try requireOwnDirectory(st, url)
            return
        }
        guard errno == ENOENT else { throw Refusal(reason: "cannot examine \(url.path) (errno \(errno))") }
        try requireRealDirectories(from: home, to: url.deletingLastPathComponent())
        try makePrivateDirectory(url)
    }

    /// `mkdir(url, 0700)`: fails on anything already there, a link included.
    static func makePrivateDirectory(_ url: URL) throws(Refusal) {
        guard mkdir(url.path, 0o700) == 0 else { throw Refusal(reason: "cannot make \(url.path) (errno \(errno))") }
        guard chmod(url.path, 0o700) == 0 else { throw Refusal(reason: "cannot restrict \(url.path) (errno \(errno))") }
    }
}
