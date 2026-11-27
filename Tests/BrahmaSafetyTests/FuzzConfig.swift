import Foundation

/// How many cases a property test draws (plan Global Constraints: 500 by default, 10 000 with `BRAHMA_FUZZ=1`) and the fixed
/// seed every draw starts from, so a failure reproduces: the tests print `FuzzConfig.seed` and the case number with every
/// failed expectation. Plan S Task S6 creates it for `PrincipalSetTests`; S15's `PathFuzzTests` reuses it.
enum FuzzConfig {
    static let cases: Int = ProcessInfo.processInfo.environment["BRAHMA_FUZZ"] == "1" ? 10_000 : 500
    static let seed: UInt64 = 0x5EED_0B4A_5AFE_0006

    /// A generator seeded with `seed` (SplitMix64): the same sequence on every run and every platform.
    static func generator() -> SeededGenerator { SeededGenerator(seed: seed) }
}

/// SplitMix64: small, fast, and deterministic for a given seed (the standard library's generator is not seedable).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
