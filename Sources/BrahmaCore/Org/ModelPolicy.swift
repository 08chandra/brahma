import Foundation

/// The decisions an agent is asked to take in its next turn (`Store.askModelContext`). `ModePolicy.select` (Task 14c) reads it:
/// a PRD or architecture decision runs at R3 on opus. `ModePolicy` replaced the old `ModelPolicy.resolve` for `auto` agents.
public struct ModelContext: Sendable, Equatable {
    public var decidingArchitecture = false
    public var decidingPRD = false

    public init(decidingArchitecture: Bool = false, decidingPRD: Bool = false) {
        self.decidingArchitecture = decidingArchitecture
        self.decidingPRD = decidingPRD
    }
}
