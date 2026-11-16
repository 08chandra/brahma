import Foundation
import Observation
import BrahmaCore

/// One mono key–value row of the STORAGE panel. `warning` colors the value; `separated` draws a hairline after the row.
public struct StorageRow: Equatable, Sendable, Identifiable {
    public var label: String
    public var value: String
    public var warning = false
    public var separated = false
    public var id: String { label }
}

/// Budget › STORAGE (Plan ML Task 9): the selected company's storage, measured off the main actor (`StorageMeter`) and
/// cached per company for `StorageMeter.minInterval` company-active seconds (durations never use wall-clock differences).
/// Refresh always measures.
@MainActor @Observable
public final class StorageModel {
    public nonisolated static let title = "STORAGE"
    public nonisolated static let footer =
        "HOT TIER: everything. Brahma keeps all records; nothing is deleted automatically. A warm archive tier comes later."
    /// FREE DISK below this is shown in `warning`.
    public nonisolated static let lowDiskBytes: Int64 = 10 * 1_073_741_824

    public private(set) var companyId: String?
    public private(set) var report: StorageReport?
    public private(set) var isMeasuring = false
    public var error: String?

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let paths: BrahmaPaths
    @ObservationIgnored private let sizing: any FileSizing
    @ObservationIgnored private let activeNow: @Sendable (String) -> TimeInterval
    @ObservationIgnored private let clock: @Sendable () -> Date
    /// Per company: the last report and the company-active second it was measured at.
    @ObservationIgnored private var cache: [String: (report: StorageReport, active: TimeInterval, generation: Int)] = [:]
    @ObservationIgnored private var generation = 0
    /// The newest measurement whose result (or failure) is shown: overlapping measurements never show an older one.
    @ObservationIgnored private var applied = 0

    /// `activeNow` defaults to the store's company-active clock.
    public init(store: Store, paths: BrahmaPaths, sizing: any FileSizing = LiveFileSizing(),
                activeNow: (@Sendable (String) -> TimeInterval)? = nil, clock: @escaping @Sendable () -> Date = { .now }) {
        self.store = store
        self.paths = paths
        self.sizing = sizing
        self.activeNow = activeNow ?? { [store] id in store.activeNow(companyId: id) }
        self.clock = clock
    }

    /// Shows `companyId`: its cached report at once, measured again only when it is older than the interval.
    public func show(companyId: String) async {
        if self.companyId != companyId {
            self.companyId = companyId
            report = cache[companyId]?.report
            error = nil
        }
        await load()
    }

    /// The cached report while it is younger than `StorageMeter.minInterval` active seconds, else a new measurement.
    public func load() async {
        guard let companyId else { return }
        let now = activeNow(companyId)
        if let hit = cache[companyId], now - hit.active < StorageMeter.minInterval {
            report = hit.report
            return
        }
        await measure(companyId: companyId, active: now)
    }

    /// The Refresh button: measures now.
    public func refresh() async {
        guard let companyId else { return }
        await measure(companyId: companyId, active: activeNow(companyId))
    }

    private func measure(companyId: String, active: TimeInterval) async {
        generation += 1
        let mine = generation
        let (store, paths, sizing, now) = (self.store, self.paths, self.sizing, clock())
        isMeasuring = true
        defer { if mine == generation { isMeasuring = false } }
        do {
            let measured = try await Task.detached { () -> StorageReport in
                guard let company = try store.company(id: companyId) else { throw WorkError.notFound("no such company") }
                return try StorageMeter.measure(store: store, paths: paths, company: company, sizing: sizing, now: now)
            }.value
            if mine > (cache[companyId]?.generation ?? 0) { cache[companyId] = (measured, active, mine) }
            guard self.companyId == companyId, mine > applied else { return }
            applied = mine
            report = measured
            error = nil
        } catch {
            guard self.companyId == companyId, mine > applied else { return }
            self.error = "Couldn't measure storage: \(error)"
        }
    }

    // MARK: Presentation

    /// The panel's rows: the company's own (TOTAL), then the shared backups, then the free disk.
    public var rows: [StorageRow] {
        guard let r = report else { return [] }
        let size = ResourceText.size
        return [
            StorageRow(label: "DATABASE (EST.)", value: size(r.dbBytes)),
            StorageRow(label: "WORKSPACE", value: size(r.workspaceBytes)),
            StorageRow(label: "RESOURCES", value: size(r.vaultBytes)),
            StorageRow(label: "TRANSCRIPTS", value: size(r.transcriptBytes)),
            StorageRow(label: "ARCHIVE", value: size(r.archiveBytes)),
            StorageRow(label: "TOTAL", value: size(r.total), separated: true),
            StorageRow(label: "BACKUPS (ALL COMPANIES)", value: size(r.backupBytes), separated: true),
            StorageRow(label: "FREE DISK", value: size(r.freeBytes), warning: r.freeBytes < Self.lowDiskBytes),
        ]
    }

    /// `MEASURED yyyy-MM-dd HH:mm` in the owner's time zone, or nil before the first measurement.
    public func measuredLine(timeZone: TimeZone) -> String? {
        guard let r = report else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "MEASURED " + f.string(from: r.measuredAt)
    }
}
