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
                Set (or remove) one of the company's previews, which the engine builds from main in a fresh sandboxed export \
                and runs again when main moves. Kinds: web and backend (a server on a loopback port: run and url are required; \
                write {port} where the engine's port goes, e.g. "PORT={port} npm start" and "http://127.0.0.1:{port}/"; a \
                backend's smoke requests are its demo), cli (demo is required: a command whose output is shown), ios (build, \
                app_path and bundle_id are required; it runs only after the owner allows the Simulator, which runs outside \
                the sandbox) and macos (build and app_path are required). Paths are relative to the repo root. Nothing starts \
                in this turn. At most 8 previews per company.
                """, inputSchema: schema([
                    "name": prop("string", "Preview name: lowercase letters, digits and dashes (max 24), e.g. web"),
                    "kind": prop("string", "web, backend, cli, ios or macos"),
                    "run": prop("string", "web/backend: shell command that starts the server, listening on {port} (1–2000 characters)"),
                    "url": prop("string", "web/backend: where it answers, http://127.0.0.1:{port}/ (or localhost, [::1]; a literal port is allowed but not shared)"),
                    "build": prop("string", "Shell command run first, e.g. npm ci && npm run build (required for ios and macos)"),
                    "demo": prop("string", "cli: the shell command whose output is the preview (1–2000 characters)"),
                    "openapi_path": prop("string", "backend: its OpenAPI file, relative to the repo root (at most 2 MB)"),
                    "app_path": prop("string", "ios/macos: the built .app, relative to the repo root, e.g. build/Build/Products/Debug/App.app"),
                    "bundle_id": prop("string", "ios: the app's bundle id (letters, digits, '.' and '-')"),
                    "device": prop("string", "ios: the Simulator device type, e.g. iPhone 15 Pro (optional)"),
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
                                 build: try optionalString(args, "build"), smoke: try optionalStringArray(args, "smoke"),
                                 demo: try optionalString(args, "demo"), openapiPath: try optionalString(args, "openapi_path"),
                                 appPath: try optionalString(args, "app_path"), bundleId: try optionalString(args, "bundle_id"),
                                 device: try optionalString(args, "device"))
        let surface = try store.upsertPreviewSurface(companyId: companyId, by: .agent(agentId), draft)
        return "Preview \(surface.name) (\(surface.kind)) set; the engine builds it from main."
    }

    /// An optional array-of-strings argument; absent or null is empty.
    func optionalStringArray(_ args: [String: JSONValue], _ key: String) throws -> [String] {
        guard let v = args[key], v != .null else { return [] }
        return try stringArray(args, key)
    }
}
