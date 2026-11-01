import Foundation

/// The human-task tool (Plan L, Task 9: `request_human_task`). Until Task 9 lands it answers `"request_human_task is not
/// available yet"` (PR-20); the name is already in `CompanyToolNames.work` so every role lists it.
extension CompanyTools {
    static func humanTaskToolSpecs() -> [ToolSpec] {
        [
            ToolSpec(name: "request_human_task", description: "Ask the owner to do something only a person can (not available yet).",
                     inputSchema: schema([:], required: [])),
        ]
    }

    /// Runs a human-task tool, or returns nil when `name` is not one.
    func dispatchHumanTask(_ name: String, _ args: [String: JSONValue]) throws -> String? {
        switch name {
        case "request_human_task": throw ToolError(message: "\(name) \(Self.notAvailableYet)")
        default: return nil
        }
    }
}
