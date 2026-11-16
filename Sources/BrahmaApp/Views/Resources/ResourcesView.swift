import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Work › RESOURCES: the owner's library. The whole panel is a drop zone (company scope by default); the zebra table lists
/// every resource (a folder's files under it, purged tombstones included) with a key–value inspector and the owner's
/// actions: vouch, change scope and purge (vouch and scope act on a folder and its files together; purge can take one file).
/// This is the owner's own view, so names of untrusted resources show; every name is rendered verbatim.
struct ResourcesView: View {
    let model: AppModel
    @State private var drops: ResourceDropModel?
    @State private var selectedId: String?
    @State private var purgeTarget: ResourceRow?

    var body: some View {
        let rows = model.resourceRows
        let selected = rows.first { $0.id == selectedId }
        Panel(title: "Resources", padded: false, accessory: {
            HStack(spacing: BrahmaTheme.spaceXS) {
                if drops?.showsAdvisory == true {
                    WarningChip(label: "Advisory").help(Text(verbatim: ResourceDropModel.advisoryText))
                }
                MonoChip(text: "\(rows.filter { !$0.isPurged && !$0.isChild }.count)", color: BrahmaTheme.text0)
            }
        }, content: {
            VStack(spacing: 0) {
                if let drops, !drops.pending.isEmpty { pendingStrip(drops) }
                if rows.isEmpty {
                    MonoEmptyState("Drop files, folders or links",
                                   detail: "They are copied into Brahma's vault; agents read them by ref. Company scope by default.")
                } else {
                    HStack(spacing: 0) {
                        table(rows, selectedId: selected?.id)
                        if let selected {
                            Hairline(axis: .vertical)
                            inspector(selected).frame(width: 300)
                        }
                    }
                }
            }
        })
        .resourceDrops(drops) { Task { await drops?.commit(message: "") } }
        .padding(BrahmaTheme.spaceS)
        .background(BrahmaTheme.bg0)
        .task(id: model.selectedCompanyId) {
            let library = ResourceDropModel(app: model, context: .library, defaults: model.dropDefaults)
            drops = library
            await library.refreshScope()
        }
        .alert(Text(verbatim: ResourcesPresentation.purgeConfirmText(purgeTarget?.ref ?? "")),
               isPresented: Binding(get: { purgeTarget != nil }, set: { if !$0 { purgeTarget = nil } }), presenting: purgeTarget) { row in
            Button("Purge", role: .destructive) {
                model.confirmPurge = row.ref
                Task { await model.purge(resource: row.ref) }
            }
            Button("Cancel", role: .cancel) { purgeTarget = nil }
        }
    }

    // MARK: Pending drops

