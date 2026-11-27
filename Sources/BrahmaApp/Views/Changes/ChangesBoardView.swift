import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Plan C Task C7c: the CHANGES tab's body — the board, or the selected item's live diff (`ChangesDiffView`) with a way back to
/// the board (which keeps the selection and its stream).
struct ChangesTabBody: View {
    let model: AppModel
    @State private var showingBoard = false

    var body: some View {
        if let changes = model.changes {
            if changes.selectedKey == nil || showingBoard {
                ChangesBoardView(changes: changes) { key in
                    changes.select(key)
                    showingBoard = false
                }
            } else {
                ChangesDiffView(model: changes, app: model, onBoard: { showingBoard = true })
            }
        } else {
            MonoEmptyState("NO ACTIVE WORKTREES")
        }
    }
}

/// Every leased worktree's live changes vs `main` (collab design §1.6) as a zebra table, newest edit first (the engine's order):
/// KEY (mono), TITLE, AGENT (state dot), FILES, +/− (mono, `success`/`danger`), EDITED, CHECK (chip). The selected row is `bg4`
/// with the accent bar; a click opens that item's diff in the tab. Every string is the engine's gated final text
/// (`BoardRowView`) or built from its numbers; titles and handles are `Text(verbatim:)`.
struct ChangesBoardView: View {
    let changes: ChangesTabModel
    let open: (String) -> Void

    private static let columns: (key: CGFloat, agent: CGFloat, files: CGFloat, counts: CGFloat, edited: CGFloat, check: CGFloat) =
        (70, 96, 44, 84, 74, 112)
    private static let minTitle: CGFloat = 120

    var body: some View {
        Panel(title: "Changes", padded: false, accessory: {
            if !changes.rows.isEmpty {
                MonoChip(text: "\(changes.rows.count) LIVE", color: BrahmaTheme.running, fill: BrahmaTheme.bg4)
            }
        }, content: {
            if changes.rows.isEmpty {
                if let error = changes.error {
                    RefUnavailableView(caption: "NOT SHOWN", text: error)
                } else {
                    MonoEmptyState("NO ACTIVE WORKTREES")
                }
            } else {
                table
            }
        })
        .padding(BrahmaTheme.spaceXS)
    }

    private var table: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, Self.minWidth)
            ScrollView([.vertical, .horizontal]) {
                VStack(spacing: 0) {
                    headerRow
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        LazyVStack(spacing: 0) {
                            ForEach(Array(changes.rows.enumerated()), id: \.element.key) { i, row in
                                rowView(i, row, now: ctx.date)
                            }
                        }
                    }
                }
                .frame(width: width, alignment: .topLeading)
            }
        }
    }

    private static var minWidth: CGFloat {
        columns.key + columns.agent + columns.files + columns.counts + columns.edited + columns.check + minTitle + 2 * BrahmaTheme.spaceS
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            ColumnHeader("Key").frame(width: Self.columns.key, alignment: .leading)
            ColumnHeader("Title").frame(maxWidth: .infinity, alignment: .leading)
            ColumnHeader("Agent").frame(width: Self.columns.agent, alignment: .leading)
            ColumnHeader("Files").frame(width: Self.columns.files, alignment: .trailing)
            ColumnHeader("+/\u{2212}").frame(width: Self.columns.counts, alignment: .trailing)
            ColumnHeader("Edited").frame(width: Self.columns.edited, alignment: .trailing).padding(.trailing, 2)
            ColumnHeader("Check").frame(width: Self.columns.check, alignment: .trailing)
        }
        .padding(.horizontal, BrahmaTheme.spaceS)
        .frame(height: BrahmaTheme.denseRowHeight)
        .background(BrahmaTheme.bg3)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func rowView(_ i: Int, _ row: BoardRowView, now: Date) -> some View {
        let numbers = changes.board.first { $0.key == row.key }
        return Button { open(row.key) } label: {
            HStack(spacing: 0) {
                Text(verbatim: row.key)
                    .font(BrahmaTheme.mono.weight(.medium))
                    .foregroundStyle(BrahmaTheme.text0)
                    .lineLimit(1)
                    .frame(width: Self.columns.key, alignment: .leading)
                HStack(spacing: BrahmaTheme.spaceXS) {
                    Text(verbatim: row.title)
                        .font(BrahmaTheme.body)
                        .foregroundStyle(BrahmaTheme.text0)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if row.tainted { RefChipView(chip: RefChip(text: "TAINTED", tone: .warn)).fixedSize() }
                    Spacer(minLength: BrahmaTheme.spaceXS)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    Circle().fill(RefStyle.tone(row.agentTone)).frame(width: 6, height: 6)
                    Text(verbatim: row.agent).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1).lineLimit(1).truncationMode(.tail)
                }
                .frame(width: Self.columns.agent, alignment: .leading)
                Text(verbatim: numbers.map { "\($0.files)" } ?? "—")
                    .font(BrahmaTheme.monoSmall)
                    .foregroundStyle(BrahmaTheme.text1)
                    .frame(width: Self.columns.files, alignment: .trailing)
                Group {
                    if let numbers { DiffCounts(added: numbers.added, removed: numbers.removed) } else { Text(verbatim: "—") }
                }
                .frame(width: Self.columns.counts, alignment: .trailing)
                // Ticks between board reloads, from the engine's newest edit time.
                Text(verbatim: Self.edited(numbers?.lastEdit, now: now))
                    .font(BrahmaTheme.monoSmall)
                    .foregroundStyle(BrahmaTheme.text2)
                    .lineLimit(1)
                    .frame(width: Self.columns.edited, alignment: .trailing)
                    .padding(.trailing, 2)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    StatusChip(label: row.check, color: RefStyle.tone(row.checkTone), pulse: row.checkTone == .busy).fixedSize()
                }
                .frame(width: Self.columns.check)
            }
        }
        .buttonStyle(.plain)
        .tableRow(index: i, selected: changes.selectedKey == row.key)
        .help(Text(verbatim: row.reviewer.map { "\(row.key) · reviewer \($0)" } ?? row.key))
        .accessibilityLabel(Text(verbatim: "\(row.key), \(row.title), \(row.agent), \(row.stats), \(row.edited), \(row.check)"))
    }

    /// `12 s ago` (the model's `edited` without its verb; the column says EDITED), `no edits yet`.
    static func edited(_ date: Date?, now: Date) -> String {
        let text = BoardRows.edited(date, now: now)
        return text.hasPrefix("edited ") ? String(text.dropFirst("edited ".count)) : text
    }
}
