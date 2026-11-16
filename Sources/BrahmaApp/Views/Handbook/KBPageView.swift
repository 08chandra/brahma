import SwiftUI
import AppKit
import BrahmaCore
import BrahmaAppModel

/// The Handbook's center: the page as the owner reads it. A mono header line (`kb:<path> · REV <n> · @<owner> · UPDATED …`),
/// its chips, the owner's actions (revision menu, Edit, I vouch for this page, Roll back to this revision, status, Export…)
/// and the body, one section at a time: headings verbatim, a `RESTRICTED · <roles>` chip on restricted sections, the text
/// through `SafeMarkdown` (links inert, images never fetched).
struct KBPageView: View {
    let handbook: HandbookModel
    @State private var editing: EditDraft?
    @State private var exportNote: String?

    struct EditDraft: Identifiable {
        var id: String { "\(path)#\(baseRevision)" }
        let path: String
        let baseRevision: Int
        let text: String
    }

    var body: some View {
        Panel(title: handbook.view?.page.title ?? "Page", padded: false, accessory: { exportButton }) {
            if let view = handbook.view {
                VStack(alignment: .leading, spacing: 0) {
                    pageHeader(view)
                    Hairline()
                    ScrollView {
                        VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                            ForEach(handbook.blocks) { block in section(block) }
                        }
                        .padding(BrahmaTheme.spaceM)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                MonoEmptyState("Select a page", detail: exportNote)
            }
        }
        .sheet(item: $editing) { draft in
            KBEditSheet(handbook: handbook, path: draft.path, baseRevision: draft.baseRevision, initial: draft.text) { editing = nil }
        }
    }

    // MARK: Header

    private func pageHeader(_ view: KBView) -> some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            Text(verbatim: handbook.headerLine)
                .font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            chips(view)
            actions(view)
            if let note = exportNote {
                Text(verbatim: note).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(BrahmaTheme.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func chips(_ view: KBView) -> some View {
        let restricted = handbook.pageRestrictedChip
        if view.page.autoKind != nil || view.tainted || view.page.status != .active || restricted != nil || handbook.revision != nil {
            HStack(spacing: BrahmaTheme.spaceXS) {
                if handbook.revision != nil {
                    StatusChip(label: "Old revision · current \(view.page.revision)", color: BrahmaTheme.text1).fixedSize()
                }
                if view.page.autoKind != nil { HandbookChip(label: "AUTO") }
                if view.page.status == .draft { HandbookChip(label: "DRAFT") }
                if view.page.status == .deprecated { HandbookChip(label: "DEPRECATED") }
                if let restricted { HandbookChip(label: restricted) }
                if view.tainted {
                    HandbookChip(label: "TAINTED")
                        .help(Text(verbatim: view.taintReason ?? "written by a session that read outside content"))
                    Text(verbatim: view.taintReason ?? "outside content")
                        .font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.warning).lineLimit(1)
                }
            }
        }
    }

    private func actions(_ view: KBView) -> some View {
        HStack(spacing: BrahmaTheme.spaceS) {
            revisionMenu(view)
            if handbook.canEdit {
                Button { editing = EditDraft(path: view.page.path, baseRevision: view.page.revision, text: view.text) } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.brahma)
            }
            if handbook.canVouch {
                Button("I vouch for this page") { Task { _ = await handbook.vouch() } }.buttonStyle(.brahmaPrimary)
            }
            if handbook.canRollback, let number = handbook.revision {
                Button("Roll back to this revision") { Task { _ = await handbook.rollback(to: number) } }.buttonStyle(.brahma)
            }
            if view.page.autoKind == nil {
                Menu {
                    ForEach(KBStatus.allCases, id: \.self) { status in
                        Button { Task { _ = await handbook.setStatus(status) } } label: {
                            Text(verbatim: status.rawValue.capitalized + (status == view.page.status ? " ✓" : ""))
                        }
                        .disabled(status == view.page.status)
                    }
                } label: {
                    Text(verbatim: "STATUS " + view.page.status.rawValue.uppercased()).font(BrahmaTheme.monoSmall)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(handbook.isWorking)
            }
            Spacer(minLength: 0)
        }
    }

    private func revisionMenu(_ view: KBView) -> some View {
        Menu {
            ForEach(handbook.revisions.reversed(), id: \.number) { r in
                Button { Task { await handbook.show(revision: r.number) } } label: {
                    Text(verbatim: handbook.revisionLabel(r) + (r.number == view.revision ? "  ✓" : ""))
                }
            }
        } label: {
            Text(verbatim: "REV \(view.revision) of \(view.page.revision)").font(BrahmaTheme.monoSmall)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Revisions, newest first, with what each changed")
    }

    private var exportButton: some View {
        Button { export() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
            .buttonStyle(.brahma)
            .disabled(handbook.isWorking)
            .help("Export every page as Markdown into an empty folder")
    }

    // MARK: Body

    @ViewBuilder private func section(_ block: KBBlock) -> some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
            if let heading = block.heading {
                HStack(spacing: BrahmaTheme.spaceS) {
                    Text(verbatim: heading)
                        .font(block.level <= 1 ? BrahmaTheme.companyTitle : block.level == 2 ? BrahmaTheme.bodyLarge.weight(.semibold)
                              : BrahmaTheme.bodyStrong)
                        .foregroundStyle(BrahmaTheme.text0)
                    if let chip = block.restrictedChip { HandbookChip(label: chip) }
                }
            } else if let chip = block.restrictedChip {
                HandbookChip(label: chip)
            }
            if !block.markdown.isEmpty {
                Text(SafeMarkdown.render(block.markdown))
                    .font(BrahmaTheme.body)
                    .foregroundStyle(BrahmaTheme.text0)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, block.restrictedChip == nil ? 0 : BrahmaTheme.spaceS)
        .overlay(alignment: .leading) {
            if block.restrictedChip != nil { Rectangle().fill(BrahmaTheme.warning).frame(width: 2) }
        }
    }

    // MARK: Export

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose an empty folder for the handbook export."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            switch await handbook.export(to: url) {
            case .success(let n): exportNote = "Exported \(n) files to \(url.path)"
            case .failure(.invalid(let message)): handbook.error = message
            }
        }
    }
}
