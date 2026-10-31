import Foundation

/// The embedded `skill` template (`brahma ext new skill <id>`): written straight to a directory, never through `claude plugin
/// init` (which writes into `~/.claude/skills`). Agents may run it in their lab.
public enum ExtensionTemplates {
    public struct File: Equatable, Sendable {
        public var path: String
        public var content: String
        public var executable: Bool
    }

    public static func skill(id: String, withBin: Bool) -> [File] {
        var files = [
            File(path: ExtensionManifest.path, content: """
            {
              "author" : {
                "name" : "Your name"
              },
              "description" : "One sentence: what \(id) does and when to use it.",
              "name" : "\(id)",
              "version" : "0.1.0"
            }

            """, executable: false),
            File(path: "skills/\(id)/SKILL.md", content: """
            ---
            name: \(id)
            description: One sentence on what this skill does and the situations it is for (the model reads this to decide).
            when_to_use: Name the task shapes that should trigger it, and the ones that should not.
            ---
            # \(id)

            1. Read reference/guide.md for the rules.
            2. Do the work in small steps; check each against the guide.
            3. Report what you did and what you checked in your hand-off.

            """, executable: false),
            File(path: "skills/\(id)/reference/guide.md", content: """
            # \(id): guide

            Put the rules, examples and before/after pairs the skill relies on here. Keep SKILL.md short and point at this file.

            """, executable: false),
            File(path: "tests/cases/basic.yaml", content: """
            # Deterministic cases for `brahma ext test` (a later Brahma release runs them; keep them honest meanwhile).
            - name: basic
              input: "A short task that should trigger \(id)."
              expect:
                mentions: ["reference/guide.md"]

            """, executable: false),
            File(path: "README.md", content: """
            # \(id)

            A Brahma skill extension: a valid Claude Code plugin folder with a 4-key `.claude-plugin/plugin.json`.

            - Lint it: `brahma ext lint .` (`--fix` strips disallowed frontmatter, prefixes `bin/` names and writes `ext.lock.json`).
            - Hooks, MCP servers, LSP servers, install scripts and binaries outside `assets/` are refused; skills run inside the agent's sandbox.
            - Helpers in `bin/` must be named `\(id)-<tool>` and are plain scripts (0755).

            """, executable: false),
        ]
        if withBin {
            files.append(File(path: "bin/\(id)-tool", content: """
            #!/bin/sh
            # \(id)-tool: a helper the skill may call from Bash (sandboxed; no network unless the owner grants it).
            set -eu
            echo "\(id)-tool: $*"

            """, executable: true))
        }
        return files
    }

    /// Writes the template into `dir` (created; must not already hold files). Never touches anything outside `dir`.
    public static func write(id: String, to dir: URL, withBin: Bool) throws {
        if let problem = ExtensionId.problem(id) { throw ExtensionError.message(problem) }
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            guard SandboxPath.kind(dir.path) == .directory, (try fm.contentsOfDirectory(atPath: dir.path)).isEmpty else {
                throw ExtensionError.message("\(dir.path) exists and is not an empty directory")
            }
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in skill(id: id, withBin: withBin) {
            let url = dir.appending(path: f.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(f.content.utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: f.executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        }
    }
}
