import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Work › HANDBOOK: a header strip with the `PAGES | MEMORY` tabs and a search field. PAGES is the page tree (or the search's
/// hits) on the left, the page in the center (`KBPageView`) and the BACKLINKS and RECENTLY CHANGED panels on the right;
/// MEMORY is the memory browser. Every title and path may be agent-written and is rendered verbatim.
struct HandbookView: View {
    let model: AppModel

    var body: some View {
        Group {
            if let handbook = model.handbook {
                HandbookContent(model: model, handbook: handbook)
            } else {
                MonoEmptyState("No company selected")
            }
        }
        .padding(BrahmaTheme.spaceS)
        .background(BrahmaTheme.bg0)
        .task(id: model.selectedCompanyId) {
            guard let handbook = model.ensureHandbook() else { return }
            await handbook.reload()
            if handbook.tab == .memory { await handbook.memory.reload() }
        }
    }
}

private struct HandbookContent: View {
    let model: AppModel
    @Bindable var handbook: HandbookModel

    var body: some View {
        VStack(spacing: BrahmaTheme.spaceS) {
            header
            if let error = handbook.error {
                ErrorStrip(text: error) { handbook.error = nil }
            }
            switch handbook.tab {
            case .pages: pages
            case .memory: MemoryBrowserView(model: handbook.memory)
            }
        }
        .task(id: handbook.tab) { if handbook.tab == .memory { await handbook.memory.reload() } }
    }

    // MARK: Header strip

    private var header: some View {
        HStack(spacing: BrahmaTheme.spaceM) {
            CapsLabel("Handbook", font: BrahmaTheme.panelTitle, color: BrahmaTheme.text1)
            Segmented(options: [(HandbookTab.pages, "Pages"), (HandbookTab.memory, "Memory")], selection: handbook.tab,
                      label: "Handbook view") { handbook.tab = $0 }
            Spacer(minLength: BrahmaTheme.spaceS)
            searchField
        }
        .padding(.horizontal, BrahmaTheme.panelPadding)
        .frame(height: BrahmaTheme.panelHeaderHeight + 4)
        .background(BrahmaTheme.bg3)
        .clipShape(RoundedRectangle(cornerRadius: BrahmaTheme.radius))
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.line, lineWidth: 1))
    }

    @ViewBuilder private var searchField: some View {
        switch handbook.tab {
        case .pages:
            TextField("Search the handbook", text: $handbook.query, prompt: Text(verbatim: "Search the handbook"))
                .brahmaField(compact: true)
                .frame(width: 240)
                .onSubmit { Task { await handbook.runSearch() } }
                .onChange(of: handbook.query) { Task { await handbook.runSearch() } }
        case .memory:
            TextField("Filter facts", text: Bindable(handbook.memory).filter.query, prompt: Text(verbatim: "Filter facts"))
                .brahmaField(compact: true)
                .frame(width: 240)
                .onChange(of: handbook.memory.filter.query) { Task { await handbook.memory.reload() } }
        }
    }

    // MARK: PAGES

    private var pages: some View {
        HStack(spacing: BrahmaTheme.spaceS) {
            Panel(title: handbook.query.trimmingCharacters(in: .whitespaces).isEmpty ? "Pages" : "Search", padded: false, accessory: {
                MonoChip(text: handbook.query.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "\(handbook.pages.count)" : (handbook.isSearching ? "…" : "\(handbook.searchHits.count)"))
            }) {
                if handbook.query.trimmingCharacters(in: .whitespaces).isEmpty { tree } else { hits }
            }
            .frame(width: 250)
            KBPageView(handbook: handbook)
            VStack(spacing: BrahmaTheme.spaceS) {
                backlinks
                recent
            }
            .frame(width: 250)
        }
    }

    private var tree: some View {
        let rows = HandbookTree.rows(handbook.tree)
        return Group {
            if rows.isEmpty {
                MonoEmptyState("No pages yet")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            treeRow(row, index: index)
                        }
                    }
                }
            }
        }
    }

    private func treeRow(_ row: HandbookTreeRow, index: Int) -> some View {
        let selected = handbook.selection?.lowercased() == row.node.path.lowercased()
        return HStack(spacing: 6) {
            Image(systemName: row.node.isPage ? (row.node.children.isEmpty ? "doc.text" : "book.closed") : "folder")
                .font(.system(size: 9))
                .foregroundStyle(selected ? BrahmaTheme.accent : BrahmaTheme.text2)
                .frame(width: 12)
            Text(verbatim: row.node.title)
                .font(row.depth == 0 ? BrahmaTheme.bodyStrong : BrahmaTheme.body)
                .foregroundStyle(row.node.isPage ? (selected ? BrahmaTheme.text0 : BrahmaTheme.text1) : BrahmaTheme.text2)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 2)
            ForEach(row.node.chips, id: \.self) { HandbookChip(label: $0) }
        }
        .padding(.leading, CGFloat(row.depth) * BrahmaTheme.spaceM)
        .tableRow(index: index, selected: selected, height: BrahmaTheme.denseRowHeight)
        .onTapGesture { if row.node.isPage { Task { await handbook.select(row.node.path) } } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var hits: some View {
        Group {
            if handbook.searchHits.isEmpty {
                MonoEmptyState(handbook.isSearching ? "Searching" : "No pages match")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(handbook.searchHits.enumerated()), id: \.element.docId) { index, hit in
                            Button { Task { await handbook.select(hit.ref) } } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(verbatim: hit.ref).font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2)
                                            .lineLimit(1).truncationMode(.middle)
                                        if hit.tainted { HandbookChip(label: "TAINTED") }
                                    }
                                    Text(verbatim: hit.snippet ?? hit.title).font(BrahmaTheme.body)
                                        .foregroundStyle(BrahmaTheme.text0).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                            .tableRow(index: index, height: 46)
                        }
                    }
                }
            }
        }
    }

    // MARK: Right column

    private var backlinks: some View {
        let links = handbook.view?.backlinks ?? []
        return Panel(title: "Backlinks", padded: false, accessory: { MonoChip(text: "\(links.count)") }) {
            if links.isEmpty {
                MonoEmptyState("No backlinks")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(links.enumerated()), id: \.offset) { index, path in
                            Button { Task { await handbook.select(path) } } label: {
                                Text(verbatim: "kb:" + path).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.accent)
                                    .lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .tableRow(index: index, height: BrahmaTheme.denseRowHeight)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 200)
    }

    private var recent: some View {
        Panel(title: "Recently changed", padded: false, accessory: { MonoChip(text: "\(handbook.recent.count)") }) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(handbook.recent.enumerated()), id: \.element.path) { index, page in
                        Button { Task { await handbook.select(page.path) } } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: page.title).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text0).lineLimit(1)
                                Text(verbatim: handbook.recentLine(page)).font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .tableRow(index: index, selected: handbook.selection?.lowercased() == page.path.lowercased(), height: 36)
                    }
                }
            }
        }
    }
}

/// A Handbook / memory chip in its token color: TAINTED, RESTRICTED and CONTRADICTED `warning`; DRAFT `ready`; AUTO,
/// DEPRECATED, PURGED and the rest `text2`.
struct HandbookChip: View {
    let label: String

    var body: some View {
        StatusChip(label: label, color: color).fixedSize()
    }

    private var color: Color {
        if label.hasPrefix("RESTRICTED") { return BrahmaTheme.warning }
        switch label {
        case "TAINTED", "CONTRADICTED": return BrahmaTheme.warning
        case "DRAFT": return BrahmaTheme.ready
        case "INHERITED": return BrahmaTheme.text1
        default: return BrahmaTheme.text2
        }
    }
}

/// A dismissible one-line refusal or failure, in `danger`.
struct ErrorStrip: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: BrahmaTheme.spaceS) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(BrahmaTheme.danger)
            Text(verbatim: text).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.danger)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: BrahmaTheme.spaceS)
            Button("Dismiss", action: dismiss).buttonStyle(.brahma)
        }
        .padding(BrahmaTheme.spaceS)
        .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.danger.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.danger, lineWidth: 1))
    }
}
