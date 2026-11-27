import SwiftUI
import BrahmaAppModel

/// Work › Budget (Plan ML, ruling h): WEEKLY (the 7-day pace), BY MODE (where this week's spend went), STORAGE and MEASURE
/// (Plan X6a, `brahma measure` of the selected company). The top bar's "Budget by mode" popover stays as it is.
struct BudgetView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            if let budget = model.budget {
                VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
                    HStack(alignment: .top, spacing: BrahmaTheme.spaceS) {
                        Panel(title: BudgetModel.panels[0]) {
                            Text(verbatim: budget.paceLine.uppercased())
                                .font(BrahmaTheme.mono)
                                .foregroundStyle(paceColor(budget))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        Panel(title: BudgetModel.panels[1]) {
                            Text(verbatim: budget.byModeText)
                                .font(BrahmaTheme.monoSmall)
                                .foregroundStyle(budget.modeBreakdownLine == nil ? BrahmaTheme.text2 : BrahmaTheme.text1)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    StoragePanel(storage: budget.storage, timeZone: model.ownerTimeZone)
                    if let measure = model.measure { MeasurePanel(measure: measure) }
                }
                .padding(BrahmaTheme.spaceS)
            } else {
                MonoEmptyState("No company selected").frame(height: 200)
            }
        }
        .background(BrahmaTheme.bg0)
        .task(id: model.selectedCompanyId) {
            model.ensureStorage()
            model.ensureMeasure()
        }
    }

    private func paceColor(_ budget: BudgetModel) -> Color {
        let ahead = model.work.pace.map { $0.state == .ahead || $0.state == .closed } ?? false
        if budget.paceLine == BudgetModel.noPace { return BrahmaTheme.text2 }
        return ahead ? BrahmaTheme.warning : BrahmaTheme.text0
    }
}
