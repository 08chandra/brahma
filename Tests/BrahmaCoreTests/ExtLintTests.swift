import Testing
import Foundation
@testable import BrahmaCore

/// `brahma ext new` / `brahma ext lint` (the SDK, part 1), the owner's `ext add` through the binary, and Claude's own
/// checks running only on the allowlisted copy under the sandboxed runner.
private func brahma(_ args: [String], home: URL, env: [String: String] = [:]) throws -> (status: Int32, stdout: String, stderr: String) {
    let url = brahmaExecutableURL()
    try #require(FileManager.default.isExecutableFile(atPath: url.path), "build the brahma product first")
    let p = Process()
    p.executableURL = url
    p.arguments = args
    var e = cliEnvironment(home: home)
    e.merge(env) { _, new in new }
    p.environment = e
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
}

@Suite(.scratch) struct ExtLintTests {
    private func decodeIssues(_ text: String) throws -> [[String: Any]] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
    }

    @Test func jsonOutputShapeAndStableCodes() throws {
        let home = try tempDir()
        let f = try PluginFixture(files: ["hooks/hooks.json": "{}",
                                          "skills/demo/SKILL.md": PluginFixture.skillMD(name: "demo", frontmatter: "allowed-tools: Bash")])
        let r = try brahma(["ext", "lint", f.root.path, "--json"], home: home)
        #expect(r.status == 1, "\(r.stderr)")
        let issues = try decodeIssues(r.stdout)
        #expect(issues.map { $0["code"] as? String } == ["EXT001", "EXT011"], "sorted by code, then path: \(issues)")
        for i in issues {
            #expect(Set(i.keys) == ["code", "path", "line", "message", "fix"], "\(i.keys)")
            #expect((i["message"] as? String)?.isEmpty == false)
        }
        #expect(issues[0]["path"] as? String == "hooks"); #expect(issues[0]["message"] as? String == "hooks never run in Brahma")
        #expect(issues[1]["path"] as? String == "skills/demo/SKILL.md"); #expect(issues[1]["line"] as? Int == 5)
        #expect((issues[1]["fix"] as? String)?.contains("allowed-tools") == true)
        // The codes are stable names.
        #expect(LintCode.hookRefused.rawValue == "EXT001"); #expect(LintCode.frontmatterStripped.rawValue == "EXT011")
    }

    @Test func fixStripsAndPrefixes() throws {
        let home = try tempDir()
        let f = try PluginFixture(files: ["skills/demo/SKILL.md": PluginFixture.skillMD(name: "demo", frontmatter: "allowed-tools: Bash\nmodel: opus")])
        try f.bin("tool")
        ScratchScope.current?.allowExecutable(named: "demo-tool")
        let before = try brahma(["ext", "lint", f.root.path], home: home)
        #expect(before.status == 1)
        let fixed = try brahma(["ext", "lint", f.root.path, "--fix"], home: home)
        #expect(fixed.status == 0, "\(fixed.stdout + fixed.stderr)")
        let skill = try f.read("skills/demo/SKILL.md")
        #expect(!skill.contains("allowed-tools") && !skill.contains("model:")); #expect(skill.contains("when_to_use"))
        #expect(f.exists("bin/demo-tool") && !f.exists("bin/tool"))
        #expect(f.exists("ext.lock.json"))
        let lock = try #require(ExtensionLock.read(root: f.root))
        #expect(lock.files.contains { $0.path == "bin/demo-tool" && $0.mode == "0755" })
        #expect(lock.lint.executes.bin)
        let after = try brahma(["ext", "lint", f.root.path, "--json"], home: home)
        #expect(after.status == 0, "\(after.stdout)"); #expect(after.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "[]")
    }

    @Test func lockRegeneratedAndHandEditRefused() throws {
        let home = try tempDir()
        let f = try PluginFixture()
        let locked = try brahma(["ext", "lint", f.root.path, "--lock"], home: home)
        #expect(locked.status == 0, "\(locked.stderr)")
        let text = try f.read("ext.lock.json")
        #expect(text.contains("\"format\" : 1") || text.contains("\"format\":1"))
        #expect(try brahma(["ext", "lint", f.root.path], home: home).status == 0)
        try f.write("ext.lock.json", text.replacingOccurrences(of: "skills/demo/SKILL.md", with: "skills/demo/OTHER.md"))
        let refused = try brahma(["ext", "lint", f.root.path, "--json"], home: home)
        #expect(refused.status == 1)
        #expect(try decodeIssues(refused.stdout).contains { $0["code"] as? String == "EXT025" })
        // A changed file also makes the lock stale; --lock alone regenerates it and changes nothing else.
        try f.write("ext.lock.json", text)
        try f.write("skills/demo/SKILL.md", PluginFixture.skillMD(name: "demo", body: "2. New step.\n"))
        #expect(try brahma(["ext", "lint", f.root.path], home: home).status == 1)
        #expect(try brahma(["ext", "lint", f.root.path, "--lock"], home: home).status == 0)
        #expect(try brahma(["ext", "lint", f.root.path], home: home).status == 0)
        #expect(try f.read("skills/demo/SKILL.md").contains("2. New step."))
    }

    @Test func exitCodes() throws {
        let home = try tempDir()
        #expect(try brahma(["ext", "lint", try PluginFixture().root.path], home: home).status == 0)
        let warn = try PluginFixture(id: "warn", files: ["skills/warn/SKILL.md": PluginFixture.skillMD(name: "warn", frontmatter: "model: opus")])
        #expect(try brahma(["ext", "lint", warn.root.path], home: home).status == 2)
        let bad = try PluginFixture(id: "bad", files: [".mcp.json": "{}"])
        #expect(try brahma(["ext", "lint", bad.root.path], home: home).status == 1)
        let missing = try brahma(["ext", "lint", home.appending(path: "nope").path], home: home)
        #expect(missing.status == 1); #expect(missing.stderr.contains("nope"))
    }

    @Test func claudeValidateRunsOnAllowlistedCopyOnly() async throws {
        // A fake `claude`: records argv and cwd in its cwd; a plugin dir with hooks/ would make it drop a marker next to it.
        let claude = try FakeTools.script("claude", """
        printf '%s\\n' "$*" >> "$PWD/claude-argv.log"
        printf '%s\\n' "$PWD" > "$PWD/claude-cwd.log"
        printf 'HOME=%s CONFIG=%s\\n' "$HOME" "$CLAUDE_CONFIG_DIR" > "$PWD/claude-env.log"
        for a in "$@"; do if [ -d "$a/hooks" ]; then touch "$a/../HOOK-RAN"; fi; done
        case "$*" in
          *details*) echo "Always-on context: 123 tokens";;
          *validate*) echo "valid";;
        esac
        exit 0
        """)
        let f = try PluginFixture(files: ["hooks/hooks.json": #"{"hooks":{}}"#, "tests/cases/a.yaml": "x: 1"])
        let paths = ownerPaths(try tempDir())
        let staged = try await ExtensionImporter.stage(source: .folder(f.root), paths: paths, sandbox: RecordingRunner())
        // The stager already dropped hooks/; plant one again on the staged copy, as a hostile package would be after staging.
        try Data("{}".utf8).write(to: {
            let d = staged.dir.appending(path: "hooks", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d.appending(path: "hooks.json")
        }())
        let runner = RecordingRunner()
        let scratch = try tempDir()
        let check = ClaudeCheck(runner: runner, claudePath: claude.path, scratch: scratch)
        let out = await ExtensionValidator.claudeChecks(staged: staged.dir, check: check)
        #expect(out.alwaysOnTokens == 123, "\(out.issues)")
        #expect(out.issues.isEmpty, "\(out.issues)")
        let calls = runner.calls
        #expect(calls.count == 2)
        let argv = try String(contentsOf: scratch.appending(path: "claude-argv.log"), encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(argv.count == 2)
        let copy = scratch.appending(path: "plugin").path
        // C2: the global options come BEFORE `plugin` (the subcommands refuse them), `details` takes the plugin NAME with `--plugin-dir`.
        // `$*` joins the argv with spaces: the empty `--setting-sources` value shows as two spaces.
        let hardening = "--setting-sources  --strict-mcp-config --settings {\"disableAllHooks\":true}"
        #expect(argv[0] == "\(hardening) plugin validate --strict \(copy)", "\(argv[0])")
        #expect(argv[1] == "\(hardening) --plugin-dir \(copy) plugin details demo", "\(argv[1])")
        for line in argv { #expect(!line.contains(staged.dir.path), "only the allowlisted copy is ever named") }
        for c in calls {
            #expect(c.cwd == scratch); #expect(c.policy.network == .none); #expect(!c.policy.toolchain)
            #expect(c.policy.writable == [scratch])
            #expect(c.policy.readable.allSatisfy { claude.resolvedForSandbox.path.hasPrefix($0.path + "/") }, "only the claude binary's own directory is readable: \(c.policy.readable)")
            #expect(c.environment["CLAUDE_CONFIG_DIR"] == scratch.appending(path: "cc").path)
            #expect(c.environment["HOME"] == scratch.appending(path: "home").path)
            #expect(c.environment["ANTHROPIC_API_KEY"] == nil && c.environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
            #expect(c.command.hasPrefix("'\(claude.path)' "), "\(c.command)")
        }
        #expect(try String(contentsOf: scratch.appending(path: "claude-env.log"), encoding: .utf8).contains("CONFIG=\(scratch.path)/cc"))
        // The copy holds only allowlisted parts: no hooks, so no marker anywhere.
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: "\(copy)/hooks")); #expect(fm.fileExists(atPath: "\(copy)/skills/demo/SKILL.md"))
        #expect(!fm.fileExists(atPath: "\(copy)/tests"), "tests are not a plugin part")
        #expect(!fm.fileExists(atPath: scratch.appending(path: "HOOK-RAN").path))
        #expect(!fm.fileExists(atPath: staged.dir.deletingLastPathComponent().appending(path: "HOOK-RAN").path))
        // `details` needing the network (or failing) is a warning, `validate --strict` failing is an error.
        let failing = try FakeTools.script("claude", "case \"$*\" in *validate*) echo 'plugin.json: invalid'; exit 1;; *) echo 'network error'; exit 1;; esac")
        let out2 = await ExtensionValidator.claudeChecks(staged: staged.dir, check: ClaudeCheck(runner: RecordingRunner(), claudePath: failing.path, scratch: try tempDir()))
        #expect(out2.issues.contains { $0.code == "EXT026" && $0.severity == .error })
        #expect(out2.issues.contains { $0.code == "EXT027" && $0.severity == .warning && $0.message.contains("unavailable") })
        #expect(out2.alwaysOnTokens == nil)
        // A CLI that does not know the options (a usage error) is "unavailable", never a refusal of the package.
        let usage = try FakeTools.script("claude", "echo \"error: unknown option '--setting-sources'\" >&2; exit 1")
        let out3 = await ExtensionValidator.claudeChecks(staged: staged.dir, check: ClaudeCheck(runner: RecordingRunner(), claudePath: usage.path, scratch: try tempDir()))
        #expect(!out3.issues.contains { $0.code == "EXT026" }); #expect(out3.issues.contains { $0.code == "EXT027" })
        // M8: a claude whose directory is the home (or an ancestor of a protected path) gets no readable entry: unavailable.
        let home = try tempDir()
        let wrapper = home.appending(path: "claude")
        try FakeTools.install(at: wrapper, "exit 0")
        let out4 = await ExtensionValidator.claudeChecks(staged: staged.dir, check: ClaudeCheck(runner: RecordingRunner(), claudePath: wrapper.path, scratch: try tempDir(), userHome: home))
        #expect(out4.issues.contains { $0.code == "EXT027" && $0.message.contains("unavailable") }, "\(out4.issues)")
    }

    /// I1: Claude's checks run only on a package the validator passed; a refused package never starts `claude`.
    @Test func claudeChecksSkippedWhenValidatorErrors() async throws {
        let w = try ExtWorld()
        let runner = RecordingRunner()
        let claude = ClaudeCheck(runner: runner, claudePath: try FakeTools.script("claude", "exit 0").path, scratch: try tempDir())
        let bad = try PluginFixture(id: "bad", files: ["skills/bad/scripts/setup.py": "import os"])
        await #expect(throws: ExtensionError.self) { try await w.propose(bad, claude: claude) }
        #expect(runner.calls.isEmpty, "claude never ran on a refused package")
        _ = try await w.propose(try PluginFixture(), claude: claude)
        #expect(runner.calls.count == 2)
    }

    /// I5: `--fix` and `--lock` refuse while the folder holds a link (nothing is written through a shared inode).
    @Test func fixRefusesWithLinks() throws {
        let home = try tempDir()
        let f = try PluginFixture(files: ["skills/demo/SKILL.md": PluginFixture.skillMD(name: "demo", frontmatter: "allowed-tools: Bash")])
        let outside = try tempDir().appending(path: "outside.md")
        try Data("secret\n".utf8).write(to: outside)
        try FileManager.default.linkItem(at: outside, to: f.root.appending(path: "skills/demo/notes.md"))
        let fixed = try brahma(["ext", "lint", f.root.path, "--fix"], home: home)
        #expect(fixed.status == 1); #expect(fixed.stderr.contains("EXT006") || fixed.stdout.contains("EXT006"), "\(fixed.stdout + fixed.stderr)")
        #expect(try f.read("skills/demo/SKILL.md").contains("allowed-tools"), "nothing was changed")
        #expect(!f.exists("ext.lock.json"))
        #expect(try brahma(["ext", "lint", f.root.path, "--lock"], home: home).status == 1)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "secret\n")
    }

    /// BRAHMA_LIVE: the real CLI (no model call) accepts the hardened argv on the clean template and runs none of a hostile
    /// fixture's hook, MCP server, skill-frontmatter hook or agent-frontmatter MCP server.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BRAHMA_LIVE"] == "1")) func liveClaudeChecksRunOnTheTemplate() async throws {
        let claude = try #require((ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
                                      .first { FileManager.default.isExecutableFile(atPath: $0) }, "claude on PATH")
        let dir = try tempDir().appending(path: "live-skill")
        try ExtensionTemplates.write(id: "live-skill", to: dir, withBin: false)
        let out = await ExtensionValidator.claudeChecks(staged: dir, check: ClaudeCheck(runner: RecordingRunner(), claudePath: claude, scratch: try tempDir()))
        #expect(out.issues.isEmpty, "\(out.issues)"); #expect(out.alwaysOnTokens != nil)
        let item = await Doctor.pluginDetailsItem(claudePath: claude, sandbox: RecordingRunner())
        #expect(item.status == .pass, "\(item.detail)")
    }

    @Test func newSkillTemplateLintsClean() throws {
        let home = try tempDir()
        let dir = home.appending(path: "mine")
        let made = try brahma(["ext", "new", "skill", "my-skill", "--dir", dir.path], home: home)
        #expect(made.status == 0, "\(made.stderr)")
        let fm = FileManager.default
        for path in [".claude-plugin/plugin.json", "skills/my-skill/SKILL.md", "skills/my-skill/reference/guide.md", "tests/cases/basic.yaml", "README.md"] {
            #expect(fm.fileExists(atPath: dir.appending(path: path).path), "\(path)")
        }
        #expect(!fm.fileExists(atPath: dir.appending(path: "bin").path), "bin/ is optional (--bin)")
        let skill = try String(contentsOf: dir.appending(path: "skills/my-skill/SKILL.md"), encoding: .utf8)
        #expect(skill.contains("name: my-skill") && skill.contains("description:") && skill.contains("when_to_use:"))
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: ".claude-plugin/plugin.json"))) as? [String: Any]
        #expect(Set(manifest?.keys.map { $0 } ?? []) == ["name", "version", "description", "author"]); #expect(manifest?["name"] as? String == "my-skill")
        let lint = try brahma(["ext", "lint", dir.path, "--json"], home: home)
        #expect(lint.status == 0, "\(lint.stdout + lint.stderr)")
        // With the helper: still clean, and the helper is `<id>-` prefixed and executable.
        let dir2 = home.appending(path: "two")
        ScratchScope.current?.allowExecutable(named: "my-tool-tool")
        #expect(try brahma(["ext", "new", "skill", "my-tool", "--dir", dir2.path, "--bin"], home: home).status == 0)
        #expect(fm.isExecutableFile(atPath: dir2.appending(path: "bin/my-tool-tool").path))
        #expect(try brahma(["ext", "lint", dir2.path], home: home).status == 0)
        // Refused: a bad id, an existing non-empty directory, and it never touches ~/.claude (no `claude plugin init`).
        #expect(try brahma(["ext", "new", "skill", "Claude-Thing", "--dir", home.appending(path: "x").path], home: home).status != 0)
        #expect(try brahma(["ext", "new", "skill", "my-skill", "--dir", dir.path], home: home).status != 0)
        #expect(!fm.fileExists(atPath: home.appending(path: ".claude").path))
    }

    /// Ruling S-c1: `ext lint` looks for claude only after the store installed the tools with every company workspace (labs
    /// included) and the data home as forbidden roots, so a claude planted on PATH in any of them is never the one it runs.
    @Test func plantedClaudeUnderAForbiddenRootIsNeverResolved() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        let created = try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "0"], home: home)
        try #require(created.status == 0, "\(created.stderr)")
        let paths = ownerPaths(home)
        let workspace = URL(fileURLWithPath: try #require(try Store(path: paths.database.path).companies().first).workspacePath)
        let marker = try tempDir().appending(path: "planted-claude-ran")
        let f = try PluginFixture()
        for dir in [workspace.appending(path: "bin"), workspace.appending(path: ".brahma/labs/eng/bin"), paths.home.appending(path: "bin")] {
            try FakeTools.install(at: dir.appending(path: "claude"), "touch '\(marker.path)'; echo 2.1.999")
            let r = try brahma(["ext", "lint", f.root.path], home: home, env: ["PATH": "\(dir.path):/usr/bin:/bin"])
            #expect(r.status == 0, "\(dir.path): \(r.stdout + r.stderr)")
            #expect(r.stderr.contains("claude not found on PATH"), "\(dir.path): \(r.stderr)")
            #expect(!FileManager.default.fileExists(atPath: marker.path), "\(dir.path)")
        }
    }

    /// N2: without a claude the doctor reports it missing and runs nothing by a bare name (no `plugin-details-inert`, whose
    /// readable directory a bare name would take from the current directory); a non-executable override is named, never
    /// replaced by a PATH claude.
    @Test func doctorWithoutClaudeRunsNothingByABareName() throws {
        let someone = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        #expect(ExtensionValidator.readableClaudeDirectory("claude", userHome: someone) == nil)
        #expect(ExtensionValidator.readableClaudeDirectory("bin/claude", userHome: someone) == nil)
        #expect(ExtensionValidator.readableClaudeDirectory("/opt/tools/bin/claude", userHome: someone)?.map(\.path) == ["/opt/tools/bin"])
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        let d = try brahma(["doctor"], home: home)
        #expect(d.status == 1)
        #expect(d.stdout.contains("FAIL  version  claude was not found: no claude found in a safe PATH directory"), "\(d.stdout)")
        #expect(!d.stdout.contains("plugin-details-inert"), "\(d.stdout)")
        let marker = try tempDir().appending(path: "path-claude-ran")
        let safe = try tempDir().appending(path: "safe", directoryHint: .isDirectory)
        try FakeTools.install(at: safe.appending(path: "claude"), "touch '\(marker.path)'; echo 2.1.999")
        let o = try brahma(["doctor"], home: home, env: ["BRAHMA_CLAUDE": "/nonexistent/claude", "PATH": "\(safe.path):/usr/bin:/bin"])
        #expect(o.status == 1)
        #expect(o.stdout.contains("FAIL  version  claude was not found: BRAHMA_CLAUDE (/nonexistent/claude) is not an executable file"), "\(o.stdout)")
        #expect(!o.stdout.contains("plugin-details-inert"), "\(o.stdout)")
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the PATH claude never ran")
    }

    @Test func cliAddAndApproveRefusal() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        let created = try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "0"], home: home)
        try #require(created.status == 0, "\(created.stderr)")
        let f = try PluginFixture()
        let added = try brahma(["ext", "add", f.root.path, "Acme", "--roles", "engineer"], home: home)
        #expect(added.status == 0, "\(added.stderr)")
        #expect(added.stdout.contains("A-1 pending"), "\(added.stdout)")
        // The CLI never decides it; the app does.
        let approve = try brahma(["approve", "Acme", "A-1"], home: home)
        #expect(approve.status != 0); #expect(approve.stderr.contains("approve extensions in the app"), "\(approve.stderr)")
        let listed = try brahma(["ext", "list", "Acme"], home: home)
        #expect(listed.status == 0); #expect(listed.stdout.contains("demo") && listed.stdout.contains("pending"), "\(listed.stdout)")
        // Agents never run owner commands.
        #expect(try brahma(["ext", "add", f.root.path, "Acme"], home: home, env: ["BRAHMA_AGENT_ID": "a1"]).status != 0)
        // Rejecting is plain.
        let rejected = try brahma(["approve", "Acme", "A-1", "--reject"], home: home)
        #expect(rejected.status == 0, "\(rejected.stderr)"); #expect(rejected.stdout.contains("rejected"))
    }
}
