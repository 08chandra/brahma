import Foundation

/// The hosting and deploy tools (Plan L: `set_deploy_config` Task 4, `set_smoke_check` Task 5, `propose_deploy` Task 6). The
/// names are in `CompanyToolNames.ops`, so roles, the high-risk gate and the plan-turn exclusion cover them. Every handler resolves the company
/// from the acting agent only, and none of them deploys anything: only the engine's release executor does, after the owner.
extension CompanyTools {
    static let notAvailableYet = "is not available yet"

    static func deployToolSpecs() -> [ToolSpec] {
        let strings: JSONValue = .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                          "description": .string("Smoke requests after a deploy, like \"GET / 200\" or \"POST /api/items {json} 201\" (up to 10)")])
        return [
            ToolSpec(name: "set_deploy_config", description: """
                Set how a release of this company's site is built and checked: the build command (run sandboxed in a clean \
                export of the release commit), the output folder to upload (a subfolder such as dist), smoke requests and the \
                text the home page must contain. The owner chooses the provider and project; deploying needs the owner's approval.
                """, inputSchema: schema([
                    "build": prop("string", "Build command, e.g. npm ci && npm run build (omit when the output folder is committed)"),
                    "output_dir": prop("string", "The folder to upload, relative to the repo, e.g. dist or site/public"),
                    "smoke": strings,
                    "expect_text": prop("string", "Text the deployed home page must contain (at most 200 characters)"),
                ], required: ["output_dir"])),
            ToolSpec(name: "set_smoke_check", description: """
                Set the smoke check the engine runs on every new main (sandboxed, in a clean export of main) and before every \
                deploy, e.g. npm ci && npm test. While it fails main is red: the engine files a bug and deploys are blocked. \
                Pass clear: true to remove it (deploys then need a new one).
                """, inputSchema: schema([
                    "command": prop("string", "The shell command; exit 0 means main is green"),
                    "timeout_seconds": prop("integer", "Timeout in seconds (default 600, at most 3600)"),
                    "clear": prop("boolean", "Remove the smoke check instead"),
                ], required: [])),
            ToolSpec(name: "propose_deploy", description: """
                Propose deploying the current main as a release, for the owner's approval. The engine records the exact deploy \
                and rollback commands; once the owner approves it builds (sandboxed), smoke-checks main, deploys and checks the \
                site. Needs set_deploy_config, a passing set_smoke_check on main and the owner's hosting token.
                """, inputSchema: schema([
                    "version": prop("string", "Release version, e.g. 0.1.0 (1–32 letters, digits, '.', '+' or '-'; unique)"),
                    "notes": prop("string", "Release notes for the owner: what changed"),
                ], required: ["version"])),
        ]
    }

    /// Runs a deploy tool, or returns nil when `name` is not one.
    func dispatchDeploy(_ name: String, _ args: [String: JSONValue]) throws -> String? {
        do {
            switch name {
            case "set_deploy_config": return try setDeployConfig(args)
            case "set_smoke_check": return try setSmokeCheck(args)
            case "propose_deploy": return try proposeDeploy(args)
            default: return nil
            }
        } catch let e as WorkError {
            throw ToolError(message: e.message)
        }
    }

    // MARK: Tools

    private func proposeDeploy(_ args: [String: JSONValue]) throws -> String {
        let version = try string(args, "version")
        let notes = try optionalString(args, "notes")
        let (release, _) = try store.proposeDeploy(companyId: companyId, by: agentId, version: version, notes: notes)
        return Store.proposedDeployText(release)
    }

    private func setSmokeCheck(_ args: [String: JSONValue]) throws -> String {
        if let clear = args["clear"], clear != .null {
            guard let flag = clear.boolValue else { throw ToolError(message: "argument clear must be a boolean") }
            if flag {
                try store.setSmokeCheck(companyId: companyId, by: agentId, check: nil)
                return "Smoke check cleared; deploys are blocked until one is set."
            }
        }
        var spec = CheckSpec(command: try string(args, "command"))
        if let t = args["timeout_seconds"], t != .null {
            guard let n = t.numberValue, n.isFinite, n == n.rounded(), abs(n) < 1e9 else {
                throw ToolError(message: "argument timeout_seconds must be an integer")
            }
            spec.timeoutSeconds = Int(n)
        }
        let company = try store.setSmokeCheck(companyId: companyId, by: agentId, check: spec)
        let shown = Store.flat(company.smokeCheck?.command ?? spec.command, max: 200)
        return "Smoke check set: \(shown) (timeout \(spec.timeoutSeconds)s). The engine runs it on every new main and before every deploy."
    }

    private func setDeployConfig(_ args: [String: JSONValue]) throws -> String {
        let outputDir = try string(args, "output_dir").trimmingCharacters(in: .whitespaces)
        let build = try optionalString(args, "build")
        let expectText = try optionalString(args, "expect_text")
        let smoke = try args["smoke"].map { v -> [SmokeRequest] in
            guard v != .null else { return [] }
            return try stringArray(args, "smoke").map(SmokeRequest.parse)
        } ?? []
        let s = try store.setDeployConfig(companyId: companyId, by: agentId, build: build, outputDir: outputDir, smoke: smoke,
                                          expectText: expectText)
        let shownBuild = s.build.map { Store.flat($0, max: 200) } ?? "none"
        return "Deploy config set: build \(shownBuild), output \(s.outputDir ?? outputDir), \(s.provider.title) project \(s.project)."
    }
}
