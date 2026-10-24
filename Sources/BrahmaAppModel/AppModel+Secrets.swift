import Foundation
import BrahmaCore

extension AppModel {
    /// Updates `secretsBanner` from the store's redactor (in-memory; counts the secrets only while held).
    public func refreshSecrets() {
        secretsBanner = store.secretsHoldText()
    }

    /// The owner's explicit "Load secrets": reads every secret with the interactive store (macOS may ask to allow access),
    /// off the main thread, and signals the engine and `brahma mcp` to retry at once.
    public func loadSecrets() async {
        guard let vault = ownerSecretVault else {
            secretsBanner = "Brahma can't read its secrets: no secret store is available in this app."
            return
        }
        let store = self.store
        let result = await Task.detached { try? store.ownerLoadSecrets(vault: vault) }.value
        refreshSecrets()
        if let result, !result.failed.isEmpty {
            secretsBanner = "Brahma still can't read: " + result.failed.map(\.name).joined(separator: ", ") + ". Agents stay paused."
        }
    }
}
