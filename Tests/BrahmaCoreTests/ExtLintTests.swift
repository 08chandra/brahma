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
        let staged = try ExtensionImporter.stage(source: .folder(f.root), paths: paths)
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
        #expect(argv[0].hasPrefix("plugin validate --strict \(copy) ") || argv[0].hasPrefix("plugin validate --strict \(copy)\n"), "\(argv[0])")
        #expect(argv[1].hasPrefix("plugin details \(copy)"), "\(argv[1])")
        for line in argv {
            // `$*` joins the argv with spaces: the empty `--setting-sources` value shows as two spaces.
            #expect(line.contains("--setting-sources  --strict-mcp-config"), "\(line)")
            #expect(line.contains("--settings {\"disableAllHooks\":true}"), "\(line)")
            #expect(!line.contains(staged.dir.path), "only the allowlisted copy is ever named")
        }
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
