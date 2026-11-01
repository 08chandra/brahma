import Foundation

/// The hosting and deploy tools (Plan L: `set_deploy_config` Task 4, `set_smoke_check` Task 5, `propose_deploy` Task 6). Until
/// their tasks land the others answer `"<tool> is not available yet"` (PR-20); the names are already in `CompanyToolNames.ops`
/// so roles, the high-risk gate and the plan-turn exclusion cover them from the start. Every handler resolves the company
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
            ToolSpec(name: "set_smoke_check", description: "Set the smoke requests run against main and every deploy (not available yet).",
                     inputSchema: schema([:], required: [])),
            ToolSpec(name: "propose_deploy", description: "Propose a deploy of main for the owner's approval (not available yet).",
                     inputSchema: schema([:], required: [])),
        ]
    }

    /// Runs a deploy tool, or returns nil when `name` is not one.
    func dispatchDeploy(_ name: String, _ args: [String: JSONValue]) throws -> String? {
        do {
            switch name {
            case "set_deploy_config": return try setDeployConfig(args)
            case "set_smoke_check", "propose_deploy": throw ToolError(message: "\(name) \(Self.notAvailableYet)")
            default: return nil
            }
        } catch let e as WorkError {
            throw ToolError(message: e.message)
        }
    }

    // MARK: Tools

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
