import Foundation
import BrahmaCore

extension AppModel {
    /// Reads the owner's `preventSleep` pref (a single-row read, off the main actor).
    func refreshPreventSleep() async {
        let store = self.store
        guard let value = try? await Task.detached(operation: { try store.ownerPrefs().preventSleep }).value else { return }
        if value != preventSleep { preventSleep = value }
    }

    /// Writes `preventSleep` through the prefs API; the engine reads it on its next tick.
    public func setPreventSleep(_ enabled: Bool) async {
        let store = self.store
        do {
            try await Task.detached {
                var prefs = try store.ownerPrefs()
                prefs.preventSleep = enabled
                try store.updateOwnerPrefs(prefs)
            }.value
            preventSleep = enabled
        } catch {
            report(error)
        }
    }
}
