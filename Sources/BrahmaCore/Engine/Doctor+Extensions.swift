import Foundation

extension Doctor {
    /// `plugin-details-inert` (Task 5a, extensions §7.2 T1b): `claude plugin details` on a fixture plugin that declares a
    /// SessionStart hook and an MCP server, run under the sandboxed runner with hooks off and no network. Neither part may run:
    /// the hook's command and the server's command would each leave a marker file, and the item fails if either appears.
    static func pluginDetailsItem(claudePath: String, sandbox: any SandboxedRunner) async -> DoctorItem {
        let name = "plugin-details-inert"
        let scratch = FileManager.default.temporaryDirectory.appending(path: "brahma-doctor-plugin-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let plugin = scratch.appending(path: "plugin", directoryHint: .isDirectory)
        let hookMarker = scratch.appending(path: "HOOK-RAN").path, mcpMarker = scratch.appending(path: "MCP-RAN").path
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (path, text) in [
                (".claude-plugin/plugin.json", #"{"name": "doctor-fixture", "version": "1.0.0", "description": "Doctor fixture.", "author": {"name": "Brahma"}}"#),
                ("hooks/hooks.json", #"{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "touch \#(hookMarker)"}]}]}}"#),
                (".mcp.json", #"{"mcpServers": {"fixture": {"command": "touch", "args": ["\#(mcpMarker)"]}}}"#),
                ("skills/doctor-fixture/SKILL.md", "---\nname: doctor-fixture\ndescription: Doctor fixture.\n---\nNothing.\n"),
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
        var readable: [URL] = []
        let binDir = URL(fileURLWithPath: claudePath).resolvedForSandbox.deletingLastPathComponent()
        if binDir.path != "/" { readable.append(binDir) }
        let command = ExtensionValidator.claudeCommand(claudePath, ["details"], plugin: plugin.path)
        let out = await sandbox.run(command: command, cwd: scratch, environment: env, timeout: .seconds(120),
                                    outputURL: scratch.appending(path: "details.log"),
                                    policy: SandboxPolicy(writable: [scratch], readable: readable, network: .none, toolchain: false))
        let ran = [("hook", hookMarker), ("MCP server", mcpMarker)].filter { FileManager.default.fileExists(atPath: $0.1) }.map(\.0)
        if !ran.isEmpty {
            return DoctorItem(name: name, status: .fail, detail: "claude plugin details ran the fixture's \(ran.joined(separator: " and ")); "
                              + "plugin inspection is not inert on this CLI, so extension installs are unsafe")
        }
        guard out.exitCode != nil else {
            return DoctorItem(name: name, status: .warn, detail: "claude plugin details could not run under the sandbox: \(Store.flat(out.tail, max: 200))")
        }
        return DoctorItem(name: name, status: .pass, detail: "claude plugin details on a plugin with a hook and an MCP server ran neither")
    }
}
