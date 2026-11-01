import Foundation

/// The engine-owned git hooks of a company workspace (Task 5a): `.brahma/hooks/pre-commit`, named by `core.hooksPath` in the
/// repository config (set through `GitCommand`). Advisory, because `--no-verify` bypasses it; engine git never runs it
/// (`core.hooksPath=/dev/null` on every engine call). Agents cannot write `.brahma/hooks` (it is write-denied on every turn).
public enum CompanyHooks {
    public static let banner = "Brahma: possible secret"

    /// The POSIX `sh` pre-commit script: every added line of the staged diff (the `+++` file headers left out; no external diff
    /// or textconv driver) is written once to a temporary file and matched against every `SecretScan` pattern with `grep -E -e`
    /// (the pattern may start with `-`); a match blocks the commit and names the rule, never the match. Deleted test files are
    /// reported, and the commit goes through. A clean commit prints nothing.
    public static let preCommit: String = {
        precondition(SecretScan.patterns.allSatisfy { !$0.ere.contains("'") }, "the EREs are single-quoted in the hook script")
        var lines = [
            "#!/bin/sh",
            "# Brahma pre-commit hook (engine-owned; reinstalled when it differs). Advisory: --no-verify bypasses it.",
            "added=$(mktemp \"${TMPDIR:-/tmp}/brahma-hook.XXXXXX\") || exit 0",
            "trap 'rm -f \"$added\"' EXIT",
            "git diff --cached -U0 --no-color --no-ext-diff --no-textconv | grep -v '^+++ ' | grep '^+' | cut -c2- > \"$added\"",
        ]
        for p in SecretScan.patterns {
            lines.append("if grep -E -q -e '\(p.ere)' \"$added\"; then")
            lines.append("  echo \"\(banner) (\(p.label)) in staged changes — commit blocked.\" >&2")
            lines.append("  exit 1")
            lines.append("fi")
        }
        lines += [
            "deleted=$(git diff --cached --name-status --diff-filter=D --no-ext-diff --no-textconv | cut -f2- | grep -E '(^|/)(Tests?|__tests__|spec|specs)/|[._-](test|spec)\\.|Tests?\\.swift$' | tr '\\n' ' ' | sed 's/ $//')",
            "if [ -n \"$deleted\" ]; then",
            "  echo \"Brahma: you deleted test files: $deleted. Your reviewer must approve this explicitly.\" >&2",
            "fi",
            "exit 0",
            "",
        ]
        return lines.joined(separator: "\n")
    }()

    /// Writes the script (0755, through `EngineFiles`, replaced when it differs; a link there is replaced, never followed) and
    /// points `core.hooksPath` at `.brahma/hooks` through `GitCommand`. Returns whether anything changed. Blocking (engine git).
    @discardableResult
    public static func install(layout: SandboxLayout, git: GitWorkspace) throws -> Bool {
        let ws = layout.workspace
        var changed = false
        _ = try EngineFiles.directory(workspace: ws, ".brahma/hooks")
        let want = Data(preCommit.utf8)
        let current = try EngineFiles.entry(workspace: ws, dir: ".brahma/hooks", name: "pre-commit")
        var same = false
        if case .regular = current, let have = try EngineFiles.read(workspace: ws, dir: ".brahma/hooks", name: "pre-commit"), have == want {
            var st = stat()
            same = lstat(layout.hooksDir.appending(path: "pre-commit").path, &st) == 0 && (st.st_mode & 0o777) == 0o755
        }
        if !same {
            _ = try EngineFiles.replace(want, workspace: ws, dir: ".brahma/hooks", name: "pre-commit", mode: 0o755)
            changed = true
        }
        if try git.hooksPath() != layout.hooksDir.path {
            try git.setHooksPath(layout.hooksDir)
            changed = true
        }
        return changed
    }
}
