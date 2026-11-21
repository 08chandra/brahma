import Foundation

/// The volatile defaults suite a harness run gives the map (spec §4.3): `brahma.harness.<pid>`, cleared at launch and at
/// exit, so a scripted run never reads or writes the owner's office unlock. Its plist must not pile up: `clear` empties the
/// domain and removes this process's file at exit, but `cfprefsd` writes the emptied domain back about 10 s later (measured
/// on macOS 26; a delete from the client cannot win while the daemon holds a pending write), so `sweep`, at every harness
/// launch, removes the plists of runs that are no longer alive; a delete after the owner is gone sticks. Only files named
/// exactly `brahma.harness.<pid>.plist` are ever touched, and only `kill(pid, 0)` is used, a liveness probe that sends no
/// signal.
public enum HarnessDefaults {
    public static let prefix = "brahma.harness."
    static let fileExtension = ".plist"

    public static func suiteName(pid: Int32) -> String { prefix + String(pid) }

    /// `~/Library/Preferences`, where `UserDefaults(suiteName:)` keeps a suite's plist for an unsandboxed app.
    public static var preferencesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences", directoryHint: .isDirectory)
    }

    /// A fresh suite for `pid`: whatever an earlier process with the same pid left is removed first.
    public static func make(pid: Int32) -> UserDefaults {
        let name = suiteName(pid: pid)
        UserDefaults.standard.removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name)!
    }

    /// Removes `pid`'s suite: its domain, then its plist in `directory` (the preferences daemon may already have written it).
    public static func clear(pid: Int32, directory: URL = preferencesDirectory) {
        let name = suiteName(pid: pid)
        UserDefaults.standard.removePersistentDomain(forName: name)
        UserDefaults(suiteName: name)?.synchronize()
        removePlist(pid: pid, in: directory)
    }

    /// Removes `brahma.harness.<pid>.plist` from `directory`, if it is there.
    static func removePlist(pid: Int32, in directory: URL) {
        let file = directory.appending(path: suiteName(pid: pid) + fileExtension, directoryHint: .notDirectory)
        try? FileManager.default.removeItem(at: file)
    }

    /// The pid of a file named exactly `brahma.harness.<pid>.plist`: canonical decimal digits (no sign, no leading zero), a
    /// positive `Int32`. Anything else is nil: `kill` of 0 or a negative number would mean a process group.
    static func pid(fileName: String) -> Int32? {
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(fileExtension) else { return nil }
        let digits = fileName.dropFirst(prefix.count).dropLast(fileExtension.count)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let pid = Int32(digits), pid > 0,
              String(pid) == digits else { return nil }
        return pid
    }

    /// The harness plists in `directory` whose process is not alive (regular files only; links and folders are left alone).
    public static func stale(in directory: URL, isAlive: (Int32) -> Bool) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        else { return [] }
        return urls.filter { url in
            guard let pid = pid(fileName: url.lastPathComponent),
                  (try? url.resourceValues(forKeys: keys))?.isRegularFile == true else { return false }
            return !isAlive(pid)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Removes the `stale` plists in `directory`; returns the ones removed.
    @discardableResult
    public static func sweep(in directory: URL = preferencesDirectory,
                             isAlive: (Int32) -> Bool = isProcessAlive) -> [URL] {
        stale(in: directory, isAlive: isAlive).filter { (try? FileManager.default.removeItem(at: $0)) != nil }
    }

    /// Whether `pid` is a live process: `kill(pid, 0)` sends no signal. Only ESRCH means gone (EPERM is someone else's
    /// live process).
    public static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return true }
        return kill(pid, 0) == 0 || errno != ESRCH
    }
}
