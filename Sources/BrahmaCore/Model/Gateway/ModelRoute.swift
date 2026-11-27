import Foundation

/// Which provider and model serve a model class for a company, a role or an agent (`modelRoute`, `"vX1-gateway"`).
public struct ModelRoute: Codable, Equatable, Sendable {
    public var companyId: String
    public var scope: RouteScope
    /// `""` for `.company`; the role id for `.role`; the agent id for `.agent`.
    public var subject: String
    /// The model class (`ModelClass.rawValue`, or a class a later plan adds).
    public var modelClass: String
    public var provider: String
    public var model: String

    public init(companyId: String, scope: RouteScope, subject: String, modelClass: String, provider: String, model: String) {
        self.companyId = companyId; self.scope = scope; self.subject = subject; self.modelClass = modelClass
        self.provider = provider; self.model = model
    }
}

public enum RouteScope: String, Codable, Sendable, CaseIterable {
    case company, role, agent
}
