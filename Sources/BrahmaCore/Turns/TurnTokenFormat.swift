import Foundation

/// The shape of a per-turn gateway token (Plan X1 Task 4): exactly 64 lowercase hex characters. `ChildEnvironment.make(gateway:)`
/// drops any other `ANTHROPIC_API_KEY`, and the gateway's own token type reuses this check.
public enum TurnTokenFormat {
    public static func isWellFormed(_ token: String) -> Bool {
        token.utf8.count == 64 && token.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