    private func pendingStrip(_ drops: ResourceDropModel) -> some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            PendingDropChips(model: drops)
            HStack {
                Spacer()
                Button("Add to library") { Task { await drops.commit(message: "") } }
                    .buttonStyle(.brahmaPrimary)
                    .disabled(drops.isWorking)
            }
        }
        .padding(BrahmaTheme.spaceM)
        .background(BrahmaTheme.bg1)
        .overlay(alignment: .bottom) { Hairline() }
    }

    // MARK: Table

    private func table(_ rows: [ResourceRow], selectedId: String?) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: BrahmaTheme.spaceS) {
                ColumnHeader("Ref").frame(width: 48, alignment: .leading)
                ColumnHeader("Name").frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                ColumnHeader("Kind").frame(width: 56, alignment: .leading)
                ColumnHeader("Size").frame(width: 96, alignment: .leading)
                ColumnHeader("Scope").frame(width: 120, alignment: .leading)
                ColumnHeader("Trust").frame(width: 84, alignment: .leading)
                ColumnHeader("Scan").frame(width: 80, alignment: .leading)
                // With the inspector open (it shows it) the table drops Added, so the rest fit the pane.
                if selectedId == nil { ColumnHeader("Added").frame(width: 112, alignment: .leading) }
            }
            .padding(.horizontal, BrahmaTheme.spaceS)
            .frame(height: BrahmaTheme.denseRowHeight)
            .background(BrahmaTheme.bg3)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: BrahmaTheme.spaceS) {
                            Text(verbatim: row.ref).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text0)
                                .frame(width: 48, alignment: .leading)
                            Text(verbatim: row.name).font(BrahmaTheme.body)
                                .foregroundStyle(row.isPurged ? BrahmaTheme.text2 : BrahmaTheme.text0)
                                .lineLimit(1).truncationMode(.middle)
                                .padding(.leading, row.isChild ? BrahmaTheme.spaceM : 0)
                                .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                            Text(verbatim: row.kindLabel).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
                                .lineLimit(1).frame(width: 56, alignment: .leading)
                            Text(verbatim: row.sizeText).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
                                .lineLimit(1).frame(width: 96, alignment: .leading)
                            Text(verbatim: row.scopeLabel).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
                                .lineLimit(1).truncationMode(.tail).frame(width: 120, alignment: .leading)
                            trustChip(row).frame(width: 84, alignment: .leading)
                            scanChip(row).frame(width: 80, alignment: .leading)
                            if selectedId == nil {
                                Text(verbatim: row.addedText).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                                    .frame(width: 112, alignment: .leading)
                            }
                        }
                        .tableRow(index: index, selected: row.id == selectedId)
                        .onTapGesture { self.selectedId = row.id == selectedId ? nil : row.id }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(row.id == selectedId ? .isSelected : [])
                    }
                }
            }
        }
    }

    @ViewBuilder private func trustChip(_ row: ResourceRow) -> some View {
        if row.isPurged {
            StatusChip(label: "Purged", color: BrahmaTheme.text2)
        } else {
            StatusChip(label: row.trustChip.isExternal ? "External" : "From you",
                       color: row.trustChip.isExternal ? BrahmaTheme.warning : BrahmaTheme.success)
                .help(Text(verbatim: TrustChipView.tooltip(row.trustChip)))
        }
    }

    @ViewBuilder private func scanChip(_ row: ResourceRow) -> some View {
        switch row.scanChip {
        case "REDACTED": WarningChip(label: "Redacted")
        case "FLAGGED": DangerChip(label: "Flagged")
        default: Text(verbatim: "—").font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
        }
    }

    // MARK: Inspector

    private func inspector(_ row: ResourceRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: row.ref)
            ScrollView {
                VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                    Text(verbatim: row.name).font(BrahmaTheme.bodyStrong)
                        .foregroundStyle(row.isPurged ? BrahmaTheme.text2 : BrahmaTheme.text0)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    KeyValueGrid(rows: [
                        KeyValueRow(label: "Ref", value: row.ref + (row.parentRef.map { " · in " + $0 } ?? ""), mono: true),
                        KeyValueRow(label: "Kind", value: row.kindLabel, mono: true),
                        KeyValueRow(label: "Size", value: row.sizeText, mono: true),
                        KeyValueRow(label: "SHA-256", value: row.sha12, mono: true),
                        KeyValueRow(label: "Scope", value: row.scopeLabel, mono: true),
                        KeyValueRow(label: "Readers", value: row.readersText, mono: true),
                        KeyValueRow(label: "Trust", value: row.isPurged ? "PURGED" : TrustChipView.tooltip(row.trustChip),
                                    valueColor: row.isPurged ? BrahmaTheme.text2
                                        : row.trustChip.isExternal ? BrahmaTheme.warning : BrahmaTheme.success),
                        KeyValueRow(label: "Scan", value: row.scanChip ?? "—", mono: true,
                                    valueColor: row.scanChip == "FLAGGED" ? BrahmaTheme.danger
                                        : row.scanChip == "REDACTED" ? BrahmaTheme.warning : BrahmaTheme.text0),
                        KeyValueRow(label: "Added", value: row.addedText, mono: true),
                        KeyValueRow(label: "Mirror", value: row.mirrorPath ?? "—", mono: true),
                    ])
                    if let note = ResourcesPresentation.purgeNote(row) {
                        Text(verbatim: note).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    actions(row)
                }
                .padding(BrahmaTheme.spaceM)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func actions(_ row: ResourceRow) -> some View {
        if row.canVouch || row.canChangeScope || row.canPurge {
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
                if row.canVouch {
                    Button(row.trustChip.action) { Task { await model.vouch(resource: row.ref) } }.buttonStyle(.brahma)
                }
                if row.canChangeScope {
                    Menu("Change scope…") {
                        Button("Company") { Task { await model.setScope(resource: row.ref, .company) } }
                        if !teams.isEmpty {
                            Section("Team") {
                                ForEach(teams, id: \.self) { t in
                                    Button { Task { await model.setScope(resource: row.ref, .team(t)) } } label: { Text(verbatim: t) }
                                }
                            }
                        }
                        if !itemKeys.isEmpty {
                            Section("Item") {
                                ForEach(itemKeys, id: \.self) { k in
                                    Button { Task { await model.setScope(resource: row.ref, .item(k)) } } label: { Text(verbatim: k) }
                                }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                if row.canPurge {
                    Button("Purge…") { purgeTarget = row }.buttonStyle(.brahma)
                }
            }
        }
    }

    // MARK: Choices

    private var teams: [String] { drops?.teamChoices ?? [] }
    private var itemKeys: [String] { drops?.itemChoices ?? [] }
}
