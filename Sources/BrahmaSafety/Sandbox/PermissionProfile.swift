import Foundation

/// How much of the Mac an agent's turn may touch. `sandboxed` (5-lite, the default for new companies) confines every turn to
/// the `SandboxScope` the engine computes for it; `workspace` is 3a's permission-prompt profile; `full` is the whole Mac.
public enum PermissionProfile: String, Codable, Sendable, CaseIterable {
    case workspace, full, sandboxed

    /// How much of the Mac it opens: sandboxed < workspace (the agent's Bash is unconfined) < full.
    public var breadth: Int {
        switch self {
        case .sandboxed: 0
        case .workspace: 1
        case .full: 2
        }
    }

    /// The narrower of two profiles (an engine ceiling narrows a company's profile, never widens it).
    public static func narrower(_ a: PermissionProfile, _ b: PermissionProfile) -> PermissionProfile { a.breadth <= b.breadth ? a : b }
}
