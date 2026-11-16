import Foundation
import BrahmaCore

/// The Budget view (Plan ML Task 9, ruling h): a sidebar row of its own. Panels WEEKLY (3a's pace line), BY MODE (3a's
/// mode breakdown) and STORAGE (`StorageModel`). The top bar's "Budget by mode" popover stays as it is; later panels (the
/// allowance row, owner requests) attach here.
@MainActor
public struct BudgetModel {
    public nonisolated static let panels = ["WEEKLY", "BY MODE", "STORAGE"]
    public nonisolated static let noSpend = "No spend recorded this week."
    /// WEEKLY before the week has a pace (no calibration yet).
    public nonisolated static let noPace = "No weekly pace yet."

    public let paceLine: String
    public let modeBreakdownLine: String?
    public let storage: StorageModel

    public init(paceLine: String, modeBreakdownLine: String?, storage: StorageModel) {
        self.paceLine = paceLine
        self.modeBreakdownLine = modeBreakdownLine
        self.storage = storage
    }

    /// BY MODE's text.
    public var byModeText: String { modeBreakdownLine ?? Self.noSpend }
}

extension AppModel {
    /// Work › Budget of the selected company; nil until Budget was opened.
    public var budget: BudgetModel? {
        storage.map { BudgetModel(paceLine: paceLine ?? BudgetModel.noPace, modeBreakdownLine: modeBreakdownLine, storage: $0) }
    }

    /// The storage meter, made on first use, pointed at the selected company (cached measurements are reused).
    @discardableResult
    public func ensureStorage() -> StorageModel? {
        guard let companyId = selectedCompanyId else { return nil }
        let model = storage ?? StorageModel(store: store, paths: paths, sizing: storageSizing)
        storage = model
        Task { await model.show(companyId: companyId) }
        return model
    }
}
