import Foundation

/// The owner's trusted provider logins of one company (`trustedLogin`, Task 1), as the engine asks about them (Ruling 10; spec
/// §9.4): a PR review or an issue by a listed login is owner-trusted text, anything else EXTERNAL. Logins compare
/// case-insensitively (Ruling 25: GitHub logins are case-insensitive, so `Alice` and `alice` are one account); `Store` stores
/// new rows normalized (`normalize`) and compares older ones the same way. Task 6 adds the seed login and `isTrusted(commit:)`.
public struct TrustList: Equatable, Sendable {
    private let logins: Set<String>

    public init(logins: [String]) {
        self.logins = Set(logins.map(Self.normalize).filter { !$0.isEmpty })
    }

    /// Whether `login` is on the list. An empty login never is.
    public func isTrusted(login: String) -> Bool {
        let key = Self.normalize(login)
        return !key.isEmpty && logins.contains(key)
    }

    /// The form logins are stored and compared in: trimmed and lowercased.
    public static func normalize(_ login: String) -> String {
        login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
