import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Budget › STORAGE: the selected company's storage as mono key–value rows (FREE DISK in `warning` below 10 GB), a
/// Refresh button, and the hot-tier footer.
struct StoragePanel: View {
    let storage: StorageModel
    let timeZone: TimeZone

    var body: some View {
        Panel(title: StorageModel.title, accessory: {
            HStack(spacing: BrahmaTheme.spaceS) {
                if storage.isMeasuring {
                    CapsLabel("Measuring…")
                } else if let measured = storage.measuredLine(timeZone: timeZone) {
                    Text(verbatim: measured).font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2)
                }
                Button { Task { await storage.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.brahma)
                    .disabled(storage.isMeasuring)
            }
        }, content: {
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
                if let error = storage.error {
                    Text(verbatim: error).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if storage.rows.isEmpty {
                    MonoEmptyState(storage.isMeasuring ? "Measuring" : "Not measured yet").frame(height: 80)
                } else {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: BrahmaTheme.spaceL, verticalSpacing: 6) {
                        ForEach(storage.rows) { row in
                            GridRow {
                                CapsLabel(row.label).gridColumnAlignment(.leading)
                                Text(verbatim: row.value)
                                    .font(BrahmaTheme.mono)
                                    .foregroundStyle(row.warning ? BrahmaTheme.warning : (row.label == "TOTAL" ? BrahmaTheme.text0 : BrahmaTheme.text1))
                                    .fontWeight(row.label == "TOTAL" ? .semibold : .regular)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .textSelection(.enabled)
                            }
                            if row.separated {
                                Hairline().gridCellColumns(2)
                            }
                        }
                    }
                    .frame(maxWidth: 420, alignment: .leading)
                }
                Hairline()
                Text(verbatim: StorageModel.footer)
                    .font(BrahmaTheme.monoSmall)
                    .foregroundStyle(BrahmaTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        })
    }
}
