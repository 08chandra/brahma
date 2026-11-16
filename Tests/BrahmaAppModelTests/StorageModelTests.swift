import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

/// A `FileSizing` that touches nothing: every tree is `perTree` bytes, the disk has `free` left, and each measurement (one
/// `freeBytes` call) is counted.
final class CountingSizing: FileSizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _measurements = 0
    private var _free: Int64
    let perTree: Int64

    init(free: Int64 = 500 * 1_073_741_824, perTree: Int64 = 1000) { _free = free; self.perTree = perTree }

    var measurements: Int { lock.withLock { _measurements } }
    var free: Int64 {
        get { lock.withLock { _free } }
        set { lock.withLock { _free = newValue } }
    }

    func allocatedSize(of url: URL) throws -> Int64 { perTree }
    func freeBytes(at url: URL) throws -> Int64 {
        lock.withLock { _measurements += 1; return _free }
    }
}

/// Company-active seconds the test sets by hand.
final class ActiveBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: TimeInterval = 0
    var value: TimeInterval {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Plan ML Task 9: Budget › STORAGE — measured off the main actor, cached per company for `StorageMeter.minInterval`
/// company-active seconds, and the low free-disk warning.
@MainActor @Suite(.scratch) struct StorageModelTests {
    @Test func cachedForTenMinutes() async throws {
        let (store, paths) = try makeHome()
        let (acme, _, _, _) = try seedAcme(store, paths)
        let globex = try #require(try store.companies().first { $0.name == "Globex" })
        let sizing = CountingSizing()
        let active = ActiveBox()
        let model = StorageModel(store: store, paths: paths, sizing: sizing, activeNow: { _ in active.value })

        await model.show(companyId: acme.id)
        #expect(sizing.measurements == 1)
        let first = try #require(model.report)
        #expect(first.total == first.dbBytes + 4 * sizing.perTree)
        active.value = StorageMeter.minInterval - 1
        await model.load()
        #expect(sizing.measurements == 1, "within the interval the cached report is shown")
        active.value = StorageMeter.minInterval
        await model.load()
        #expect(sizing.measurements == 2)
        await model.refresh()
        #expect(sizing.measurements == 3, "Refresh always measures")
        // Per company: another company is measured on its own, and coming back within the interval measures nothing.
        await model.show(companyId: globex.id)
        #expect(sizing.measurements == 4)
        #expect(model.companyId == globex.id)
        active.value = StorageMeter.minInterval + 50
        await model.show(companyId: acme.id)
        #expect(sizing.measurements == 4)
        #expect(model.report?.measuredAt == model.report?.measuredAt)
        #expect(model.rows.map(\.label) == ["DATABASE (EST.)", "WORKSPACE", "RESOURCES", "TRANSCRIPTS", "ARCHIVE", "TOTAL",
                                            "BACKUPS (ALL COMPANIES)", "FREE DISK"])
    }

    @Test func lowDiskWarning() async throws {
        let (store, paths) = try makeHome()
        let (acme, _, _, _) = try seedAcme(store, paths)
        #expect(StorageModel.lowDiskBytes == 10 * 1_073_741_824)
        let sizing = CountingSizing(free: 9 * 1_073_741_824)
        let model = StorageModel(store: store, paths: paths, sizing: sizing, activeNow: { _ in 0 })
        await model.show(companyId: acme.id)
        let low = try #require(model.rows.last)
        #expect(low.label == "FREE DISK" && low.warning && low.value == "9.0 GB")
        #expect(model.rows.dropLast().allSatisfy { !$0.warning })
        sizing.free = 11 * 1_073_741_824
        await model.refresh()
        #expect(model.rows.last?.warning == false)
        #expect(model.rows.last?.value == "11.0 GB")
        #expect(StorageModel.footer
                == "HOT TIER: everything. Brahma keeps all records; nothing is deleted automatically. A warm archive tier comes later.")
    }
}
