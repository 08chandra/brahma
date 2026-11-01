import Foundation

extension Doctor {
    /// `plugin-details-inert` (Task 5a, extensions §7.2 T1b): `claude plugin details` on a fixture plugin that declares a
    /// SessionStart hook (`hooks/hooks.json`), an MCP server (`.mcp.json`), a skill-frontmatter hook and an agent-frontmatter MCP
    /// server, run under the sandboxed runner with hooks off and no network, with the hardened global options before the
    /// subcommand. None of the four may run (each would leave a marker file), and the item passes only when the CLI exited 0 AND
    /// reported the fixture loaded (its `@inline` source, the hook and the MCP server counted). A CLI that refuses the options or
    /// prints no inventory warns: it proved nothing.
    public static func pluginDetailsItem(claudePath: String, sandbox: any SandboxedRunner) async -> DoctorItem {
        let name = "plugin-details-inert"
        let scratch = FileManager.default.temporaryDirectory.appending(path: "brahma-doctor-plugin-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let plugin = scratch.appending(path: "plugin", directoryHint: .isDirectory)
        let markers = ["hook": "HOOK-RAN", "MCP server": "MCP-RAN", "skill-frontmatter hook": "SKILL-HOOK-RAN", "agent-frontmatter MCP server": "AGENT-MCP-RAN"]
            .mapValues { scratch.appending(path: $0).path }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (path, text) in [
                (".claude-plugin/plugin.json", #"{"name": "doctor-fixture", "version": "1.0.0", "description": "Doctor fixture.", "author": {"name": "Brahma"}}"#),
                ("hooks/hooks.json", #"{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "touch \#(markers["hook"]!)"}]}]}}"#),
                (".mcp.json", #"{"mcpServers": {"fixture": {"command": "touch", "args": ["\#(markers["MCP server"]!)"]}}}"#),
                ("skills/doctor-fixture/SKILL.md", "---\nname: doctor-fixture\ndescription: Doctor fixture.\nhooks:\n  SessionStart:\n    - hooks:\n        - type: command\n"
                    + "          command: \"touch \(markers["skill-frontmatter hook"]!)\"\n---\nNothing.\n"),
                ("agents/helper.md", "---\nname: helper\ndescription: Helper.\nmcpServers:\n  m:\n    command: touch\n    args: [\"\(markers["agent-frontmatter MCP server"]!)\"]\n---\nHelp.\n"),
            ] {
                let url = plugin.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
            for dir in ["cc", "home"] { try FileManager.default.createDirectory(at: scratch.appending(path: dir), withIntermediateDirectories: true) }
        } catch {
            return DoctorItem(name: name, status: .warn, detail: "can't prepare the fixture: \(error)")
        }
        var env = ChildEnvironment.make(base: ProcessInfo.processInfo.environment, purpose: .general)
        env["HOME"] = scratch.appending(path: "home").path
        env["CLAUDE_CONFIG_DIR"] = scratch.appending(path: "cc").path
        env.removeValue(forKey: "TMPDIR")
        guard let readable = ExtensionValidator.readableClaudeDirectory(claudePath, userHome: ExtensionImporter.ownerHome()) else {
            return DoctorItem(name: name, status: .warn, detail: "the claude binary at \(claudePath) sits in a directory the sandbox may not read whole")
        }
        let command = ExtensionValidator.claudeCommand(claudePath, ["--plugin-dir", plugin.path, "plugin", "details", "doctor-fixture"])
        let out = await sandbox.run(command: command, cwd: scratch, environment: env, timeout: .seconds(120),
                                    outputURL: scratch.appending(path: "details.log"),
                                    policy: SandboxPolicy(writable: [scratch], readable: readable, network: .none, toolchain: false))
        let ran = markers.filter { FileManager.default.fileExists(atPath: $0.value) }.keys.sorted()
        if !ran.isEmpty {
            return DoctorItem(name: name, status: .fail, detail: "claude plugin details ran the fixture's \(ran.joined(separator: ", ")); "
                              + "plugin inspection is not inert on this CLI, so extension installs are unsafe")
        }
        guard let code = out.exitCode else {
            return DoctorItem(name: name, status: .warn, detail: "claude plugin details could not run under the sandbox: \(Store.flat(out.tail, max: 200))")
        }
        guard code == 0 else {
            return DoctorItem(name: name, status: .warn, detail: "claude plugin details exited \(code) and proved nothing: \(Store.flat(out.tail, max: 200))")
        }
        let shows = out.tail.contains("doctor-fixture@inline") && out.tail.contains("Hooks (1)") && out.tail.contains("MCP servers (1)")
        guard shows else {
            return DoctorItem(name: name, status: .warn, detail: "claude plugin details did not report the fixture's hook and MCP server as loaded; "
                              + "nothing was proven: \(Store.flat(out.tail, max: 200))")
        }
        return DoctorItem(name: name, status: .pass, detail: "claude plugin details loaded a plugin with a hook and an MCP server (four forms) and ran none of them")
    }
}
