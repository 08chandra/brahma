import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// The company's items as a tree table (epic, its tasks, ...) with an inspector for the selected one.
struct BacklogView: View {
    @Bindable var model: AppModel
    @State private var shown = BacklogView.pageSize

    static let pageSize = 200
    private static let keyWidth: CGFloat = 72
    private static let typeWidth: CGFloat = 44
    private static let statusWidth: CGFloat = 84
    private static let pWidth: CGFloat = 26
    private static let tierWidth: CGFloat = 32
    private static let ownerWidth: CGFloat = 70

    /// While the inspector shows HISTORY, the table keeps only its Key, Title and Status columns and the inspector takes the
    /// rest of the width.
    private var compact: Bool { model.selectedItem.map { model.isReplaying(itemId: $0.id) } ?? false }

    var body: some View {
        let rows = model.backlogRows
        HStack(spacing: 0) {
            Panel(title: "Backlog", padded: false, accessory: {
                HStack(spacing: BrahmaTheme.spaceM) {
                    Toggle(isOn: $model.showDoneItems) {
                        Text(verbatim: "Show done").font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text1)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    Button { model.presentedSheet = .newItem } label: { Label("New Item", systemImage: "plus") }
                        .buttonStyle(.brahma)
                }
            }, content: { table(rows) })
            .frame(width: compact ? 360 : nil)
            if let key = model.selectedItemKey, let item = model.item(key: key) {
                Hairline(axis: .vertical)
                ItemInspector(model: model, item: item)
                    .id(item.key)
                    .frame(minWidth: compact ? 420 : 380, maxWidth: compact ? .infinity : 380)
                    .frame(maxHeight: .infinity)
                    .background(BrahmaTheme.bg2)
            }
        }
        .padding(BrahmaTheme.spaceS)
    }

    @ViewBuilder private func table(_ rows: [ItemRow]) -> some View {
        if rows.isEmpty {
            MonoEmptyState("No items yet", detail: "New Item adds the first one; agents can add more.")
        } else {
            let visible = Array(rows.prefix(shown))
            VStack(spacing: 0) {
                HStack(spacing: BrahmaTheme.spaceS) {
                    ColumnHeader("Key").frame(width: Self.keyWidth, alignment: .leading)
                    if !compact { ColumnHeader("Type").frame(width: Self.typeWidth, alignment: .leading) }
                    ColumnHeader("Title").frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
                    ColumnHeader("Status").frame(width: Self.statusWidth, alignment: .leading)
                    if !compact {
                        ColumnHeader("P").frame(width: Self.pWidth, alignment: .leading)
                        ColumnHeader("Tier").frame(width: Self.tierWidth, alignment: .leading)
                        ColumnHeader("Owner").frame(width: Self.ownerWidth, alignment: .leading)
                        ColumnHeader("Check").frame(width: 100, alignment: .leading)
                    }
                }
                .padding(.horizontal, BrahmaTheme.spaceS)
                .frame(height: BrahmaTheme.rowHeight)
                .background(BrahmaTheme.bg3)
                .overlay(alignment: .bottom) { Hairline() }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, row in
                            rowView(row)
                                .tableRow(index: index, selected: row.key == model.selectedItemKey)
                                .onTapGesture { model.selectedItemKey = row.key }
                        }
                    }
                }
                Hairline()
                HStack(spacing: BrahmaTheme.spaceS) {
                    CapsLabel("Showing \(visible.count) of \(rows.count)\(model.work.truncated ? "+" : "")", color: BrahmaTheme.text1)
                    Spacer()
                    if visible.count < rows.count {
                        Button("Load more") { shown += Self.pageSize }.buttonStyle(.brahma)
                    }
                }
                .padding(.horizontal, BrahmaTheme.spaceS)
                .frame(height: BrahmaTheme.panelHeaderHeight)
                .background(BrahmaTheme.bg3)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func rowView(_ row: ItemRow) -> some View {
        HStack(spacing: BrahmaTheme.spaceS) {
            HStack(spacing: 3) {
                if row.reviewFlags.isEmpty {
                    Color.clear.frame(width: 10)
                } else {
                    Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(BrahmaTheme.warning)
                        .help(row.reviewFlags.joined(separator: "\n"))
                }
                Text(verbatim: row.key).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text0).lineLimit(1)
            }
            .frame(width: Self.keyWidth, alignment: .leading)
            if !compact {
                Text(verbatim: row.type).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1).lineLimit(1)
                    .frame(width: Self.typeWidth, alignment: .leading)
            }
            HStack(spacing: 6) {
                Text(verbatim: row.title)
                    .font(row.hasChildren ? BrahmaTheme.bodyStrong : BrahmaTheme.body)
                    .foregroundStyle(row.status == .done ? BrahmaTheme.text2 : BrahmaTheme.text0)
                    .lineLimit(1)
                if let chip = row.intensityChip {
                    if chip.contains("unconfirmed") { WarningChip(label: chip) } else { StatusChip(label: chip, color: BrahmaTheme.accent) }
                }
            }
            .padding(.leading, CGFloat(row.depth) * 14)
            .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
            ItemStatusChip(status: row.status).frame(width: Self.statusWidth, alignment: .leading)
            if !compact { trailingColumns(row) }
        }
        .accessibilityElement(children: .combine)
    }

    /// P, Tier, Owner and Check (left out of the compact table).
    @ViewBuilder private func trailingColumns(_ row: ItemRow) -> some View {
        Text(verbatim: row.priorityLabel).font(BrahmaTheme.monoSmall).foregroundStyle(row.priority < 2 ? BrahmaTheme.warning : BrahmaTheme.text1)
            .frame(width: Self.pWidth, alignment: .leading)
        Text(verbatim: row.tier).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
            .frame(width: Self.tierWidth, alignment: .leading)
        Text(verbatim: row.assignee.map { "@" + $0 } ?? "—").font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
            .lineLimit(1).frame(width: Self.ownerWidth, alignment: .leading)
        Text(verbatim: row.checkLabel).font(BrahmaTheme.monoSmall).foregroundStyle(checkColor(row.checkLabel))
            .lineLimit(1).frame(width: 100, alignment: .leading)
    }
}

