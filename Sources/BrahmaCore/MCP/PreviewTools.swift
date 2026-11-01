import Foundation

/// The preview tools (Plan L, Task 2): `set_preview_command`. Registered from `CompanyTools` like the other groups; the company
/// is always the acting agent's (`companyId` is checked against the agent on every call), never an argument. Roles: the pack's
/// `ops` list (`CompanyToolNames.ops`); the role filter in `CompanyTools.call` refuses everyone else.
extension CompanyTools {
    static func previewToolSpecs() -> [ToolSpec] {
        let strings: JSONValue = .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                          "description": .string("Up to 10 smoke requests, e.g. \"GET /health 200\" or \"POST /items {json} 201\"")])
        return [
            ToolSpec(name: "set_preview_command", description: """
                Set (or remove) one of the company's previews: a web server the engine builds from main in a fresh sandboxed \
                export and keeps running on a loopback port, restarted when main moves. run and url are required; write {port} \
                where the engine's port goes (e.g. "PORT={port} npm start" and "http://127.0.0.1:{port}/"). The engine builds it \
                from main; nothing starts in this turn. At most 8 previews per company.
                """, inputSchema: schema([
                    "name": prop("string", "Preview name: lowercase letters, digits and dashes (max 24), e.g. web"),
                    "kind": prop("string", "web (the only kind yet)"),
                    "run": prop("string", "Shell command that starts the server, listening on {port} (1–2000 characters)"),
                    "url": prop("string", "Where it answers: http://127.0.0.1:{port}/ (or localhost, [::1]; a literal port is allowed but not shared)"),
                    "build": prop("string", "Optional shell command run first, e.g. npm ci && npm run build"),
                    "smoke": strings,
                    "remove": prop("boolean", "true removes the preview named name instead"),
                ], required: ["name", "kind"])),
        ]
    }

    /// Runs a preview tool, or returns nil when `name` is not one.
    func dispatchPreview(_ name: String, _ args: [String: JSONValue]) throws -> String? {
        do {
            switch name {
            case "set_preview_command": return try setPreviewCommand(args)
            default: return nil
            }
        } catch let e as WorkError {
            throw ToolError(message: e.message)
        }
    }

    // MARK: Tools

    private func setPreviewCommand(_ args: [String: JSONValue]) throws -> String {
        let name = try string(args, "name").trimmingCharacters(in: .whitespaces)
        if let remove = args["remove"], remove != .null {
            guard let flag = remove.boolValue else { throw ToolError(message: "argument remove must be a boolean") }
            if flag {
                let gone = try store.removePreviewSurface(companyId: companyId, name: name, by: .agent(agentId))
                return "Preview \(gone.name) removed."
            }
        }
        let kind = try string(args, "kind").trimmingCharacters(in: .whitespaces).lowercased()
        let draft = PreviewDraft(name: name, kind: kind, run: try optionalString(args, "run"), url: try optionalString(args, "url"),
                                 build: try optionalString(args, "build"), smoke: try optionalStringArray(args, "smoke"))
        let surface = try store.upsertPreviewSurface(companyId: companyId, by: .agent(agentId), draft)
        return "Preview \(surface.name) (\(surface.kind)) set; the engine builds it from main."
    }

    /// An optional array-of-strings argument; absent or null is empty.
    func optionalStringArray(_ args: [String: JSONValue], _ key: String) throws -> [String] {
        guard let v = args[key], v != .null else { return [] }
        return try stringArray(args, key)
    }
}
