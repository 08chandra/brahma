import Foundation

// Brahma's own extensions (Task 10b), publisher `brahma`: Swift literals, materialized read-only into each company workspace at
// engine start (and `brahma company create`) as `<ws>/.brahma/ext/<id>/<hash12>/plugin/`, and verified against the tree hash
// pinned here before every mount. They are never rows in `companyExtension`: nobody proposes, installs or removes them, and
// no other extension may take their ids.

/// One built-in extension: its plugin files (relative path → text, every file 0644) and the pinned `ExtensionLock` tree hash.
public struct BuiltinExtension: Sendable {
    public let id: String
    public let version: String
    public let files: [String: String]
    public let pinnedHash: String

    /// The lock entries of `files`, as `ExtensionLock.entries` lists a materialized copy (sorted by path, mode 0644).
    public var entries: [ExtensionLock.FileEntry] {
        files.keys.sorted().map { ExtensionLock.FileEntry(path: $0, mode: "0644", sha256: SHA256.hex(Data(files[$0]!.utf8))) }
    }

    /// The hash of the literal files (equal to `pinnedHash` unless someone edited a literal without re-pinning it).
    public var computedHash: String { ExtensionLock.treeHash(entries: entries) }
}

public enum BuiltinExtensions {
    public static let authoringId = "extension-authoring"
    public static let workersId = "brahma-workers"
    /// The Task 14u probe gate that proves only `brahma-workers` agents load on a sandboxed Task turn.
    public static let f7Gate = "F7-agents"
    /// What the CLI's init `agents` must equal with only `brahma-workers` mounted under `--restricted` (gate F7-agents).
    public static let workersInitAgents = ["brahma-workers:brahma-reader"]
    static let disableBuiltinAgentsVariable = "CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS"

    public static var all: [BuiltinExtension] { [authoring, workers] }
    public static var ids: Set<String> { Set(all.map(\.id)) }

    /// The environment a Task turn mounting `brahma-workers` gets: the CLI's built-in agent types switched off, but only once
    /// the F7-agents gate passed for this CLI build and shape (Task 14u wires the gate). Until then nothing is emitted and the
    /// Task 1b rule stays: a Task turn has no web tools.
    public static func agentEnvironment(f7AgentsPassed: Bool) -> [String: String] {
        f7AgentsPassed ? [disableBuiltinAgentsVariable: "1"] : [:]
    }

    static func manifest(_ id: String, _ description: String) -> String {
        """
        {
          "author" : {
            "name" : "Brahma"
          },
          "description" : "\(description)",
          "name" : "\(id)",
          "version" : "1.0.0"
        }

        """
    }

    // MARK: extension-authoring

    public static let authoring = BuiltinExtension(
        id: authoringId, version: "1.0.0",
        files: [
            ExtensionManifest.path: manifest(authoringId, "How to build a Brahma skill extension in your lab and hand it to the owner."),
            "skills/extension-authoring/SKILL.md": """
                ---
                name: extension-authoring
                description: Build a skill extension (a Claude Code plugin folder) in your lab, lint it until clean, and propose it to the owner with propose_extension.
                when_to_use: When the team keeps repeating the same procedure, tone or checklist and a reusable skill would help. Not for one-off notes; write those in your notes file.
                ---
                # Building an extension

                An extension is a plain Claude Code plugin folder that holds skills. You build it in your lab, the linter checks it, and you
                hand it to your technical lead and then the owner with `propose_extension`. Nothing you build is mounted on any turn
                before the owner approves it.

                ## The format

                - `.claude-plugin/plugin.json` holds exactly four keys: `name` (the id), `version`, `description` and `author`.
                  Any other key is refused.
                - The id is lowercase letters, digits and dashes, starting with a letter, at most 40 characters.
                - `skills/<name>/SKILL.md` per skill. Its frontmatter is `name` (the folder name), `description` and `when_to_use`;
                  the description says what the skill does and when to use it, in at most 1,024 characters.
                - Long rules and examples go in `skills/<name>/reference/*.md`; keep SKILL.md short and point at them.
                - Optional `commands/` and `agents/` Markdown files follow the same frontmatter rules.
                - Optional `bin/` helpers: plain scripts, mode 0755, each named `<id>-<tool>`.
                - Optional `assets/` for data files; assets are not mounted in this release, so a skill must not depend on them.

                ## The trust rules

                - No hooks: no `hooks/` folder, no `hooks` key anywhere, no hook frontmatter.
                - No MCP or LSP servers and no `settings.json`.
                - No install scripts of any kind (`package.json` scripts, `setup.py`, `install.sh`, a Makefile) and no `node_modules/`.
                - No binaries outside `assets/`, no symbolic links, no hidden or bidirectional Unicode.
                - No secrets, no credential paths, and no network hosts the folder does not declare.
                - `allowed-tools` and `model` in frontmatter are stripped; agent `tools` may only name tools your role already has.

                ## The loop

                1. In your lab: `brahma ext new skill <id>` writes the template into `./<id>`.
                2. Write the skill. Keep each instruction concrete and checkable.
                3. Run `brahma ext lint --json <id>` and fix every entry it lists. `brahma ext lint --fix <id>` applies the mechanical
                   fixes. Repeat until the list is `[]`.
                4. Commit the folder in your lab with plain git (`git add <id>` then `git commit -m "<id>"`, each on its own).
                5. End your turn. A commit is recorded when the turn that made it ends; propose in a later turn.

                ## The hand-off

                Call `propose_extension` with `path` (the folder in your lab), a one-line `summary`, the `roles` it suits, and the
                `item` it came from if there is one. Brahma snapshots the folder at your lab's last commit, lints it again, checks
                where its content came from, and files an ask: your technical lead pre-checks it, then the owner decides. Content
                from a session that read outside content, or from a commit not recorded yet, goes straight to the owner instead.
                Only committed work is proposed, so commit first. If lint is not clean you get the list back and no ask is filed.

                """,
        ],
        pinnedHash: "2f4705aa08f36f1172fe5aead0ac7bf317245d41779806772c2a46f459626305")

