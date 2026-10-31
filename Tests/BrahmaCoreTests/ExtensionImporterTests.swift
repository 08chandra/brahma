import Testing
import Foundation
@testable import BrahmaCore

/// The decomposing importer (Task 5a, skill-only): what each source becomes in staging, and the notices it leaves.
@Suite(.scratch) struct ExtensionImporterTests {
    private func paths() throws -> BrahmaPaths { ownerPaths(try tempDir()) }

    @Test func bareSkillWraps() throws {
        let dir = try tempDir().appending(path: "voice", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir.appending(path: "reference"), withIntermediateDirectories: true)
        try Data(PluginFixture.skillMD(name: "brand-voice").utf8).write(to: dir.appending(path: "SKILL.md"))
        try Data("# guide".utf8).write(to: dir.appending(path: "reference/guide.md"))
        let p = try paths()
        let staged = try ExtensionImporter.stage(source: .bareSkill(dir), paths: p)
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
        #expect(throws: ExtensionError.self) { try ExtensionImporter.stage(source: .bareSkill(bad), paths: p) }
    }

    @Test func claudeCodePluginDecomposed() throws {
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
        let staged = try ExtensionImporter.stage(source: .folder(f.root), paths: try paths())
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

    @Test func dependenciesOnlyNoticed() throws {
        let f = try PluginFixture(manifest: PluginFixture.manifestJSON(id: "demo", extra: #", "dependencies": ["other-plugin", "third@1.0"]"#))
        let staged = try ExtensionImporter.stage(source: .folder(f.root), paths: try paths())
        #expect(staged.notices.contains { $0.contains("other-plugin") && $0.contains("not installed") })
        #expect(staged.notices.contains { $0.contains("third@1.0") })
        #expect(!(try String(contentsOf: staged.dir.appending(path: ".claude-plugin/plugin.json"), encoding: .utf8)).contains("dependencies"))
        // Nothing else appeared in staging: the dependency was never followed.
        let entries = try FileManager.default.contentsOfDirectory(atPath: staged.dir.deletingLastPathComponent().path)
        #expect(entries == [staged.dir.lastPathComponent])
        // Top-level node_modules is refused outright.
        let g = try PluginFixture(files: ["node_modules/x/index.js": "1"])
        #expect(throws: ExtensionError.self) { try ExtensionImporter.stage(source: .folder(g.root), paths: try paths()) }
    }

    @Test func neverRunsClaudePluginInstall() throws {
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
        let staged = try ExtensionImporter.stage(source: .claudeCodeInstalled(marketplace: "official", plugin: "vendor"), paths: try paths(), userHome: home)
        #expect(try ExtensionManifest.read(staged.dir).version == "1.2.0")
        #expect(staged.source.publisher == "third-party:claude-code/official"); #expect(staged.source.sourceType == "claudeCode")
        #expect(staged.notices.contains { $0.contains("hook") })
        #expect(!FileManager.default.fileExists(atPath: staged.dir.appending(path: "hooks").path))
        // Never from an agent turn.
        #expect(throws: ExtensionError.self) {
            try ExtensionImporter.stage(source: .claudeCodeInstalled(marketplace: "official", plugin: "vendor"), paths: try paths(), userHome: home,
                                        environment: ["BRAHMA_AGENT_ID": "a1"])
        }
    }

    @Test func binRenamedWithNotice() throws {
        let f = try PluginFixture()
        try f.bin("lint")
        try f.bin("demo-fmt")
        let staged = try ExtensionImporter.stage(source: .folder(f.root), paths: try paths())
        ScratchScope.current?.allowExecutable(named: "demo-lint"); ScratchScope.current?.allowExecutable(named: "demo-fmt")
        let fm = FileManager.default
        #expect(fm.isExecutableFile(atPath: staged.dir.appending(path: "bin/demo-lint").path))
        #expect(fm.isExecutableFile(atPath: staged.dir.appending(path: "bin/demo-fmt").path))
        #expect(!fm.fileExists(atPath: staged.dir.appending(path: "bin/lint").path))
        #expect(staged.notices.contains("bin/lint was renamed to bin/demo-lint."), "\(staged.notices)")
        #expect(!staged.notices.contains { $0.contains("demo-fmt") })
    }

    @Test func zipSourceStagesAndLinksRefused() throws {
        let f = try PluginFixture(files: ["README.md": "# demo"])
        let zip = try tempDir().appending(path: "demo.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = f.root.deletingLastPathComponent()
        p.arguments = ["-q", "-r", "-y", zip.path, "demo"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        try #require(p.terminationStatus == 0)
        let staged = try ExtensionImporter.stage(source: .zip(zip), paths: try paths())
        #expect(staged.id == "demo"); #expect(staged.source.sourceType == "zip")
        #expect(FileManager.default.fileExists(atPath: staged.dir.appending(path: "README.md").path))
        #expect(ExtensionValidator.validate(staged: staged.dir).errors.isEmpty)
        // A link inside the source folder is refused at staging (never copied, never followed).
        let g = try PluginFixture()
        try FileManager.default.createSymbolicLink(at: g.root.appending(path: "skills/demo/ref"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        #expect(throws: ExtensionError.self) { try ExtensionImporter.stage(source: .folder(g.root), paths: try paths()) }
    }
}
