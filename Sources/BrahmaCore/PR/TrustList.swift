import Foundation

/// The owner's trusted provider logins of one company (`trustedLogin`, Task 1), as the engine asks about them (Ruling 10; spec
/// §9.4): a PR review or an issue by a listed login is owner-trusted text, anything else EXTERNAL. Logins compare
/// case-insensitively (Ruling 25: GitHub logins are case-insensitive, so `Alice` and `alice` are one account); `Store` stores
/// new rows normalized (`normalize`) and compares older ones the same way. Task 6 adds the seed login and `isTrusted(commit:)`.
public struct TrustList: Equatable, Sendable {
    private let logins: Set<String>

    public init(logins: [String]) {
        self.logins = Set(logins.filter(Self.isASCII).map(Self.normalize).filter { !$0.isEmpty })
    }

    /// Whether `login` is on the list. An empty login never is, nor one with a non-ASCII character (fix round 1: Unicode case
    /// folding maps look-alikes such as U+212A KELVIN SIGN onto ASCII letters; GitHub logins are ASCII).
    public func isTrusted(login: String) -> Bool {
        let key = Self.normalize(login)
        return !key.isEmpty && Self.isASCII(login) && logins.contains(key)
    }

    /// Every scalar is ASCII.
    public static func isASCII(_ login: String) -> Bool { login.unicodeScalars.allSatisfy(\.isASCII) }

    /// The form logins are stored and compared in: trimmed and lowercased.
    public static func normalize(_ login: String) -> String {
        login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
