import Foundation

/// An owner-set price for one provider's model, USD per million tokens (`priceRow`, `"vX1-gateway"`). Pinned prices live in
/// code (`PriceBook.pinned`, Task 6); an owner row wins over a pinned one.
public struct PriceRow: Codable, Equatable, Sendable {
    public var provider: String
    public var model: String
    public var inPerMTok: Double
    public var outPerMTok: Double
    public var cacheReadPerMTok: Double?
    public var cacheWritePerMTok: Double?
    /// Who set it (`owner`).
    public var setBy: String

    public init(provider: String, model: String, inPerMTok: Double, outPerMTok: Double, cacheReadPerMTok: Double? = nil,
                cacheWritePerMTok: Double? = nil, setBy: String) {
        self.provider = provider; self.model = model; self.inPerMTok = inPerMTok; self.outPerMTok = outPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok; self.cacheWritePerMTok = cacheWritePerMTok; self.setBy = setBy
    }
}
