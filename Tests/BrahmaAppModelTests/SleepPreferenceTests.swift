import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite struct SleepPreferenceTests {
    @Test func menuToggleReadsAndWritesTheOwnerPref() async throws {
        let w = try await WorkWorld.make()
        #expect(w.model.preventSleep)                                    // on by default
        await w.model.setPreventSleep(false)
        #expect(!w.model.preventSleep)
        #expect(try !w.store.ownerPrefs().preventSleep)
        // Changed elsewhere (`brahma prefs set prevent-sleep on`): the next tick shows it.
        var prefs = try w.store.ownerPrefs(); prefs.preventSleep = true
        try w.store.updateOwnerPrefs(prefs)
        await w.model.tick()
        #expect(w.model.preventSleep)
        // The rest of the prefs are untouched by the toggle.
        prefs.quietStart = "21:30"
        try w.store.updateOwnerPrefs(prefs)
        await w.model.setPreventSleep(false)
        #expect(try w.store.ownerPrefs().quietStart == "21:30")
    }
}
