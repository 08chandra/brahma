import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One engine child that leads its own process group (a check's shell or `sandbox-exec`, a merge's git), as the engine
/// recorded it at spawn: `<runDir>/children/<kind>-<pid>-<tag>.group` (0600, written like `TurnRecords`). The record goes
/// once the child is reaped. `brahma stop` and the app's STOP EVERYTHING read these (`EmergencyStop.recordedGroups`) and
/// signal the groups themselves, so a wedged engine cannot keep a check or a merge running (Task 7c fix round 1, S15).
struct ChildGroupRecord: Codable, Equatable, Sendable {
    var leader: pid_t
    var leaderStart: Double
    var kind: String
}

/// Where and as what an engine child is recorded. `current` is how a check's runner learns it (the orchestrator sets it
/// around the run; `GroupRun` records the leader it spawns); a merge's git gets it through `GitWorkspace.childGroups`.
public struct ChildGroups: Sendable {
    public let dir: URL
    public let kind: String
    /// Tests only: told after each record is written (with the leader) and after it is removed.
    var observer: (@Sendable (Event) -> Void)?

    enum Event: Equatable, Sendable { case recorded(pid_t), forgotten(pid_t) }

    @TaskLocal static var current: ChildGroups?

    public init(dir: URL, kind: String) {
        self.dir = dir; self.kind = kind
    }

    /// `<runDir>/children`.
    public static func directory(runDir: URL) -> URL { runDir.appending(path: "children", directoryHint: .isDirectory) }

    /// Records a leader just spawned (its start time is its identity). A record that cannot be written is not fatal: the
    /// engine's own cancellation still reaches the child; only the engine-less stop would miss it.
    func record(_ pid: pid_t) -> URL? {
        guard pid > 1, kind.range(of: "^[a-z]{1,16}$", options: .regularExpression) != nil,
              let entry = ProcessTable.entry(pid) else { return nil }
        let url = dir.appending(path: "\(kind)-\(pid)-\(UUID().uuidString.prefix(8)).group")
        do {
            try SettingsFile.writePrivate(try JSONEncoder().encode(ChildGroupRecord(leader: pid, leaderStart: entry.start, kind: kind)), to: url)
        } catch { return nil }
        observer?(.recorded(pid))
        return url
    }

    /// The child was reaped: its record goes (never through a link).
    func forget(_ url: URL?, pid: pid_t) {
        guard let url else { return }
        unlink(url.path)
        observer?(.forgotten(pid))
    }

    /// The leaders recorded in `dir` that are still the process that was recorded (same pid and start time): a reused pid
    /// never counts. Read without following links; a damaged record is skipped.
    static func liveLeaders(in dir: URL) -> Set<Int32> {
        var out = Set<Int32>()
        for record in records(in: dir) {
            if let entry = ProcessTable.entry(record.value.leader), entry.start == record.value.leaderStart, !entry.isZombie {
                out.insert(record.value.leader)
            }
        }
        return out
    }

    /// Start-up: records whose leader is gone (or is another process now) are removed.
    static func removeStale(in dir: URL) {
        for record in records(in: dir) {
            let entry = ProcessTable.entry(record.value.leader)
            if entry == nil || entry?.start != record.value.leaderStart { unlink(record.url.path) }
        }
    }

    private static func records(in dir: URL) -> [(url: URL, value: ChildGroupRecord)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".group") && !$0.hasPrefix(".") }.compactMap { name in
            let url = dir.appending(path: name)
            var st = stat()
            guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_size < 4096,
                  let data = FileManager.default.contents(atPath: url.path),
                  let value = try? JSONDecoder().decode(ChildGroupRecord.self, from: data), value.leader > 1 else { return nil }
            return (url, value)
        }
    }
}
