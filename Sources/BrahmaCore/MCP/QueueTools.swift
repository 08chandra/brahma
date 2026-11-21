import Foundation

/// The merge queue's agent tool (Plan 4a Task 2), `set_main_check`, and Task 6's `publish_artifact` (below). The company is always the acting agent's. The engine is
/// the referee: nothing here writes a merge request, a run, a batch or `main`; the tool only changes which command the engine
/// runs on every candidate, and the store refuses everyone but the roles covering `cto`. The owner is told of every change, and
/// a tainted session is refused it (`TaintPolicy.reviewedHighRisk`).
extension CompanyTools {
    static func queueToolSpecs() -> [ToolSpec] {
        [
            ToolSpec(name: "set_main_check", description: """
                Set the check the engine runs on every merge candidate before it lands on main, or clear it. Only the CTO sets it. \
                It runs in a fresh, sandboxed export of the candidate with the merge queue's own environment, before each item's \
                own check; when it fails with only the first request in the candidate and also on main itself, the queue is held \
                and nobody is blamed. The owner is told whenever it changes. Pass "none" as the command to clear it.
                """, inputSchema: schema([
                    "command": prop("string", "Shell command that exits 0 when main stays green, e.g. make test; or none to clear the check"),
                    "timeout": prop("integer", "Seconds the check may run (1–3600, default 600)"),
                ], required: ["command"])),
            ToolSpec(name: "publish_artifact", description: """
                Publish a file or folder from your worktree (or the workspace) as an artifact the owner and the team see in the \
                preview pane: HTML, Markdown, PDF, images, tables, spreadsheets, documents, 3D models, CAD files, video, text or \
                code. The engine copies it under .brahma/artifacts and names it AR-<n>. A folder needs index.html; a .gltf brings \
                the files next to it that it names. Only regular files inside the workspace; at most 50 MB a file (500 MB a video).
                """, inputSchema: schema([
                    "path": prop("string", "The file or folder, relative to your worktree, e.g. mock/index.html"),
                    "title": prop("string", "A short title (at most 120 characters)"),
                    "item": prop("string", "The work item it belongs to, e.g. ACME-12 (optional)"),
                ], required: ["path", "title"])),
        ]
    }

    /// Runs a queue tool, or returns nil when `name` is not one.
    func dispatchQueue(_ name: String, _ args: [String: JSONValue]) throws -> String? {
        do {
            switch name {
            case "set_main_check": return try setMainCheck(args)
            case "publish_artifact": return try publishArtifact(args)
            default: return nil
            }
        } catch let e as WorkError {
            throw ToolError(message: e.message)
        }
    }

    /// `publish_artifact {path, title, item?}`: the path is taken from the agent's own leased worktree, else the workspace.
    /// Every check is the store's (`Store.publishArtifact`); there is no URL argument.
    private func publishArtifact(_ args: [String: JSONValue]) throws -> String {
        let path = try string(args, "path"), title = try string(args, "title"), item = try optionalString(args, "item")
        guard let company = try store.company(id: companyId) else { throw ToolError(message: "no such company") }
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        var base = workspace
        if let lease = try store.lease(agentId: agentId), lease.companyId == companyId, let held = try store.workItem(id: lease.itemId),
           held.companyId == companyId {
            base = store.gitWorkspace(root: workspace, companyId: companyId).worktreePath(key: held.key)
        }
        let artifact = try store.publishArtifact(companyId: companyId, by: .agent(agentId), sourcePath: path, title: title,
                                                 itemKey: item, baseDirectory: base)
        return artifact.publishedLine
    }

    private func setMainCheck(_ args: [String: JSONValue]) throws -> String {
        let command = try string(args, "command").trimmingCharacters(in: .whitespacesAndNewlines)
        if command.lowercased() == "none" {
            try store.setMainCheck(companyId: companyId, by: agentId, check: nil)
            return "Main check cleared."
        }
        var timeout = 600
        if let value = args["timeout"], value != .null {
            guard let n = value.numberValue, n.isFinite, n == n.rounded(), abs(n) < 1_000_000_000 else {
                throw ToolError(message: "argument timeout must be an integer")
            }
            timeout = Int(n)
        }
        let spec = CheckSpec(command: command, timeoutSeconds: timeout)
        guard let set = try store.setMainCheck(companyId: companyId, by: agentId, check: spec) else { return "Main check cleared." }
        return "Main check set: \(Store.flat(set.command, max: 200))."
    }
}
