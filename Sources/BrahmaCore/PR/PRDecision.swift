import Foundation

/// Allowed with a value, or refused with a reason shown to the owner (Ruling 12: this tree has no generic `Decision<T>`).
public enum PRDecision<T> {
    case allowed(T)
    case refused(String)

    public var value: T? {
        if case .allowed(let v) = self { return v }
        return nil
    }

    public var refusal: String? {
        if case .refused(let why) = self { return why }
        return nil
    }
}

extension PRDecision: Equatable where T: Equatable {}
extension PRDecision: Sendable where T: Sendable {}
