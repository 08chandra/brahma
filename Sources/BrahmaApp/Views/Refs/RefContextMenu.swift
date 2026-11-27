import SwiftUI
import AppKit
import BrahmaCore
import BrahmaAppModel

/// The owner's ref actions (collab design §1.5, §3.6), each through the `AppModel` method that holds the owner principal: the
/// view never builds a principal, never reads the store, and adds no rule of its own.
@MainActor
enum RefActions {
    /// Copy ref: the model's escaped JSON literal (Ruling 58, gated; empty when it held a value, so nothing is copied).
    static func copyRef(model: AppModel, ref: WorkRef) {
        Task {
            let literal = await model.copyRef(ref)
            guard !literal.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(literal, forType: .string)
        }
    }

    /// Ask to explain: the ⌘K palette with "Explain this" typed and the ref attached (`ShowKind.explain`; the routing goes by
    /// the ref). Nothing is sent until the owner presses Enter on the ASK row.
    static func askToExplain(model: AppModel, ref: WorkRef) {
        model.openShow(presentation: .overlay, kind: .explain, attachedRef: OpenedRef.stripped(ref))
        Task { await model.showBar.update(query: "Explain this") }
    }

    /// Save As…: the owner's save panel (suggesting `suggestedName`), then `AppModel.export` (gated, quarantined, recorded).
    static func saveAs(model: AppModel, ref: WorkRef, suggested: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.export(ref, to: url) }
    }

    /// Open in preview: the ref in the OPENED slot of Mission Control.
    static func openInPreview(model: AppModel, ref: WorkRef) {
        model.select(.missionControl)
        Task { await model.openRef(ref, origin: .owner) }
    }

    /// Reply in thread: the message's thread in chat's inspector (its reply box drops into `.thread(rootId:)`).
    static func replyInThread(model: AppModel, messageId: String) {
        Task { await model.openInInspector(WorkRef(kind: .thread, id: messageId), messageId: messageId) }
    }

    /// The file name Save As… suggests (fix round 1, M-3): the model's gated display title, sanitized by the model
    /// (`RefBodies.saveName`: last component, no separators, control, bidi or format characters), never the agent's raw path;
    /// the ref's kind when no title is known.
    static func suggestedName(_ ref: WorkRef, title: String?) -> String {
        RefBodies.saveName(title: title ?? "", kind: ref.kind)
    }
}

/// The sheets ref actions open (Share to…, Quote, the purge confirmation), presented by `RefActionHost` at the window root so a
/// context menu or a card can ask for one.
@MainActor @Observable
final class RefSheets {
    static let shared = RefSheets()

    struct Share: Identifiable {
        let id = UUID()
        var refs: [WorkRef]
        /// Set for Quote: the message quoted (a share of `msg:<id>`).
        var quoteMessageId: String?
    }

    struct Purge: Identifiable {
        let id = UUID()
        var ref: WorkRef
        /// The model's gated title.
        var title: String
    }

    var share: Share?
    var purge: Purge?
    /// What the last purge reported (backups that may hold it), shown once.
    var purgeReport: RefPurgeReport?
}

/// Presents `RefSheets` (attach once, at the window root).
struct RefActionHost: ViewModifier {
    let model: AppModel
    @Bindable private var sheets = RefSheets.shared

    init(model: AppModel) { self.model = model }

    func body(content: Content) -> some View {
        content
            .sheet(item: $sheets.share) { share in
                ShareRefSheet(model: model, share: share)
                    .background(BrahmaTheme.bg1)
                    .preferredColorScheme(.dark)
            }
            .alert(Text(verbatim: "Purge \(sheets.purge?.title ?? "this")?"),
                   isPresented: Binding(get: { sheets.purge != nil }, set: { if !$0 { sheets.purge = nil } })) {
                Button("Purge", role: .destructive) {
                    guard let p = sheets.purge else { return }
                    sheets.purge = nil
                    // The model's purge runs only with this explicit confirmation (`confirmPurge`, M6).
                    model.confirmPurge = p.ref.kind == .resource ? "F-\(p.ref.id)" : p.ref.canonical
                    Task {
                        if let report = await model.purge(p.ref) { sheets.purgeReport = report }
                    }
                }
                Button("Cancel", role: .cancel) { sheets.purge = nil }
            } message: {
                Text(verbatim: "This deletes the stored bytes and share refs. Backups that contain it are listed for you to delete.")
            }
            .alert("Purged", isPresented: Binding(get: { sheets.purgeReport != nil }, set: { if !$0 { sheets.purgeReport = nil } })) {
                Button("OK") { sheets.purgeReport = nil }
            } message: {
                Text(verbatim: Self.reportText(sheets.purgeReport))
            }
    }

