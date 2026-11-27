import Foundation

/// A per-turn gateway token (Plan X1 Task 7): 32 random bytes as 64 lowercase hex characters, given to one `claude` turn as its
/// `ANTHROPIC_API_KEY` and accepted by the gateway as `x-api-key` or `Authorization: Bearer`. It is a bearer credential: its
/// description and dump never show the value, so string interpolation cannot log it.
public struct GatewayToken: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let value: String

    init(value: String) { self.value = value }

    /// A fresh token from the system CSPRNG (`SystemRandomNumberGenerator`: `arc4random_buf` on Darwin, `getrandom` on Linux).
    public static func mint() -> GatewayToken {
        var rng = SystemRandomNumberGenerator()
        var hex = ""
        hex.reserveCapacity(64)
        for _ in 0..<4 {
            let word = rng.next() as UInt64
            for shift in stride(from: 60, through: 0, by: -4) {
                hex.unicodeScalars.append(Self.digits[Int((word >> UInt64(shift)) & 0xf)])
            }
        }
        return GatewayToken(value: hex)
    }

    /// The one token shape (`TurnTokenFormat`, shared with `ChildEnvironment.make(gateway:)`).
    public static func isWellFormed(_ s: String) -> Bool { TurnTokenFormat.isWellFormed(s) }

    private static let digits = Array("0123456789abcdef".unicodeScalars)

    public var description: String { "GatewayToken(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
