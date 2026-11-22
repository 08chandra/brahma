import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Work › MERGE QUEUE (Plan 4a Task 10): the header strip (`MAIN <sha7>`, `BATCH <n>`, the strategy, `MAIN CHECK <cmd|NONE>`,
/// main's health, "Settings…"; `HELD: <reason>` with "Resume" while the queue is held; `BATCH AT <STEP>` while the engine is
/// finishing a batch from its journal) over the zebra table of requests. "Retry" and "Resume" go through the owner-only Store
/// paths (`AppModel.retryMerge`, `resumeMergeQueue`); nothing here moves `main` or sets a request's status. Agent-controlled
/// text (titles, the main check command, conflict file names in a detail) is `Text(verbatim:)`.
struct MergeQueueView: View {
    let model: AppModel

    var body: some View {
        let rows = model.mergeRows
        let header = model.mergeHeader
        Panel(title: "Merge queue", padded: false, accessory: {
            HStack(spacing: BrahmaTheme.spaceXS) {
                MonoChip(text: header.title, color: header.tone == .muted ? BrahmaTheme.text1 : Self.toneColor(header.tone), fill: BrahmaTheme.bg4)
                Button("Settings…") { model.presentedSheet = .mergeSettings }.buttonStyle(.brahma)
            }
        }, content: {
            VStack(spacing: 0) {
                strip(header)
                Hairline()
                if rows.isEmpty {
                    MonoEmptyState("MERGE QUEUE EMPTY",
                                   detail: "Approved items with changes wait here while the engine rebases, re-runs checks and merges them.")
                } else {
                    table(rows)
                }
            }
        })
        .padding(BrahmaTheme.spaceS)
        .background(BrahmaTheme.bg0)
    }

    // MARK: Header strip

    private func strip(_ header: MergeHeader) -> some View {
        let health = model.mainHealth
        return VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            HStack(spacing: BrahmaTheme.spaceS) {
                MonoChip(text: header.main, color: BrahmaTheme.text0, fill: BrahmaTheme.bg4)
                MonoChip(text: header.batch, color: BrahmaTheme.text0, fill: BrahmaTheme.bg4)
                Text(verbatim: header.strategy).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text1).lineLimit(1)
                // The command is agent-controlled and may be long: one line, cut in the middle, whole in the tooltip.
                MonoChip(text: header.mainCheck, color: header.hasMainCheck ? BrahmaTheme.text0 : BrahmaTheme.text2, fill: BrahmaTheme.bg4)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 520, alignment: .leading)
                    .help(Text(verbatim: header.mainCheck))
                StatusChip(label: health.title, color: PreviewPane<EmptyView>.toneColor(health.tone), pulse: health.tone == .busy)
                Spacer(minLength: 0)
            }
            if header.held != nil || header.unfinishedBatch != nil {
                HStack(spacing: BrahmaTheme.spaceS) {
                    if let held = header.held {
                        StatusChip(label: held, color: BrahmaTheme.warning)
                            .help(Text(verbatim: held))
                        Button("Resume") { Task { await model.resumeMergeQueue() } }
                            .buttonStyle(.brahmaPrimary)
                            .help("Release the hold; a root-behind hold lifts only once the root checkout is on main")
                    }
                    if let batch = header.unfinishedBatch {
                        StatusChip(label: batch, color: BrahmaTheme.running, pulse: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(BrahmaTheme.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: header.detail))
    }

    // MARK: Table

    /// One layout for the header and every row: fixed columns, and DETAIL the only flexible one, so the cells line up whatever
    /// the content (M1). `retry` is the trailing button column.
    private enum Column: CaseIterable {
        case ref, key, title, owner, status, detail, commit, queued, retry

        var header: String {
            switch self {
            case .ref: "Ref"
            case .key: "Key"
            case .title: "Title"
            case .owner: "Owner"
            case .status: "Status"
            case .detail: "Detail"
            case .commit: "Commit"
            case .queued: "Queued"
            case .retry: ""
            }
        }

        /// Nil: the flexible column.
        var width: CGFloat? {
            switch self {
            case .ref: 44
            case .key: 80
            case .title: 200
            case .owner: 90
            case .status: 96
            case .detail: nil
            case .commit: 64
            case .queued: 112
            case .retry: 56
            }
        }
    }

    private func sized<V: View>(_ column: Column, _ view: V) -> some View {
        Group {
            if let width = column.width {
                view.frame(width: width, alignment: column == .retry ? .trailing : .leading)
            } else {
                view.frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func table(_ rows: [MergeRow]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: BrahmaTheme.spaceS) {
                ForEach(Column.allCases, id: \.self) { column in
                    sized(column, ColumnHeader(column.header))
                }
            }
            .padding(.horizontal, BrahmaTheme.spaceS)
            .frame(height: BrahmaTheme.denseRowHeight)
            .background(BrahmaTheme.bg3)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: BrahmaTheme.spaceS) {
                            ForEach(Column.allCases, id: \.self) { column in
                                sized(column, cell(column, row))
                            }
                        }
                        .tableRow(index: index)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text(verbatim: "\(row.ref) \(row.itemKey) \(row.statusTitle) \(row.detail)"))
                    }
                }
            }
        }
    }

    @ViewBuilder private func cell(_ column: Column, _ row: MergeRow) -> some View {
        switch column {
        case .ref: Text(verbatim: row.ref).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text0)
        case .key: Text(verbatim: row.itemKey).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text0).lineLimit(1)
        case .title: Text(verbatim: row.title).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text1).lineLimit(1)
        case .owner: Text(verbatim: row.holder).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text1).lineLimit(1)
        case .status: StatusChip(label: row.statusTitle, color: Self.toneColor(row.tone), pulse: row.tone == .running)
        case .detail:
            Text(verbatim: row.detail).font(BrahmaTheme.monoSmall).foregroundStyle(detailColor(row)).lineLimit(1)
                .truncationMode(.tail)
                .help(Text(verbatim: row.detail))
        case .commit: Text(verbatim: row.commit).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text1)
        case .queued: Text(verbatim: row.when).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
        case .retry:
            if row.canRetry {
                Button("Retry") { Task { await model.retryMerge(requestId: row.id) } }
                    .buttonStyle(.brahma)
                    .help("Put this failed merge back in the queue; the engine merges it next")
            } else {
                // Never an empty cell: an empty view takes no width and no HStack spacing, which would pull this row's
                // columns off the header's.
                Color.clear.frame(width: 0, height: 0)
            }
        }
    }

    private func detailColor(_ row: MergeRow) -> Color {
        switch row.tone {
        case .danger: BrahmaTheme.danger
        case .warning: BrahmaTheme.warning
        default: BrahmaTheme.text1
        }
    }

    /// Global Constraints "Color tokens": queued `ready`; running/landing `running`; merged `success`; bounced `danger`; failed
    /// and held `warning`; cancelled `text2`.
    static func toneColor(_ tone: MergeTone) -> Color {
        switch tone {
        case .ready: BrahmaTheme.ready
        case .running: BrahmaTheme.running
        case .success: BrahmaTheme.success
        case .danger: BrahmaTheme.danger
        case .warning: BrahmaTheme.warning
        case .muted: BrahmaTheme.text2
        }
    }
}