/// Form, check line, branch and worktree, dependencies, the last 20 events and the owner's status moves.
private struct ItemInspector: View {
    let model: AppModel
    let item: WorkItem
    @State private var form = ItemForm()
    @State private var detail: ItemDetail?
    @State private var merge: ItemMergeDetail?
    @State private var saving = false

    var body: some View {
        let row = ItemRows.row(item, handles: model.handles, run: model.work.latestRuns[item.id])
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: item.key) {
                // HISTORY: the item's whole history (owner only), in place of the detail.
                Segmented(options: [(false, "Detail"), (true, "History")], selection: model.isReplaying(itemId: item.id),
                          label: "Inspector view") { on in
                    if on { model.openReplay(itemKey: item.key) } else { model.closeReplay() }
                }
                Button { model.selectedItemKey = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(BrahmaTheme.text1)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close inspector"))
            }
            if model.isReplaying(itemId: item.id), let replay = model.replay {
                ReplayView(replay: replay)
            } else {
                detailScroll(row)
            }
        }
        .task(id: item.updatedAt) {
            form = fresh
            detail = await model.itemDetail(key: item.key)
            merge = await model.itemMergeDetail(itemKey: item.key)
        }
        .onChange(of: model.work.latestRuns[item.id]?.status) {
            Task { detail = await model.itemDetail(key: item.key) }
        }
        // The queue moves without touching the item until it lands or bounces: follow the snapshot's merge state too.
        .onChange(of: model.snapshot.merge) {
            Task { merge = await model.itemMergeDetail(itemKey: item.key) }
        }
    }

    private func detailScroll(_ row: ItemRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                header(row)
                Hairline()
                checkSection(row)
                Hairline()
                where_(row)
                Hairline()
                ItemMergeSection(detail: merge)
                if let detail, !detail.dependencies.isEmpty {
                    Hairline()
                    CapsLabel("Waits for")
                    ForEach(detail.dependencies) { dep in
                        HStack(spacing: BrahmaTheme.spaceS) {
                            Text(verbatim: dep.key).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text0)
                            Text(verbatim: dep.title).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text1).lineLimit(1)
                            Spacer(minLength: 4)
                            ItemStatusChip(status: dep.status)
                        }
                    }
                }
                Hairline()
                moves
                ItemFormFields(form: $form, handles: model.snapshot.agents.filter { $0.state != .killed }.map(\.name).sorted(),
                               unconfirmedNote: row.unconfirmedNote)
                HStack {
                    Spacer()
                    Button("Save") {
                        saving = true
                        Task { _ = await model.updateItem(key: item.key, form); saving = false }
                    }
                    .buttonStyle(.brahmaPrimary)
                    .disabled(saving || form == fresh || form.validate(knownHandles: Set(model.snapshot.agents.map(\.name))) != nil)
                }
                if let detail, !detail.events.isEmpty {
                    Hairline()
                    CapsLabel("Last \(detail.events.count) events")
                    ForEach(detail.events.reversed()) { e in eventLine(e) }
                }
            }
            .padding(BrahmaTheme.spaceM)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The form as the stored item would fill it in.
    private var fresh: ItemForm {
        ItemForm(item: item, handles: model.handles)
    }

    private func header(_ row: ItemRow) -> some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            Text(verbatim: item.title).font(BrahmaTheme.bodyLarge.weight(.semibold)).foregroundStyle(BrahmaTheme.text0)
                .textSelection(.enabled)
            HStack(spacing: BrahmaTheme.spaceS) {
                ItemStatusChip(status: item.status)
                StatusChip(label: row.priorityLabel, color: row.priority < 2 ? BrahmaTheme.warning : BrahmaTheme.text2)
                StatusChip(label: "Tier " + row.tier, color: BrahmaTheme.text2)
                if let chip = row.intensityChip {
                    if chip.contains("unconfirmed") { WarningChip(label: chip) } else { StatusChip(label: chip, color: BrahmaTheme.accent) }
                }
            }
            if let reason = item.blockedReason, item.status == .blocked {
                Text(verbatim: "Blocked: " + reason).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.danger)
            }
            if !item.reviewFlags.isEmpty {
                ForEach(item.reviewFlags, id: \.self) { flag in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(BrahmaTheme.warning)
                        Text(verbatim: flag).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.warning)
                    }
                }
            }
        }
    }

    private func checkSection(_ row: ItemRow) -> some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            CapsLabel("Check")
            Text(verbatim: row.checkLabel).font(BrahmaTheme.mono).foregroundStyle(checkColor(row.checkLabel))
            if let spec = item.checkSpec {
                Text(verbatim: "$ " + spec.command).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
                    .textSelection(.enabled)
            }
            if let tail = detail?.checkTail { MonoBlock(text: tail) }
        }
    }

    private func where_(_ row: ItemRow) -> some View {
        var rows = [KeyValueRow(label: "Owner", value: row.assignee.map { "@" + $0 } ?? "unassigned"),
                    KeyValueRow(label: "Reviewer", value: row.reviewer.map { "@" + $0 } ?? "none")]
        if let team = row.team { rows.append(KeyValueRow(label: "Team", value: team)) }
        if let sprint = row.sprintName { rows.append(KeyValueRow(label: "Sprint", value: sprint, mono: true)) }
        if let parent = detail?.parentKey { rows.append(KeyValueRow(label: "Parent", value: parent, mono: true)) }
        if let branch = detail?.branch { rows.append(KeyValueRow(label: "Branch", value: branch, mono: true)) }
        if let worktree = detail?.worktree { rows.append(KeyValueRow(label: "Worktree", value: worktree, mono: true)) }
        return KeyValueGrid(rows: rows)
    }

    @ViewBuilder private var moves: some View {
        let targets = OwnerMoves.targets(from: item.status)
        if !targets.isEmpty {
            HStack(spacing: BrahmaTheme.spaceS) {
                CapsLabel("Move to")
                ForEach(targets, id: \.self) { target in
                    Button(target.title) { Task { _ = await model.moveItem(key: item.key, to: target) } }
                        .buttonStyle(.brahma)
                }
            }
        }
    }

    private func eventLine(_ e: ItemDetail.EventLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: BrahmaTheme.spaceS) {
            Text(verbatim: TimeText.hm(e.time, timeZone: model.ownerTimeZone)).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
            Text(verbatim: e.actor).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
            Text(verbatim: e.text.isEmpty ? e.kind : e.text).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text0)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
