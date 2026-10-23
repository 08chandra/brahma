import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Six 220 pt columns, one per status. The owner can drag a card only where `OwnerMoves` allows: In review and Done are
/// written by the engine alone.
struct BoardView: View {
    @Bindable var model: AppModel

    static let columnWidth: CGFloat = 220
    static let minColumnWidth: CGFloat = 150

    var body: some View {
        let columns = model.boardColumns
        Panel(title: "Board", padded: false, accessory: { sprintPicker }, content: {
            GeometryReader { proxy in
                // 220 pt when the window has room; narrower (never under 150) so all six columns stay in view.
                let width = max(Self.minColumnWidth, min(Self.columnWidth, (proxy.size.width - 5) / CGFloat(columns.count)))
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                            if index > 0 { Hairline(axis: .vertical) }
                            BoardColumnView(model: model, column: column)
                                .frame(width: width)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        })
        .padding(BrahmaTheme.spaceS)
    }

    private var sprintPicker: some View {
        Picker("Sprint", selection: $model.boardSprintId) {
            Text(verbatim: "All items").tag(String?.none)
            ForEach(model.work.openSprints, id: \.id) { sprint in
                Text(verbatim: sprint.name).tag(String?.some(sprint.id))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
    }
}

private struct BoardColumnView: View {
    let model: AppModel
    let column: BoardColumn
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: BrahmaTheme.spaceS) {
                Circle().fill(column.status.chipColor).frame(width: 6, height: 6)
                CapsLabel(column.title, color: BrahmaTheme.text1)
                Spacer()
                MonoChip(text: "\(column.rows.count)", color: BrahmaTheme.text1)
            }
            .padding(.horizontal, BrahmaTheme.spaceS)
            .frame(height: BrahmaTheme.rowHeight)
            .background(BrahmaTheme.bg3)
            .overlay(alignment: .bottom) { Hairline() }
            ScrollView {
                LazyVStack(spacing: BrahmaTheme.spaceS) {
                    if column.rows.isEmpty {
                        Text(verbatim: "NONE").font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                            .frame(maxWidth: .infinity).padding(.top, BrahmaTheme.spaceM)
                    }
                    ForEach(column.rows) { row in
                        BoardCard(model: model, row: row)
                    }
                }
                .padding(BrahmaTheme.spaceS)
            }
        }
        .frame(maxHeight: .infinity)
        .background(targeted ? BrahmaTheme.bg3.opacity(0.5) : BrahmaTheme.bg2)
        .dropDestination(for: String.self) { keys, _ in
            guard let key = keys.first, let item = model.item(key: key) else { return false }
            guard OwnerMoves.allows(from: item.status, to: column.status) else {
                model.errorMessage = column.status == .inReview || column.status == .done
                    ? "Only the engine moves an item into \(column.title): it runs the check and the review."
                    : "\(key) can't move from \(item.status.title) to \(column.title) by hand."
                return false
            }
            Task { _ = await model.moveItem(key: key, to: column.status) }
            return true
        } isTargeted: { targeted = $0 }
    }
}

private struct BoardCard: View {
    let model: AppModel
    let row: ItemRow
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                if !row.reviewFlags.isEmpty {
                    Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(BrahmaTheme.warning)
                }
                Text(verbatim: row.key).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
                Spacer(minLength: 2)
                Text(verbatim: row.priorityLabel).font(BrahmaTheme.monoTiny)
                    .foregroundStyle(row.priority < 2 ? BrahmaTheme.warning : BrahmaTheme.text2)
                Text(verbatim: row.tier).font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2)
            }
            Text(verbatim: row.title).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text0).lineLimit(3)
                .multilineTextAlignment(.leading)
            HStack(spacing: 5) {
                Text(verbatim: row.assignee.map { "@" + $0 } ?? "unassigned").font(BrahmaTheme.monoTiny)
                    .foregroundStyle(BrahmaTheme.text1).lineLimit(1)
                Spacer(minLength: 2)
                if let chip = row.intensityChip {
                    if chip.contains("unconfirmed") { WarningChip(label: chip) } else { StatusChip(label: chip, color: BrahmaTheme.accent) }
                }
            }
            if row.checkLabel != "No check" {
                Text(verbatim: row.checkLabel).font(BrahmaTheme.monoTiny).foregroundStyle(checkColor(row.checkLabel)).lineLimit(1)
            }
            if row.status == .blocked, let reason = row.blockedReason {
                Text(verbatim: reason).font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.danger).lineLimit(2)
            }
        }
        .padding(BrahmaTheme.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(hovered ? BrahmaTheme.bg4 : BrahmaTheme.bg3))
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.line, lineWidth: 1))
        .overlay(alignment: .leading) { Rectangle().fill(row.status.chipColor).frame(width: 2) }
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(BrahmaTheme.fast) { hovered = inside } }
        .onTapGesture { model.apply(.item(key: row.key)) }
        .draggable(row.key)
        .contextMenu {
            ForEach(OwnerMoves.targets(from: row.status), id: \.self) { target in
                Button("Move to \(target.title)") { Task { _ = await model.moveItem(key: row.key, to: target) } }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
