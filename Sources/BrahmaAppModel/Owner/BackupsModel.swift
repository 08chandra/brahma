import Foundation
import Observation
import BrahmaCore

/// One line of the Backups panel's status block.
public struct BackupStatusLine: Equatable, Sendable {
    public let label: String
    public let value: String
}

/// Settings › Backups: when each backup last ran, the off-machine targets, the optional WAL shipping switch and "back up now".
/// Every call into the engine's backup APIs (file and database work) runs off the main actor; this class only holds results.
@MainActor @Observable
public final class BackupsModel {
    public static let installLitestream = "Install litestream to enable"

    public private(set) var lastHourly: Date?
    public private(set) var lastHome: Date?
    public private(set) var lastTargetSync: Date?
    public private(set) var targets: [BackupTarget] = []
    public private(set) var walReplica: String?
    public private(set) var isBackingUp = false
    /// The last refusal or failure, in words; cleared by the next successful action.
    public private(set) var error: String?
    /// What the last "back up now" did.
    public private(set) var message: String?

    @ObservationIgnored private var store: Store
    @ObservationIgnored private let paths: BrahmaPaths
    @ObservationIgnored private let tools: BackupTools
    @ObservationIgnored private var timeZone: TimeZone

    public init(store: Store, paths: BrahmaPaths, tools: BackupTools = .system) {
        self.store = store
        self.paths = paths
        self.tools = tools
        self.timeZone = TimeZone.current
    }

    public var walEnabled: Bool { walReplica != nil }
    public var litestreamInstalled: Bool { tools.litestream != nil }
    /// Switching it on needs litestream; an already-enabled setting can always be switched off.
    public var walToggleDisabled: Bool { !walEnabled && !litestreamInstalled }
    public var walNote: String? { walToggleDisabled ? Self.installLitestream : nil }

    public var statusLines: [BackupStatusLine] {
        [BackupStatusLine(label: "Last database snapshot", value: text(lastHourly)),
         BackupStatusLine(label: "Last home snapshot", value: text(lastHome)),
         BackupStatusLine(label: "Last off-machine sync", value: text(lastTargetSync))]
    }

    private func text(_ date: Date?) -> String {
        guard let date else { return "never" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    /// Rereads everything shown here.
    public func refresh() async {
        let (store, paths) = (self.store, self.paths)
        struct Read: Sendable {
            var hourly: Date?, home: Date?, sync: Date?, targets: [BackupTarget], replica: String?, zone: TimeZone
        }
        do {
            let read: Read = try await Task.detached {
                let timer = try store.timers(companyId: nil).first { $0.name == "backup.targets" }
                return Read(hourly: BackupService(paths: paths).list().first { $0.reason == .hourly }?.date,
                            home: HomeSnapshot.list(paths: paths).map(\.date).max(),
                            sync: timer?.lastFiredAt, targets: try store.backupTargets(),
                            replica: try store.walShipping()?.replica, zone: store.ownerTimeZone())
            }.value
            lastHourly = read.hourly
            lastHome = read.home
            // A manual sync in this session may be newer than the timer's last fire.
            lastTargetSync = [read.sync, lastTargetSync].compactMap { $0 }.max()
            targets = read.targets
            walReplica = read.replica
            timeZone = read.zone
        } catch {
            self.error = "\(error)"
        }
    }

    // MARK: Targets

    public func addFolder(_ path: String) async {
        await add(.folder(path: path.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    public func addRclone(_ remote: String) async {
        await add(.rclone(remote: remote.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// Validated through `BackupTargets.validate` (the folder exists and is writable, lies outside the data home and every
    /// workspace; a remote is installed and encrypted) before it is stored.
    private func add(_ target: BackupTarget) async {
        let (store, paths, tools) = (self.store, self.paths, self.tools)
        do {
            try await Task.detached {
                let workspaces = try store.companies().map { URL(fileURLWithPath: $0.workspacePath, isDirectory: true) }
                let valid = try BackupTargets.validate(target, paths: paths, workspaces: workspaces, tools: tools)
                try store.addBackupTarget(valid)
            }.value
            error = nil
        } catch {
            self.error = "\(error)"
        }
        await refresh()
    }

    /// Removes the target at the 1-based position `number`, as `brahma backup targets` numbers them.
    public func remove(number: Int) async {
        let store = self.store
        do {
            try await Task.detached { try store.removeBackupTarget(number: number) }.value
            error = nil
        } catch {
            self.error = "\(error)"
        }
        await refresh()
    }

    // MARK: WAL shipping

    /// Switches Litestream WAL shipping on for `replica` (checked like a folder target, or a URL without credentials) or off.
    /// It takes effect when the engine next starts.
    public func setWAL(enabled: Bool, replica: String) async {
        let (store, paths, tools) = (self.store, self.paths, self.tools)
        do {
            try await Task.detached {
                if enabled {
                    guard tools.litestream != nil else { throw WALShippingError.unavailable }
                    let workspaces = try store.companies().map { URL(fileURLWithPath: $0.workspacePath, isDirectory: true) }
                    let valid = try WALShipping.validateReplica(replica.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                paths: paths, workspaces: workspaces)
                    try store.setWALShipping(WALShippingConfig(replica: valid))
                } else {
                    try store.setWALShipping(nil)
                }
            }.value
            error = nil
        } catch {
            self.error = "\(error)"
        }
        await refresh()
    }

    // MARK: Back up now

    /// A manual database snapshot, a data-home snapshot, and (when there are targets) a sync to every target.
    public func backUpNow() async {
        guard !isBackingUp else { return }
        isBackingUp = true
        defer { isBackingUp = false }
        let (store, paths, tools) = (self.store, self.paths, self.tools)
        struct Outcome: Sendable { var problems: [String]; var synced: Bool }
        do {
            let outcome: Outcome = try await Task.detached {
                var problems: [String] = []
                _ = try BackupService(paths: paths, writer: store.writer).snapshot(reason: .manual)
                let home = try HomeSnapshot.take(paths: paths)
                if !home.problems.isEmpty { problems.append("\(home.problems.count) home file(s) left out") }
                var synced = false
                if !(try store.backupTargets().isEmpty) {
                    for result in try BackupTargets.syncAll(store: store, paths: paths, tools: tools) {
                        switch result.outcome {
                        case .synced: synced = true
                        case .skipped(let why), .unavailable(let why), .failed(let why):
                            problems.append("\(result.target.summary): \(why)")
                        }
                    }
                }
                return Outcome(problems: problems, synced: synced)
            }.value
            if outcome.synced { lastTargetSync = Date() }
            error = outcome.problems.isEmpty ? nil : outcome.problems.joined(separator: "; ")
            message = outcome.problems.isEmpty ? "Backed up" : "Backed up with problems"
        } catch {
            self.error = "\(error)"
            message = nil
        }
        await refresh()
    }
}