    // MARK: brahma-workers (F7)

    public static let workers = BuiltinExtension(
        id: workersId, version: "1.0.0",
        files: [
            ExtensionManifest.path: manifest(workersId, "Brahma's own sub-agent types for sandboxed Task turns."),
            "agents/brahma-reader.md": """
                ---
                name: brahma-reader
                description: Reads and searches the code and files a task names, runs read-only commands, and reports what it found. Never edits and never reaches the web.
                tools: [Read, Bash, Skill]
                disallowedTools: [WebFetch, WebSearch, Agent]
                ---
                You read. Look at exactly what the task asks for: files, logs, command output. Use Bash only for read-only commands
                (listing, searching, running tests that change nothing). Report what you found, with paths and line numbers, and
                say plainly what you could not find. Do not edit files, do not start other agents, and do not try to reach the network.

                """,
        ],
        pinnedHash: "70384f6dd07cc0c570c2fc8fe0136bf72457a2328e1c57ab63168c4ebf648442")

    // MARK: Materialize and mount

    /// `<ws>/.brahma/ext/<id>/<hash12>/plugin`.
    public static func pluginDir(_ builtin: BuiltinExtension, workspace: URL) -> URL {
        workspace.appending(path: relativeDir(builtin), directoryHint: .isDirectory)
    }

    static func relativeDir(_ builtin: BuiltinExtension) -> String { ".brahma/ext/\(builtin.id)/\(builtin.pinnedHash.prefix(12))/plugin" }

    /// Writes every built-in into the workspace (read-only, through `EngineFiles`, never following a link) unless its copy
    /// already hashes as pinned; a copy that does not is replaced. A literal that does not hash as pinned is never written.
    /// Blocking.
    public static func materialize(workspace: URL) throws {
        for builtin in all {
            guard builtin.computedHash == builtin.pinnedHash else {
                throw ExtensionError.message("the built-in \(builtin.id) does not hash as pinned; it was not materialized")
            }
            let dir = pluginDir(builtin, workspace: workspace)
            if SandboxPath.kind(dir.path) == .directory, (try? ExtensionLock.treeHash(root: dir)) == builtin.pinnedHash { continue }
            if SandboxPath.kind(dir.path) != .missing {
                ExtensionLibrary.makeWritable(dir)
                _ = try EngineFiles.removeNoFollow(dir, under: workspace)
            }
            let relative = relativeDir(builtin)
            _ = try EngineFiles.directory(workspace: workspace, relative)
            for path in builtin.files.keys.sorted() {
                let parts = path.split(separator: "/").map(String.init)
                let sub = relative + (parts.count > 1 ? "/" + parts.dropLast().joined(separator: "/") : "")
                _ = try EngineFiles.directory(workspace: workspace, sub)
                _ = try EngineFiles.replace(Data(builtin.files[path]!.utf8), workspace: workspace, dir: sub, name: parts.last!, mode: 0o444)
            }
            guard try ExtensionLock.treeHash(root: dir) == builtin.pinnedHash else {
                throw ExtensionError.message("the materialized \(builtin.id) does not hash as pinned")
            }
        }
    }

    /// The built-ins a turn mounts: `extension-authoring` on itemless work and notice turns (cwd = the lab when Sandboxed) of
    /// every role in the software pack, on every profile. Only a copy that is a real directory below the workspace and hashes as
    /// pinned is mounted; one that does not is materialized again first (it is Brahma's own), and left out if it still does not.
    /// Nothing is mounted where the built-ins were never materialized. Blocking.
    static func mounts(company: Company, role: String, kind: TurnKind, itemScoped: Bool, store: Store) -> [ExtensionMount] {
        guard kind == .work || kind == .notice, !itemScoped, company.packId == "software",
              store.catalog.pack("software")?.role(role) != nil else { return [] }
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        guard let mount = verifiedMount(authoring, workspace: workspace) else { return [] }
        return [mount]
    }

    /// The `brahma-workers` mount for a sandboxed Task turn (Task 14u decides when): verified like `extension-authoring`.
    public static func workersMount(workspace: URL) -> ExtensionMount? { verifiedMount(workers, workspace: workspace) }

    static func verifiedMount(_ builtin: BuiltinExtension, workspace: URL) -> ExtensionMount? {
        let resolved = workspace.resolvedForSandbox.path
        let real = URL(fileURLWithPath: resolved).appending(path: relativeDir(builtin), directoryHint: .notDirectory)
        // Never materialized here (an engine that has not started, a workspace made since): not mounted.
        guard SandboxPath.kind(real.path) != .missing else { return nil }
        func ok() -> Bool {
            SandboxPath.linkedComponent(real.path, under: resolved) == nil && RehashCache.verify(real, expected: builtin.pinnedHash)
        }
        if !ok() {
            guard (try? materialize(workspace: workspace)) != nil, ok() else { return nil }
        }
        return ExtensionMount(id: builtin.id, hash: builtin.pinnedHash, url: pluginDir(builtin, workspace: workspace),
                              publisher: ExtensionPublisher.brahma, agentNetwork: [])
    }
}
