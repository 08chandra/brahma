import Foundation

public enum FormError: Error, Equatable { case invalid(String) }

public enum AppSheet: String, Identifiable, Sendable {
    case newCompany, hire
    public var id: String { rawValue }
}

public struct CompanyForm: Equatable, Sendable {
    public var name = ""
    public var goal = ""

    public init(name: String = "", goal: String = "") {
        self.name = name
        self.goal = goal
    }

    public func validate() -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Name is required" }
        if goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Goal is required" }
        return nil
    }
}
