import Testing
import Foundation
@testable import BrahmaCore

/// The decomposing importer (Task 5a, skill-only): what each source becomes in staging, and the notices it leaves.
@Suite(.scratch) struct ExtensionImporterTests {
    private func paths() throws -> BrahmaPaths { ownerPaths(try tempDir()) }

    @Test func bareSkillWraps() async throws {
        let dir = try tempDir().appending(path: "voice", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir.appending(path: "reference"), withIntermediateDirectories: true)
        try Data(PluginFixture.skillMD(name: "brand-voice").utf8).write(to: dir.appending(path: "SKILL.md"))
        try Data("# guide".utf8).write(to: dir.appending(path: "reference/guide.md"))
        let p = try paths()
        let staged = try await ExtensionImporter.stage(source: .bareSkill(dir), paths: p, sandbox: RecordingRunner())
        #expect(staged.id == "brand-voice")
        #expect(staged.dir.path.hasPrefix(p.extensionsDir.staging.path))
        let manifest = try ExtensionManifest.read(staged.dir)
        #expect(manifest.name == "brand-voice"); #expect(manifest.description == "Demo skill: use it for demos.")
        #expect(FileManager.default.fileExists(atPath: staged.dir.appending(path: "skills/brand-voice/SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: staged.dir.appending(path: "skills/brand-voice/reference/guide.md").path))
        #expect(staged.source.publisher == "local"); #expect(staged.source.sourceType == "bareSkill")
        #expect(ExtensionValidator.validate(staged: staged.dir).errors.isEmpty)
        // The frontmatter name must be a valid id.
        let bad = try tempDir().appending(path: "bad", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data(PluginFixture.skillMD(name: "My Claude Skill").utf8).write(to: bad.appending(path: "SKILL.md"))
        await #expect(throws: ExtensionError.self) { try await ExtensionImporter.stage(source: .bareSkill(bad), paths: p, sandbox: RecordingRunner()) }
    }

    @Test func claudeCodePluginDecomposed() async throws {
        // A realistic Claude Code plugin: skills plus an MCP server, hooks, an LSP server and a few more parts.
        let f = try PluginFixture(id: "vendor", manifest: """
        {"name": "vendor", "version": "2.0.0", "description": "Vendor tools.", "author": {"name": "V"},
         "homepage": "https://vendor.example.com", "mcpServers": {"vendor-api": {"command": "npx", "args": ["-y", "vendor-mcp"]}},
         "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "echo hi"}]}]},
         "lspServers": {"ts": {"command": "tsserver"}}, "channels": {"x": 1},
         "userConfig": {"apiToken": {"type": "string", "description": "API token"}, "region": {"type": "string"}}}
        """, files: [
            "skills/vendor/SKILL.md": PluginFixture.skillMD(name: "vendor"),
            ".mcp.json": #"{"mcpServers": {"vendor-remote": {"type": "http", "url": "https://mcp.vendor.example.com"}}}"#,
            "hooks/hooks.json": #"{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo x"}]}]}}"#,
            ".lsp.json": #"{"lspServers": {}}"#, "settings.json": "{}", "monitors/m.md": "# m", "output-styles/o.md": "# o",
            "themes/t.json": "{}", "workflows/w.md": "# w", "CLAUDE.md": "# rules", "commands/deploy.md": "---\ndescription: Deploy.\n---\nDeploy.",
        ])
        let staged = try await ExtensionImporter.stage(source: .folder(f.root), paths: try paths(), sandbox: RecordingRunner())
        let fm = FileManager.default
        // Kept: skills and commands, the 4-key manifest.
        #expect(fm.fileExists(atPath: staged.dir.appending(path: "skills/vendor/SKILL.md").path))
        #expect(fm.fileExists(atPath: staged.dir.appending(path: "commands/deploy.md").path))
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: staged.dir.appending(path: ".claude-plugin/plugin.json"))) as? [String: Any]
        #expect(Set(manifest?.keys.map { $0 } ?? []) == ["name", "version", "description", "author"])
        // Dropped: MCP, hooks, LSP and the rest, each with its notice.
        for gone in [".mcp.json", "hooks", ".lsp.json", "settings.json", "monitors", "output-styles", "themes", "workflows", "CLAUDE.md"] {
            #expect(!fm.fileExists(atPath: staged.dir.appending(path: gone).path), "\(gone)")
        }
        let n = staged.notices
        #expect(n.contains("This plugin's MCP server vendor-api was not imported; connectors arrive in a later Brahma release."), "\(n)")
        #expect(n.contains("This plugin's MCP server vendor-remote was not imported; connectors arrive in a later Brahma release."))
        #expect(n.contains("This plugin's SessionStart hook will not run in Brahma."))
        #expect(n.contains("This plugin's PreToolUse hook will not run in Brahma."))
        for part in ["LSP server", "settings.json", "monitors", "output-styles", "themes", "workflows", "channels", "CLAUDE.md"] {
            #expect(n.contains { $0.contains(part) && $0.contains("not imported") }, "\(part)")
        }
        #expect(n.contains { $0.contains("apiToken") && $0.contains("add it as a secret") }, "\(n)")
        #expect(n.contains { $0.contains("region") && !$0.contains("secret") })
        // The result validates clean, apart from warnings.
        #expect(ExtensionValidator.validate(staged: staged.dir).errors.isEmpty, "\(ExtensionValidator.validate(staged: staged.dir).errors)")
        #expect(staged.source.publisher == "local"); #expect(staged.source.sourceType == "folder")
    }

    @Test func dependenciesOnlyNoticed() async throws {
        let f = try PluginFixture(manifest: PluginFixture.manifestJSON(id: "demo", extra: #", "dependencies": ["other-plugin", "third@1.0"]"#))
        let staged = try await ExtensionImporter.stage(source: .folder(f.root), paths: try paths(), sandbox: RecordingRunner())
        #expect(staged.notices.contains { $0.contains("other-plugin") && $0.contains("not installed") })
        #expect(staged.notices.contains { $0.contains("third@1.0") })
        #expect(!(try String(contentsOf: staged.dir.appending(path: ".claude-plugin/plugin.json"), encoding: .utf8)).contains("dependencies"))
        // Nothing else appeared in staging: the dependency was never followed.
        let entries = try FileManager.default.contentsOfDirectory(atPath: staged.dir.deletingLastPathComponent().path)
        #expect(entries == [staged.dir.lastPathComponent])
        // Top-level node_modules is refused outright.
        let g = try PluginFixture(files: ["node_modules/x/index.js": "1"])
        await #expect(throws: ExtensionError.self) { try await ExtensionImporter.stage(source: .folder(g.root), paths: try paths(), sandbox: RecordingRunner()) }
    }

    @Test func neverRunsClaudePluginInstall() async throws {
        // The importer's source never names `claude plugin install` (or `claude plugin` at all): Brahma copies plugin folders itself.
        let root = EngineGitGuardTests.packageRoot
        let importer = try String(contentsOf: root.appending(path: "Sources/BrahmaCore/Extensions/ExtensionImporter.swift"), encoding: .utf8)
        #expect(!EngineGitGuardTests.code(importer).contains("plugin install"))
        for (path, text) in try EngineGitGuardTests.sources(under: "Sources") {
            #expect(!EngineGitGuardTests.code(text).contains("plugin install"), "\(path)")
            #expect(!EngineGitGuardTests.code(text).contains("plugin\", \"install"), "\(path)")
        }
        // A plugin cache import copies the newest version folder of `~/.claude/plugins/cache/<marketplace>/<plugin>/`.
        let home = try tempDir()
        let cache = home.appending(path: ".claude/plugins/cache/official/vendor", directoryHint: .isDirectory)
        for version in ["1.0.0", "1.2.0", "abcdef123456"] {
            let dir = cache.appending(path: version, directoryHint: .isDirectory)
            _ = try PluginFixture(id: "vendor", manifest: #"{"name": "vendor", "version": "\#(version)", "description": "V.", "author": {"name": "V"}}"#,
                                  files: ["hooks/hooks.json": "{}"], under: dir.deletingLastPathComponent().appending(path: "x-\(version)"))
            try FileManager.default.moveItem(at: dir.deletingLastPathComponent().appending(path: "x-\(version)/vendor"), to: dir)
        }
        try Data("1".utf8).write(to: cache.appending(path: "abcdef123456/.orphaned_at"))
        let staged = try await ExtensionImporter.stage(source: .claudeCodeInstalled(marketplace: "official", plugin: "vendor"), paths: try paths(), userHome: home, sandbox: RecordingRunner())
        #expect(try ExtensionManifest.read(staged.dir).version == "1.2.0")
        #expect(staged.source.publisher == "third-party:claude-code/official"); #expect(staged.source.sourceType == "claudeCode")
        #expect(staged.notices.contains { $0.contains("hook") })
        #expect(!FileManager.default.fileExists(atPath: staged.dir.appending(path: "hooks").path))
        // Never from an agent turn.
        await #expect(throws: ExtensionError.self) {
            try await ExtensionImporter.stage(source: .claudeCodeInstalled(marketplace: "official", plugin: "vendor"), paths: try paths(), userHome: home,
                                        environment: ["BRAHMA_AGENT_ID": "a1"], sandbox: RecordingRunner())
        }
    }

    @Test func binRenamedWithNotice() async throws {
        let f = try PluginFixture()
        try f.bin("lint")
        try f.bin("demo-fmt")
        let staged = try await ExtensionImporter.stage(source: .folder(f.root), paths: try paths(), sandbox: RecordingRunner())
        ScratchScope.current?.allowExecutable(named: "demo-lint"); ScratchScope.current?.allowExecutable(named: "demo-fmt")
        let fm = FileManager.default
        #expect(fm.isExecutableFile(atPath: staged.dir.appending(path: "bin/demo-lint").path))
        #expect(fm.isExecutableFile(atPath: staged.dir.appending(path: "bin/demo-fmt").path))
        #expect(!fm.fileExists(atPath: staged.dir.appending(path: "bin/lint").path))
        #expect(staged.notices.contains("bin/lint was renamed to bin/demo-lint."), "\(staged.notices)")
        #expect(!staged.notices.contains { $0.contains("demo-fmt") })
    }

    @Test func zipSourceStagesAndLinksRefused() async throws {
        let f = try PluginFixture(files: ["README.md": "# demo"])
        let zip = try tempDir().appending(path: "demo.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = f.root.deletingLastPathComponent()
        p.arguments = ["-q", "-r", "-y", zip.path, "demo"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        try #require(p.terminationStatus == 0)
        let staged = try await ExtensionImporter.stage(source: .zip(zip), paths: try paths(), sandbox: RecordingRunner())
        #expect(staged.id == "demo"); #expect(staged.source.sourceType == "zip")
        #expect(FileManager.default.fileExists(atPath: staged.dir.appending(path: "README.md").path))
        #expect(ExtensionValidator.validate(staged: staged.dir).errors.isEmpty)
        // A link inside the source folder is refused at staging (never copied, never followed).
        let g = try PluginFixture()
        try FileManager.default.createSymbolicLink(at: g.root.appending(path: "skills/demo/ref"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        await #expect(throws: ExtensionError.self) { try await ExtensionImporter.stage(source: .folder(g.root), paths: try paths(), sandbox: RecordingRunner()) }
    }

    /// S10 / I2: the archive is enumerated before anything is extracted; the limits, link, absolute and `..` entries refuse it
    /// with nothing left in staging; extraction itself runs `/usr/bin/unzip` under the sandboxed runner with a byte quota.
    @Test func zipLimitsEnforcedBeforeExtraction() async throws {
        let p = try paths()
        func refused(_ build: (inout ZipBuilder) -> Void, _ fragment: String) async throws {
            var z = ZipBuilder()
            z.add("demo/.claude-plugin/plugin.json", PluginFixture.manifestJSON(id: "demo"))
            z.add("demo/skills/demo/SKILL.md", PluginFixture.skillMD(name: "demo"))
            build(&z)
            let zip = try tempDir().appending(path: "x.zip")
            try z.write(to: zip)
            let runner = RecordingRunner()
            let error = await errorOf { _ = try await ExtensionImporter.stage(source: .zip(zip), paths: p, sandbox: runner) }
            #expect((error as? ExtensionError)?.message.contains(fragment) == true, "\(fragment): \(String(describing: error))")
            #expect(runner.calls.isEmpty, "\(fragment): nothing was extracted")
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: p.extensionsDir.staging.path)) ?? []).isEmpty, "\(fragment): staging is clean")
        }
        try await refused({ z in for n in 0..<ExtensionLimits.maxFiles { z.add("demo/assets/f\(n).txt", "x") } }, "entries")
        try await refused({ z in z.add("demo/assets/big", "a", declaredSize: ExtensionLimits.maxBytes + 1) }, "uncompressed")
        try await refused({ z in z.add("demo/skills/demo/link", "/etc/passwd", symlink: true) }, "symbolic link")
        try await refused({ z in z.add("/etc/demo.md", "x") }, "absolute")
        try await refused({ z in z.add("demo/../../escape.md", "x") }, "..")
        try await refused({ z in z.add("demo\\..\\..\\escape.md", "x") }, "'..'")   // m-5: `\` separates too
        try await refused({ z in z.add("demo/assets/evil\u{202E}txt.md", "x") }, "control, hidden or bidi")
        #expect(ZipLimits.maxRatio == 100)
        // A real archive: the extraction runs /usr/bin/unzip under the runner, writable = the unzip dir only, no network, a byte quota.
        let f = try PluginFixture(files: ["README.md": "# demo"])
        let zip = try tempDir().appending(path: "demo.zip")
        try Self.zip(dir: f.root.deletingLastPathComponent(), name: "demo", to: zip)
        let runner = RecordingRunner()
        let staged = try await ExtensionImporter.stage(source: .zip(zip), paths: p, sandbox: runner)
        #expect(staged.id == "demo")
        let call = try #require(runner.calls.first)
        #expect(call.command.contains("/usr/bin/unzip' -q -n ") || call.command.contains("/usr/bin/unzip -q -n "), "\(call.command)")
        #expect(call.command.contains("ulimit -f"), "\(call.command)")
        #expect(!call.command.contains(" -o ")); #expect(call.policy.network == .none); #expect(!call.policy.toolchain)
        #expect(call.policy.writable.count == 1); #expect(call.policy.writable[0].lastPathComponent == ".unzip")
        #expect(call.policy.writable[0].path.hasPrefix(p.extensionsDir.staging.path))
        #expect(!FileManager.default.fileExists(atPath: staged.dir.appending(path: ".unzip").path))
        // A zip bomb (6 MB of zeros, a few KB compressed) is refused by the ratio, before unzip runs.
        let zeros = try tempDir()
        try FileManager.default.createDirectory(at: zeros.appending(path: "demo/.claude-plugin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: zeros.appending(path: "demo/assets"), withIntermediateDirectories: true)
        try Data(PluginFixture.manifestJSON(id: "demo").utf8).write(to: zeros.appending(path: "demo/.claude-plugin/plugin.json"))
        try Data(count: 6 * 1024 * 1024).write(to: zeros.appending(path: "demo/assets/zeros"))
        let bomb = zeros.appending(path: "bomb.zip")
        try Self.zip(dir: zeros, name: "demo", to: bomb)
        let bombRunner = RecordingRunner()
        let bombError = await errorOf { _ = try await ExtensionImporter.stage(source: .zip(bomb), paths: p, sandbox: bombRunner) }
        #expect((bombError as? ExtensionError)?.message.contains("ratio") == true, "\(String(describing: bombError))")
        #expect(bombRunner.calls.isEmpty)
    }

    /// S10: the running byte quota. A deflated archive whose central directory (and local headers) under-declare the sizes
    /// passes the inventory, but its real bytes are counted through the quota before anything is written: refused, staging clean.
    @Test func zipUnderDeclaredSizesHitTheQuota() async throws {
        let p = try paths()
        let src = try tempDir()
        try FileManager.default.createDirectory(at: src.appending(path: "demo/.claude-plugin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: src.appending(path: "demo/assets"), withIntermediateDirectories: true)
        try Data(PluginFixture.manifestJSON(id: "demo").utf8).write(to: src.appending(path: "demo/.claude-plugin/plugin.json"))
        try Data(count: ExtensionLimits.maxBytes + 4096).write(to: src.appending(path: "demo/assets/zeros"))
        let zip = src.appending(path: "liar.zip")
        try Self.zip(dir: src, name: "demo", to: zip)
        // Rewrite every big entry's declared uncompressed size to 50x its compressed size (under the ratio and byte limits).
        var bytes = [UInt8](try Data(contentsOf: zip))
        func u32(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24 }
        func put(_ i: Int, _ v: Int) { for k in 0..<4 { bytes[i + k] = UInt8((v >> (8 * k)) & 0xff) } }
        var patched = 0
        for i in 0..<(bytes.count - 30) where bytes[i] == 0x50 && bytes[i + 1] == 0x4b {
            if bytes[i + 2] == 0x03, bytes[i + 3] == 0x04, u32(i + 22) > 1_000_000 { put(i + 22, u32(i + 18) * 50); patched += 1 }
            if bytes[i + 2] == 0x01, bytes[i + 3] == 0x02, u32(i + 24) > 1_000_000 { put(i + 24, u32(i + 20) * 50); patched += 1 }
        }
        try #require(patched == 2)
        try Data(bytes).write(to: zip)
        let inventory = try ZipInventory.entries(of: Data(bytes))
        #expect(inventory.reduce(0) { $0 + $1.uncompressedSize } <= ExtensionLimits.maxBytes, "the inventory alone would pass")
        let error = await errorOf { _ = try await ExtensionImporter.stage(source: .zip(zip), paths: p, sandbox: RecordingRunner()) }
        #expect((error as? ExtensionError)?.message.contains("inflates to more than") == true, "\(String(describing: error))")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: p.extensionsDir.staging.path)) ?? []).isEmpty, "staging is clean")
    }

    /// I-2 (fix round 2): the inventory is self-consistent or the archive is refused before anything is extracted: an end
    /// record that under-counts (the reviewer's 65,537 entries plus a symlink behind "1 entry"), a benign fake directory in front
    /// of the real one, prepended bytes, and a local header that differs from its central entry. A normal archive still imports,
    /// with unzip's own listing compared to the inventory first.
    @Test func zipInventoryMustBeSelfConsistent() async throws {
        let p = try paths()
        func refused(_ z: ZipBuilder, _ fragment: String, patch: ((inout [UInt8]) -> Void)? = nil) async throws {
            let zip = try tempDir().appending(path: "crafted.zip")
            try z.write(to: zip)
            if let patch { var b = [UInt8](try Data(contentsOf: zip)); patch(&b); try Data(b).write(to: zip) }
            let runner = RecordingRunner()
            let error = await errorOf { _ = try await ExtensionImporter.stage(source: .zip(zip), paths: p, sandbox: runner) }
            #expect((error as? ExtensionError)?.message.contains(fragment) == true, "\(fragment): \(String(describing: error))")
            #expect(runner.calls.isEmpty, "\(fragment): nothing was extracted or even listed")
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: p.extensionsDir.staging.path)) ?? []).isEmpty)
        }
        func base() -> ZipBuilder {
            var z = ZipBuilder()
            z.add("demo/.claude-plugin/plugin.json", PluginFixture.manifestJSON(id: "demo"))
            z.add("demo/a.txt", "a")
            return z
        }
        var undercount = base()
        undercount.add("demo/link", "/etc/passwd", symlink: true)
        undercount.countOverride = 1
        try await refused(undercount, "not self-consistent")
        var many = base()
        for n in 0..<65_537 { many.add("d/\(n)", "") }
        many.add("demo/evil", "/etc/passwd", symlink: true)
        many.countOverride = 1
        try await refused(many, "not self-consistent")
        var fake = base()
        fake.add("demo/link", "/etc/passwd", symlink: true)
        fake.fakeCentral = ["demo/a.txt"]
        try await refused(fake, "not self-consistent")
        // Bytes in front of the first entry (Info-ZIP would re-base the offsets).
        try await refused(base(), "not self-consistent") { b in
            b.insert(contentsOf: [0, 0, 0, 0], at: 0)
            for i in 0..<(b.count - 4) where b[i] == 0x50 && b[i + 1] == 0x4b && b[i + 2] == 0x05 && b[i + 3] == 0x06 {
                let off = Int(b[i + 16]) | Int(b[i + 17]) << 8 | Int(b[i + 18]) << 16 | Int(b[i + 19]) << 24
                let moved = off + 4
                for k in 0..<4 { b[i + 16 + k] = UInt8((moved >> (8 * k)) & 0xff) }
            }
        }
        // A local header whose name differs from its central entry.
        try await refused(base(), "not self-consistent") { b in
            if let i = (0..<(b.count - 30)).first(where: { b[$0] == 0x50 && b[$0 + 1] == 0x4b && b[$0 + 2] == 0x03 && b[$0 + 3] == 0x04 }) { b[i + 30] = UInt8(ascii: "x") }
        }
        // A normal archive imports; the one sandboxed command lists with zipinfo and compares before unzip extracts.
        let f = try PluginFixture(files: ["README.md": "# demo"])
        let zip = try tempDir().appending(path: "demo.zip")
        try Self.zip(dir: f.root.deletingLastPathComponent(), name: "demo", to: zip)
        let runner = RecordingRunner()
        _ = try await ExtensionImporter.stage(source: .zip(zip), paths: p, sandbox: runner)
        let command = try #require(runner.calls.first?.command)
        let listAt = try #require(command.range(of: "/usr/bin/zipinfo' -1 ")), unzipAt = try #require(command.range(of: "/usr/bin/unzip' -q -n "))
        #expect(listAt.lowerBound < unzipAt.lowerBound); #expect(command.contains("/usr/bin/cmp -s - "))
        #expect(runner.calls.count == 1)
    }

    static func zip(dir: URL, name: String, to zip: URL) throws {
        let zp = Process()
        zp.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zp.currentDirectoryURL = dir
        zp.arguments = ["-q", "-r", zip.path, name]; zp.standardOutput = FileHandle.nullDevice; zp.standardError = FileHandle.nullDevice
        try zp.run(); zp.waitUntilExit()
        try #require(zp.terminationStatus == 0)
    }

    /// I6: top-level entries outside the allowlist are dropped with a notice (a symlink at such a name too); only node_modules refuses.
    @Test func foreignTopLevelEntriesDropped() async throws {
        let f = try PluginFixture(files: [".in_use/lock": "1", ".gitignore": "x", ".github/workflows/ci.yml": "on: push", ".cursor-plugin/plugin.json": "{}",
                                          ".codex-plugin/x": "1", "gemini-extension.json": "{}", "AGENTS.md": "# a", "docs/guide.md": "# g"])
        try FileManager.default.createSymbolicLink(at: f.root.appending(path: "CLAUDE.md"), withDestinationURL: f.root.appending(path: "AGENTS.md"))
        let staged = try await ExtensionImporter.stage(source: .folder(f.root), paths: try paths(), sandbox: RecordingRunner())
        for gone in [".in_use", ".gitignore", ".github", ".cursor-plugin", ".codex-plugin", "gemini-extension.json", "AGENTS.md", "docs", "CLAUDE.md"] {
            #expect(!FileManager.default.fileExists(atPath: staged.dir.appending(path: gone).path), "\(gone)")
            #expect(staged.notices.contains { $0.contains(gone) && $0.contains("not imported") }, "\(gone): \(staged.notices)")
        }
        #expect(ExtensionValidator.validate(staged: staged.dir).errors.isEmpty)
    }

    /// M1, M2: `mcpServers` as a path or a list is noticed (and the file dropped); component-path keys are dropped with a notice.
    @Test func manifestPathFormsNoticed() async throws {
        let f = try PluginFixture(manifest: PluginFixture.manifestJSON(id: "demo", extra: #", "mcpServers": "./servers/mcp.json", "outputStyles": "./styles", "commands": ["./extra-cmds"]"#),
                                  files: ["servers/mcp.json": #"{"mcpServers": {"remote": {"type": "http", "url": "https://x"}}}"#, "styles/s.md": "# s"])
        let staged = try await ExtensionImporter.stage(source: .folder(f.root), paths: try paths(), sandbox: RecordingRunner())
        // The referenced folder is outside the allowlist, so it is never copied: the server is noticed by its path, and dropped.
        #expect(staged.notices.contains { $0.contains("MCP server") && $0.contains("servers/mcp.json") && $0.contains("not imported") }, "\(staged.notices)")
        #expect(staged.notices.contains { $0.hasPrefix("servers was not imported") })
        #expect(staged.notices.contains { $0.contains("outputStyles") && $0.contains("dropped") })
        #expect(staged.notices.contains { $0.contains("commands") && $0.contains("dropped") })
        #expect(!FileManager.default.fileExists(atPath: staged.dir.appending(path: "servers").path))
        #expect(ExtensionValidator.validate(staged: staged.dir).errors.isEmpty, "\(ExtensionValidator.validate(staged: staged.dir).errors)")
        let listed = try PluginFixture(manifest: PluginFixture.manifestJSON(id: "demo", extra: #", "mcpServers": ["./a.json", "./b.json"]"#))
        let s2 = try await ExtensionImporter.stage(source: .folder(listed.root), paths: try paths(), sandbox: RecordingRunner())
        #expect(s2.notices.filter { $0.contains("MCP server") }.count == 2, "\(s2.notices)")
    }
}
