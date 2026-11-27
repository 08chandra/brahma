import Foundation
import BrahmaCore

/// The secret sheet's fields. The value goes to the vault only (`Store.setSecret`), never to the database or a log.
public struct SecretsForm: Equatable, Sendable {
    public static let testKeyCaption = "Test keys are given to agents as environment variables. Other keys stay with the engine."

    public var name = ""
    public var value = ""
    /// A test key may be handed to an agent's environment for the item it works on; any other secret is engine-held.
    public var isTest = false

    public init(name: String = "", value: String = "", isTest: Bool = false) {
        self.name = name
        self.value = value
        self.isTest = isTest
    }

    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }

    /// Why the form cannot be saved, or nil.
    public func validate() -> String? {
        let name = trimmedName
        guard SecretName.isValid(name) else {
            return "Name: A-Z, 0-9 and _, starting with a letter, 2 to 64 characters (for example STRIPE_TEST_KEY)."
        }
        if isTest, SecretName.engineOnly.contains(name) {
            return "\(name) is engine-only: it is never put in an agent's environment. Turn off Test key."
        }
        if isTest, !SecretName.isInjectable(name) {
            return "A test key's name must contain KEY, TOKEN or SECRET and not be a variable the shell or Claude reads."
        }
        guard !value.isEmpty else { return "Enter the value." }
        return nil
    }
}
