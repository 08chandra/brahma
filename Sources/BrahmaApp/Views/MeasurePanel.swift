import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Budget › MEASURE (Plan X6a Task 8): the selected company's `brahma measure` report as a zebra table, one row per metric with
/// its value exactly as the CLI prints it (so the denominator is always shown) and its basis; a metric with detail rows expands
/// to show them. A value that is not a measured number (`insufficient data`, `not measured`, `not applicable`) is `text2`. The
/// window picker offers 7 days, 28 days (the CLI's default) and all. Every string comes from `MeasureModel`, already cleaned of
/// controls and bidi overrides, and is shown with `Text(verbatim:)`.
struct MeasurePanel: View {
    let measure: MeasureModel

    var body: some View {
        Panel(title: MeasureModel.title, padded: false, accessory: {
            HStack(spacing: BrahmaTheme.spaceS) {
                if measure.isLoading {
                    CapsLabel("Measuring…")
                } else if let window = measure.windowLine {
                    Text(verbatim: window).font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2)
                }
                Segmented(options: MeasureModel.Span.allCases.map { ($0, $0.title) }, selection: measure.window,
                          label: "Measure window") { span in Task { await measure.setWindow(span) } }
                Button { Task { await measure.load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.brahma)
                    .disabled(measure.isLoading)
            }
        }, content: {
            VStack(alignment: .leading, spacing: 0) {
                if let error = measure.errorMessage {
                    Text(verbatim: error)
                        .font(BrahmaTheme.monoSmall)
                        .foregroundStyle(BrahmaTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(BrahmaTheme.panelPadding)
                } else if measure.rows.isEmpty {
                    MonoEmptyState(measure.isLoading ? "Measuring" : "Not measured yet").frame(height: 80)
                } else {
                    header
                    ForEach(Array(measure.rows.enumerated()), id: \.element.id) { index, row in
                        MeasureRowView(row: row, index: index) { measure.toggle(row.id) }
                    }
                }
                Hairline()
                Text(verbatim: MeasureModel.footnote)
                    .font(BrahmaTheme.monoSmall)
                    .foregroundStyle(BrahmaTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(BrahmaTheme.panelPadding)
            }
        })
    }

    private var header: some View {
        HStack(spacing: BrahmaTheme.spaceM) {
            ColumnHeader("Metric").frame(width: MeasureRowView.labelWidth, alignment: .leading)
            ColumnHeader("Value").frame(width: MeasureRowView.valueWidth, alignment: .leading)
            ColumnHeader("Basis").frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, BrahmaTheme.spaceS)
        .frame(height: BrahmaTheme.denseRowHeight)
        .background(BrahmaTheme.bg3)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// One MEASURE row: a disclosure arrow when it has detail rows, the label indented by depth, the value (`text2` when it is not a
/// measured number) and the basis on one line, its full text in the tooltip.
private struct MeasureRowView: View {
    static let labelWidth: CGFloat = 260
    static let valueWidth: CGFloat = 300

    let row: MeasureRow
    let index: Int
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: BrahmaTheme.spaceM) {
            HStack(spacing: BrahmaTheme.spaceXS) {
                if row.expandable {
                    Image(systemName: row.expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(BrahmaTheme.text2)
                        .frame(width: 10)
                } else {
                    Color.clear.frame(width: 10)
                }
                Text(verbatim: row.depth == 0 ? row.label : "↳ " + row.label)
                    .font(row.depth == 0 ? BrahmaTheme.body : BrahmaTheme.monoSmall)
                    .foregroundStyle(row.depth == 0 ? BrahmaTheme.text0 : BrahmaTheme.text1)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, CGFloat(row.depth) * BrahmaTheme.spaceL)
            .frame(width: Self.labelWidth, alignment: .leading)
            Text(verbatim: row.value)
                .font(BrahmaTheme.mono)
                .foregroundStyle(row.secondary ? BrahmaTheme.text2 : BrahmaTheme.text0)
                .lineLimit(1)
                .truncationMode(.tail)
                // The value (and a refusal's reason) takes the width it needs first; the basis gives way (its tooltip has it all).
                .frame(minWidth: Self.valueWidth, alignment: .leading)
                .layoutPriority(1)
                .textSelection(.enabled)
                .help(row.value)
            Text(verbatim: row.basis)
                .font(BrahmaTheme.monoSmall)
                .foregroundStyle(BrahmaTheme.text2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.basis)
        }
        .tableRow(index: index, height: BrahmaTheme.denseRowHeight)
        .onTapGesture { if row.expandable { toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.expandable ? .isButton : [])
        .accessibilityValue(row.expandable ? Text(verbatim: row.expanded ? "expanded" : "collapsed") : Text(verbatim: ""))
        .accessibilityAction { if row.expandable { toggle() } }
    }
}
