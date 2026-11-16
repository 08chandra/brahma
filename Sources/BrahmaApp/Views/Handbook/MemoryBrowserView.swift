import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Handbook › MEMORY: remembered facts and recorded episodes as a dense zebra table (REF, FACT, KIND, TYPE, SCOPE, AUTHOR,
/// CONFIDENCE, CREATED and the CONTRADICTED / TAINTED / EXPIRED / INHERITED flags), filters for agent, kind and deleted
/// entries, and the owner's decisions: delete (confirmed; a tombstone stays) and inherit from a killed agent. Facts are
/// agent-written and rendered verbatim.
struct MemoryBrowserView: View {
    @Bindable var model: MemoryBrowserModel
    @State private var selectedId: String?
    @State private var deleteTarget: MemoryRow?
    @State private var inheritFrom: String?
    @State private var inheritTo: String?

    var body: some View {
        let rows = model.rows
        let selected = rows.first { $0.id == selectedId }
        Panel(title: "Memory", padded: false, accessory: { MonoChip(text: "\(rows.count)") }) {
            VStack(spacing: 0) {
                filters
                Hairline()
                if let notice = model.notice {
                    Text(verbatim: notice).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
                        .padding(.horizontal, BrahmaTheme.spaceM).padding(.vertical, BrahmaTheme.spaceXS)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = model.error {
                    ErrorStrip(text: error) { model.error = nil }.padding(BrahmaTheme.spaceS)
                }
                if rows.isEmpty {
                    MonoEmptyState(model.isLoading ? "Loading" : "No memory entries",
                                   detail: "Agents save facts with remember; the engine records episodes of finished work.")
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
        }
        .alert(Text(verbatim: MemoryBrowserModel.deleteConfirmText(deleteTarget?.ref ?? "")),
               isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
               presenting: deleteTarget) { row in
            Button("Delete", role: .destructive) {
                model.confirmDelete = row.ref
                Task { await model.delete(row) }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        }
    }

    // MARK: Filters and inherit

    private var filters: some View {
        HStack(spacing: BrahmaTheme.spaceM) {
            Menu {
                Button("All agents") { setAgent(nil) }
                ForEach(model.agents, id: \.id) { a in
                    Button { setAgent(a.id) } label: { Text(verbatim: "@" + a.name + (a.state == .killed ? " (killed)" : "")) }
                }
            } label: {
                Text(verbatim: "AGENT: " + (model.agents.first { $0.id == model.filter.agentId }.map { "@" + $0.name } ?? "ALL"))
                    .font(BrahmaTheme.monoSmall)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Segmented(options: [(String?.none, "All"), (MemoryEntryKind.semantic.rawValue, "Facts"),
                                (MemoryEntryKind.episodic.rawValue, "Episodes")],
                      selection: model.filter.kind?.rawValue, label: "Kind") { raw in
                model.filter.kind = raw.flatMap(MemoryEntryKind.init(rawValue:))
                Task { await model.reload() }
            }
            Toggle(isOn: Binding(get: { model.filter.showRemoved }, set: { model.filter.showRemoved = $0; Task { await model.reload() } })) {
                CapsLabel("Show deleted")
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: BrahmaTheme.spaceS)
            inheritControl
        }
        .padding(.horizontal, BrahmaTheme.spaceM)
        .frame(height: 34)
        .background(BrahmaTheme.bg1)
    }

    private func setAgent(_ id: String?) {
        model.filter.agentId = id
        Task { await model.reload() }
    }

    /// Hand a killed agent's private facts to another agent: only killed agents appear as the source.
    private var inheritControl: some View {
        HStack(spacing: BrahmaTheme.spaceXS) {
            CapsLabel("Inherit")
            Menu {
                if model.inheritSources.isEmpty { Text(verbatim: "No killed agents") }
                ForEach(model.inheritSources, id: \.id) { a in
                    Button { inheritFrom = a.id } label: { Text(verbatim: "@" + a.name) }
                }
            } label: {
                Text(verbatim: "FROM " + (model.inheritSources.first { $0.id == inheritFrom }.map { "@" + $0.name } ?? "…"))
                    .font(BrahmaTheme.monoSmall)
            }
            .menuStyle(.borderlessButton).fixedSize()
            Menu {
                ForEach(model.inheritTargets, id: \.id) { a in
                    Button { inheritTo = a.id } label: { Text(verbatim: "@" + a.name) }
                }
            } label: {
                Text(verbatim: "TO " + (model.inheritTargets.first { $0.id == inheritTo }.map { "@" + $0.name } ?? "…"))
                    .font(BrahmaTheme.monoSmall)
            }
            .menuStyle(.borderlessButton).fixedSize()
            Button("Inherit") {
                guard let from = inheritFrom, let to = inheritTo else { return }
                Task {
                    if await model.inherit(from: from, to: to) != nil { inheritFrom = nil; inheritTo = nil }
                }
            }
            .buttonStyle(.brahma)
            .disabled(inheritFrom == nil || inheritTo == nil || model.isWorking)
            .help("Copy a killed agent's private facts to another agent (taint and provenance are kept)")
        }
    }

    // MARK: Table

    private func table(_ rows: [MemoryRow], selectedId: String?) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: BrahmaTheme.spaceS) {
                ColumnHeader("Ref").frame(width: 56, alignment: .leading)
                ColumnHeader("Fact").frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                ColumnHeader("Kind").frame(width: 64, alignment: .leading)
                ColumnHeader("Type").frame(width: 72, alignment: .leading)
                if selectedId == nil {
                    ColumnHeader("Scope").frame(width: 110, alignment: .leading)
                    ColumnHeader("Author").frame(width: 80, alignment: .leading)
                    ColumnHeader("Conf").frame(width: 40, alignment: .leading)
                    ColumnHeader("Created").frame(width: 112, alignment: .leading)
                }
                ColumnHeader("Flags").frame(width: 120, alignment: .leading)
            }
            .padding(.horizontal, BrahmaTheme.spaceS)
            .frame(height: BrahmaTheme.denseRowHeight)
            .background(BrahmaTheme.bg3)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: BrahmaTheme.spaceS) {
                            Text(verbatim: row.ref).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text0)
                                .frame(width: 56, alignment: .leading)
                            Text(verbatim: row.fact).font(BrahmaTheme.body)
                                .foregroundStyle(row.isRemoved ? BrahmaTheme.text2 : BrahmaTheme.text0)
                                .lineLimit(1).truncationMode(.tail)
                                .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                            mono(row.kind, 64)
                            mono(row.type, 72)
                            if selectedId == nil {
                                mono(row.scope, 110)
                                mono(row.author, 80)
                                mono(row.confidence, 40)
                                mono(row.created, 112, color: BrahmaTheme.text2)
                            }
                            HStack(spacing: 3) { ForEach(row.flags, id: \.self) { HandbookChip(label: $0) } }
                                .frame(width: 120, alignment: .leading)
                                .clipped()
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

    private func mono(_ text: String, _ width: CGFloat, color: Color = BrahmaTheme.text1) -> some View {
        Text(verbatim: text).font(BrahmaTheme.monoSmall).foregroundStyle(color)
            .lineLimit(1).truncationMode(.tail).frame(width: width, alignment: .leading)
    }

    // MARK: Inspector

    private func inspector(_ row: MemoryRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: row.ref)
            ScrollView {
                VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                    Text(verbatim: row.fact).font(BrahmaTheme.body)
                        .foregroundStyle(row.isRemoved ? BrahmaTheme.text2 : BrahmaTheme.text0)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if !row.flags.isEmpty {
                        HStack(spacing: BrahmaTheme.spaceXS) { ForEach(row.flags, id: \.self) { HandbookChip(label: $0) } }
                    }
                    KeyValueGrid(rows: [
                        KeyValueRow(label: "Ref", value: row.ref, mono: true),
                        KeyValueRow(label: "Kind", value: row.kind, mono: true),
                        KeyValueRow(label: "Type", value: row.type, mono: true),
                        KeyValueRow(label: "Key", value: row.key ?? "—", mono: true),
                        KeyValueRow(label: "Scope", value: row.scope, mono: true),
                        KeyValueRow(label: "Author", value: row.author, mono: true),
                        KeyValueRow(label: "Confidence", value: row.confidence, mono: true),
                        KeyValueRow(label: "Created", value: row.created, mono: true),
                        KeyValueRow(label: "Trust", value: row.isTainted ? (row.taintReason ?? "outside content") : "—",
                                    valueColor: row.isTainted ? BrahmaTheme.warning : BrahmaTheme.text0),
                    ])
                    if row.canDelete {
                        Button("Delete…") { deleteTarget = row }.buttonStyle(.brahma).disabled(model.isWorking)
                    }
                }
                .padding(BrahmaTheme.spaceM)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
