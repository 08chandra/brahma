import Foundation

/// A company's spend caps for one provider, in USD (`providerCap`, `"vX1-gateway"`). The day and month are the owner's
/// calendar (`SpendPeriod`).
public struct ProviderCaps: Codable, Equatable, Sendable {
    public var monthlyUSD: Double
    public var dailyUSD: Double

    /// The daily cap when none is given: monthly ÷ 20.
    public static let defaultDailyDivisor: Double = 20

    public init(monthlyUSD: Double, dailyUSD: Double? = nil) {
        self.monthlyUSD = monthlyUSD
        self.dailyUSD = dailyUSD ?? monthlyUSD / Self.defaultDailyDivisor
    }
}

/// A spend window in the owner's time zone.
public enum SpendPeriod: String, Codable, Sendable, CaseIterable {
    case day, month
}
