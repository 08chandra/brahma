import Foundation

/// The hosting and deploy tools (Plan L: `set_deploy_config` Task 4, `set_smoke_check` Task 5, `propose_deploy` Task 6). Until
/// their tasks land every one answers `"<tool> is not available yet"` (PR-20); the names are already in `CompanyToolNames.ops`
/// so roles, the high-risk gate and the plan-turn exclusion cover them from the start.
extension CompanyTools {
    static let notAvailableYet = "is not available yet"

    static func deployToolSpecs() -> [ToolSpec] {
        [
            ToolSpec(name: "set_deploy_config", description: "Configure where the company's site deploys (not available yet).",
                     inputSchema: schema([:], required: [])),
            ToolSpec(name: "set_smoke_check", description: "Set the smoke requests run against main and every deploy (not available yet).",
                     inputSchema: schema([:], required: [])),
            ToolSpec(name: "propose_deploy", description: "Propose a deploy of main for the owner's approval (not available yet).",
                     inputSchema: schema([:], required: [])),
        ]
    }

    /// Runs a deploy tool, or returns nil when `name` is not one.
    func dispatchDeploy(_ name: String, _ args: [String: JSONValue]) throws -> String? {
        switch name {
        case "set_deploy_config", "set_smoke_check", "propose_deploy": throw ToolError(message: "\(name) \(Self.notAvailableYet)")
        default: return nil
        }
    }
}
