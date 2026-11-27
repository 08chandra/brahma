import Foundation

/// What a capability probe found a model can do (spec §8.2.5).
public enum ModelProbeLevel: String, Codable, Sendable {
    case agent, textOnly, unavailable
}

/// One step of a capability probe (filled by Task 13's `ModelProbe`).
public struct ProbeStepResult: Codable, Equatable, Sendable {
    public var step: String
    public var passed: Bool
    /// e.g. `"19/20"`.
    public var score: String
    public var detail: String

    public init(step: String, passed: Bool, score: String, detail: String) {
        self.step = step; self.passed = passed; self.score = score; self.detail = detail
    }
}

/// A probe result, keyed by (provider, model, adapter version, `claude` version) (`modelProbe`, `"vX1-gateway"`).
public struct ModelProbeRecord: Codable, Equatable, Sendable {
    public var provider: String
    public var model: String
    public var adapterVersion: String
    public var cliVersion: String
    public var level: ModelProbeLevel
    public var steps: [ProbeStepResult]
    public var declaredContext: Int?
    public var probedAt: Date

    /// A record older than this is re-probed.
    public static let maxAge: TimeInterval = 30 * 86_400

    public init(provider: String, model: String, adapterVersion: String, cliVersion: String, level: ModelProbeLevel,
                steps: [ProbeStepResult], declaredContext: Int?, probedAt: Date) {
        self.provider = provider; self.model = model; self.adapterVersion = adapterVersion; self.cliVersion = cliVersion
        self.level = level; self.steps = steps; self.declaredContext = declaredContext; self.probedAt = probedAt
    }
}

/// A queued request to probe a model (`modelProbeRequest`, `"vX1-gateway"`); the engine runs the oldest queued one.
public struct ModelProbeRequest: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        case queued, done, failed
    }

    public var id: String
    public var provider: String
    public var model: String
    /// `owner`, `engine` or an agent id.
    public var requestedBy: String
    /// The company whose caps the probe's charges count against; nil for an owner-wide request.
    public var companyId: String?
    public var status: Status
    public var createdAt: Date

    public init(id: String, provider: String, model: String, requestedBy: String, companyId: String?, status: Status,
                createdAt: Date) {
        self.id = id; self.provider = provider; self.model = model; self.requestedBy = requestedBy; self.companyId = companyId
        self.status = status; self.createdAt = createdAt
    }
}