    static func reportText(_ r: RefPurgeReport?) -> String {
        guard let r else { return "" }
        var lines = ["Removed \(r.vaultPaths.count) stored file(s) and \(r.gitRefs.count) share ref(s)."]
        if !r.backupsFlagged.isEmpty { lines.append("Backups that may contain it: " + r.backupsFlagged.joined(separator: ", ")) }
        if r.stillInHistory { lines.append("It is committed: the company's git history still holds it.") }
        return lines.joined(separator: "\n")
    }
}

extension View {
    func refActionHost(model: AppModel) -> some View { modifier(RefActionHost(model: model)) }

    /// The ref context menu (collab design §3.6): Ask to explain, Copy ref, Share to…, Quote and Reply in thread (for a
    /// message: `messageId` is quoted, `threadRoot` — the message itself unless it is a reply — is the thread replied in),
    /// Save As…, Open in preview. Nothing for a nil ref (a locked card opens nothing).
    func refContextMenu(model: AppModel, ref: WorkRef?, title: String? = nil, messageId: String? = nil, threadRoot: String? = nil) -> some View {
        let root = threadRoot ?? messageId
        return contextMenu {
            if let ref {
                Button("Ask to explain") { RefActions.askToExplain(model: model, ref: ref) }
                Button("Copy ref") { RefActions.copyRef(model: model, ref: ref) }
                Button("Share to…") { RefSheets.shared.share = RefSheets.Share(refs: [ref]) }
                if let messageId {
                    Button("Quote") { RefSheets.shared.share = RefSheets.Share(refs: [], quoteMessageId: messageId) }
                    Button("Reply in thread") { RefActions.replyInThread(model: model, messageId: root ?? messageId) }
                }
                Divider()
                Button("Save As…") { RefActions.saveAs(model: model, ref: ref, suggested: RefActions.suggestedName(ref, title: title)) }
                Button("Open in preview") { RefActions.openInPreview(model: model, ref: ref) }
            } else if let messageId {
                Button("Quote") { RefSheets.shared.share = RefSheets.Share(refs: [], quoteMessageId: messageId) }
                Button("Reply in thread") { RefActions.replyInThread(model: model, messageId: root ?? messageId) }
            }
        }
    }
}

/// Share to… / Quote: where (`@handle` or `#channel`) and an optional note, then `AppModel.share` / `AppModel.quote`.
struct ShareRefSheet: View {
    let model: AppModel
    let share: RefSheets.Share
    @Environment(\.dismiss) private var dismiss
    @State private var to = ""
    @State private var note = ""
    @State private var busy = false

    private var isQuote: Bool { share.quoteMessageId != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
            CapsLabel(isQuote ? "Quote" : "Share to", font: BrahmaTheme.panelTitle, color: BrahmaTheme.text1)
            if !isQuote {
                HStack(spacing: BrahmaTheme.spaceXS) {
                    ForEach(Array(share.refs.enumerated()), id: \.offset) { _, ref in
                        MonoChip(text: OpenedRef.kindChip(for: ref), color: BrahmaTheme.text1, fill: BrahmaTheme.bg4)
                    }
                }
            }
            TextField("To", text: $to, prompt: Text(verbatim: "@handle or #channel"))
                .font(BrahmaTheme.mono)
                .brahmaField()
            if !isQuote {
                TextField("Note", text: $note, prompt: Text(verbatim: "A note (optional, \(ShareLimits.noteMax) characters)"), axis: .vertical)
                    .lineLimit(2...5)
                    .brahmaField()
            }
            Text(verbatim: "Readers of the source see it; anyone else sees a locked chip.")
                .font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.brahma)
                Button(isQuote ? "Quote" : "Share") { submit() }
                    .buttonStyle(.brahmaPrimary)
                    .disabled(busy || to.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(BrahmaTheme.spaceL)
        .frame(width: 380)
    }

    private func submit() {
        let target = to.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        Task {
            let ok: Bool
            if let id = share.quoteMessageId {
                ok = await model.quote(messageId: id, to: target)
            } else {
                let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
                ok = await model.share(refs: share.refs, to: target, note: n.isEmpty ? nil : n)
            }
            busy = false
            if ok { dismiss() }
        }
    }
}
