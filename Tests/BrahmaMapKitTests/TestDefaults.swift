import Foundation

/// C6 M13 / item 20 (FW-B2): a fresh `UserDefaults` suite for one use (`brahma.tests.<prefix>.<uuid>`), never the standard
/// defaults; every suite made is removed (its domain and its plist in `~/Library/Preferences`) when the test process exits.
enum TestDefaults {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var names: [String] = []
    nonisolated(unsafe) private static var installed = false

    static func make(_ prefix: String) -> UserDefaults {
        let name = "brahma.tests.\(prefix).\(UUID().uuidString)"
        lock.withLock {
            names.append(name)
            if !installed {
                installed = true
                atexit { TestDefaults.removeAll() }
            }
        }
        return UserDefaults(suiteName: name)!
    }

    static func removeAll() {
        let all = lock.withLock { names }
        let prefs = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences")
        for name in all {
            UserDefaults().removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: prefs.appending(path: "\(name).plist"))
        }
    }
}
