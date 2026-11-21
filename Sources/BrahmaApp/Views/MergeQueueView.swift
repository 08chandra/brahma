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
                MonoChip(text: header.mainCheck, color: header.mainCheck.hasSuffix(" NONE") ? BrahmaTheme.text2 : BrahmaTheme.text0, fill: BrahmaTheme.bg4)
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

    private func table(_ rows: [MergeRow]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: BrahmaTheme.spaceS) {
                ColumnHeader("Ref").frame(width: 44, alignment: .leading)
                ColumnHeader("Key").frame(width: 80, alignment: .leading)
                ColumnHeader("Title").frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                ColumnHeader("Owner").frame(width: 90, alignment: .leading)
                ColumnHeader("Status").frame(width: 90, alignment: .leading)
                ColumnHeader("Detail").frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                ColumnHeader("Commit").frame(width: 64, alignment: .leading)
                ColumnHeader("Queued").frame(width: 112, alignment: .leading)
                Spacer().frame(width: 56)
            }
            .padding(.horizontal, BrahmaTheme.spaceS)
            .frame(height: BrahmaTheme.denseRowHeight)
            .background(BrahmaTheme.bg3)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: BrahmaTheme.spaceS) {
                            Text(verbatim: row.ref).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text0).frame(width: 44, alignment: .leading)
                            Text(verbatim: row.itemKey).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text0).lineLimit(1)
                                .frame(width: 80, alignment: .leading)
                            Text(verbatim: row.title).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text1).lineLimit(1)
                                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                            Text(verbatim: row.holder).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text1).lineLimit(1)
                                .frame(width: 90, alignment: .leading)
                            StatusChip(label: row.statusTitle, color: Self.toneColor(row.tone), pulse: row.tone == .running)
                                .frame(width: 90, alignment: .leading)
                            Text(verbatim: row.detail).font(BrahmaTheme.monoSmall).foregroundStyle(detailColor(row)).lineLimit(1)
                                .truncationMode(.tail)
                                .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                                .help(Text(verbatim: row.detail))
                            Text(verbatim: row.commit).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text1).frame(width: 64, alignment: .leading)
                            Text(verbatim: row.when).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2).frame(width: 112, alignment: .leading)
                            Group {
                                if row.canRetry {
                                    Button("Retry") { Task { await model.retryMerge(requestId: row.id) } }
                                        .buttonStyle(.brahma)
                                        .help("Put this failed merge back in the queue; the engine merges it next")
                                }
                            }
                            .frame(width: 56, alignment: .trailing)
                        }
                        .tableRow(index: index)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text(verbatim: "\(row.ref) \(row.itemKey) \(row.statusTitle) \(row.detail)"))
                    }
                }
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
