import Foundation
import GRDB
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum InfraClass: Equatable, Sendable { case none, network, account }

/// Why the whole engine is paused. Raw value order is not precedence; see `rank`.
public enum HoldReason: String, Codable, Equatable, Sendable {
    case network, account, cli, disk

    /// A higher reason replaces a lower one: account > cli > disk > network.
    var rank: Int {
        switch self {
        case .account: 3
        case .cli: 2
        case .disk: 1
        case .network: 0
        }
    }
}

/// The error text of a failed turn, as far as the classifier may look at it: the `result` event's text and
/// `api_error_status` when `is_error`, or the runner's launch error. Never stderr, never assistant text.
public struct InfraInput: Equatable, Sendable {
    public var text: String
    public var status: Int?
    public init(text: String, status: Int?) { self.text = text; self.status = status }
}

public enum EngineHealth {
    /// Rules (see `Orchestrator`): network 3 failing turns within 300 s; account 2 consecutive; version re-check
    /// every 600 s; disk < 5 GB holds and >= 6 GB releases, checked every 60 s; probe every 60 s while on network hold.
    public static let networkFailuresToHold = 3
    public static let networkWindow: TimeInterval = 300
    public static let accountFailuresToHold = 2
    public static let probeInterval: TimeInterval = 60
    public static let cliCheckInterval: TimeInterval = 600
    public static let diskCheckInterval: TimeInterval = 60
    public static let diskHoldBytes: Int64 = 5 * 1_000_000_000
    public static let diskReleaseBytes: Int64 = 6 * 1_000_000_000
    /// The fifth consecutive infrastructure failure of one agent counts as an ordinary failure.
    public static let maxConsecutiveInfra = 5
    /// An agent whose turn failed for infrastructure reasons waits this long (fixed, no growth) before it is eligible.
    public static let infraCooldown: TimeInterval = 15

    public static let networkPatterns = ["enotfound", "econnrefused", "econnreset", "etimedout", "getaddrinfo",
                                         "network is unreachable", "fetch failed", "socket hang up"]
    public static let accountPatterns = ["not logged in", "/login", "invalid api key", "authentication", "subscription",
                                         "credit balance"]

    /// Account beats network when both match (a login problem is what the owner must act on).
    public static func classify(text: String, apiErrorStatus: Int?) -> InfraClass {
        let t = text.lowercased()
        if apiErrorStatus == 401 || apiErrorStatus == 403 || accountPatterns.contains(where: t.contains) { return .account }
        if let s = apiErrorStatus, (500...599).contains(s) { return .network }
        if networkPatterns.contains(where: t.contains) { return .network }
        return .none
    }
}

public protocol ConnectivityProbe: Sendable {
    func online() async -> Bool
}

/// HEAD `https://api.anthropic.com`, 5 s; any HTTP response, whatever its status, counts as online.
public struct HTTPSProbe: ConnectivityProbe {
    public var url: URL
    public init(url: URL = URL(string: "https://api.anthropic.com")!) { self.url = url }

    public func online() async -> Bool {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }
}

public protocol DiskSpace: Sendable {
    func freeBytes(at: URL) -> Int64?
}

/// `FileManager.attributesOfFileSystem(.systemFreeSize)` of the nearest existing ancestor of the path.
public struct SystemDiskSpace: DiskSpace {
    public init() {}

    public func freeBytes(at url: URL) -> Int64? {
        var path = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: path.path), path.pathComponents.count > 1 {
            path.deleteLastPathComponent()
        }
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path.path),
              let free = attrs[.systemFreeSize] as? NSNumber else { return nil }
        return free.int64Value
    }
}

public struct EngineHold: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "engineHold"

    var id: Int = 1
    public var reason: HoldReason
    public var detail: String
    public var since: Date
    public var nextProbeAt: Date?
}

extension Store {
    public func engineHold() throws -> EngineHold? {
        try writer.read { db in try EngineHold.fetchOne(db, key: 1) }
    }

    /// Enters a hold. One hold at a time: a higher-precedence reason replaces a lower one; the same or a lower one
    /// changes nothing. Returns whether the hold changed (callers raise alerts only then).
    @discardableResult
    public func setHold(reason: HoldReason, detail: String, now: Date) throws -> Bool {
        try writer.write { db in
            if let current = try EngineHold.fetchOne(db, key: 1), current.reason.rank >= reason.rank { return false }
            let next: Date? = reason == .network ? now.addingTimeInterval(EngineHealth.probeInterval) : nil
            try EngineHold(reason: reason, detail: detail, since: now, nextProbeAt: next).save(db)
            for c in try Company.fetchAll(db) {
                try ActivityEvent(companyId: c.id, agentId: nil, turnId: nil, kind: .error,
                                  text: "engine paused: \(reason.rawValue) — \(detail)", createdAt: now).insert(db)
            }
            return true
        }
    }

    /// Leaves the hold (any reason, or only `onlyIf`). Logs "engine resumed" when there was one.
    public func clearHold(now: Date, onlyIf reason: HoldReason? = nil) throws {
        try writer.write { db in
            guard let current = try EngineHold.fetchOne(db, key: 1) else { return }
            if let reason, current.reason != reason { return }
            try db.execute(sql: "DELETE FROM engineHold WHERE id = 1")
            for c in try Company.fetchAll(db) {
                try ActivityEvent(companyId: c.id, agentId: nil, turnId: nil, kind: .usage, text: "engine resumed",
                                  createdAt: now).insert(db)
            }
        }
    }

    /// `brahma doctor` / the app's Retry, after a passing report. Free disk space is not something a doctor
    /// probe can vouch for, so a disk hold stays until the disk rule releases it.
    public func clearHoldAfterDoctor(now: Date) throws {
        guard let hold = try engineHold(), hold.reason != .disk else { return }
        try clearHold(now: now, onlyIf: hold.reason)
    }

    func scheduleNextProbe(at date: Date) throws {
        try writer.write { db in try db.execute(sql: "UPDATE engineHold SET nextProbeAt = ? WHERE id = 1", arguments: [date]) }
    }
}
