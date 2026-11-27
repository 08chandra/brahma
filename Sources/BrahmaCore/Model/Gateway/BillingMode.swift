import Foundation

/// How a company's turns are paid for (Plan X1, spec §8.2; `company.billingMode`, `"vX1-gateway"`). `subscription` is the
/// stored default ("personal mode": the owner's own Claude login, conservative pacing); `apiKey` runs every turn through the
/// gateway on a provider key; `fallback` uses the subscription and falls back to a key when it is limited. A new company's
/// default is decided at creation (Ruling 7′, Task 14), never by the column default.
public enum BillingMode: String, Codable, Sendable, CaseIterable {
    case subscription
    case apiKey = "api-key"
    case fallback
}
