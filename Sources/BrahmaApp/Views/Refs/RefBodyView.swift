import SwiftUI
import AppKit
import BrahmaCore
import BrahmaAppModel

/// The OPENED tab's (and chat's inspector's) body for a ref (collab design §1.3): the model's header (gated title and subtitle,
/// chips, actions) over one renderer per `RefContent` case, reusing the existing views — `FileBodyView` (files, resources and
/// artifacts: an artifact ref renders its entry file through the gate, C6 M10), `WebPreviewView` (with `PhoneFrame` for iPhone, inside the AGENT-BUILT strip), `ThreadView`, `AgentNowView`,
/// `FactCardView` — with the engine's words as a mono empty state when it is unavailable.
///
/// The view adds no rule of its own: every string is the model's, every action an `AppModel` method that holds the owner
/// principal (Ruling C6-3).
struct RefBodyView: View {
    let model: AppModel
    let refBody: RefBody
    /// The ref shown, and how it got here (nil while nothing is open).
    let opened: OpenedRef?
    /// Chat's inspector split (adds "Open in preview" and a close button).
    var inspector = false

    var body: some View {
        VStack(spacing: 0) {
            RefHeaderView(model: model, header: refBody.header, opened: opened, inspector: inspector)
            Hairline()
            if !inspector, let opened, let chips = opened.stepChips {
                StepChips(chips: chips, current: opened.stepIndex, select: { i in Task { await model.step(to: i) } }, note: nil,
                          from: opened.origin.answeredBy)
                Hairline()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(BrahmaTheme.bg0)
    }

    @ViewBuilder private var content: some View {
        switch refBody.content {
        case .code(let lines, let firstLine, let highlight, let hasHidden):
            CodeView(lines: lines, firstLine: firstLine, highlight: highlight, hasHidden: hasHidden)
                .refContextMenu(model: model, ref: opened?.ref, title: refBody.header.title)
        case .diff(let diff, let live, let updated):
            // The header carries the model's chips (UNCOMMITTED, LIVE, TAINTED…); the diff draws none of its own.
            DiffView(diff: diff, updatedText: live ? updated : nil)
        case .changes(let key, let compare):
            LiveDiffBody(model: model, key: key, compare: compare)
        case .file(let file, let provenance):
            FileBodyView(body: file, provenance: provenance, builtBy: Self.builtBy(provenance, handles: model.handles))
        case .item(let itemId):
            ItemRefBody(model: model, itemId: itemId)
        case .ask(let askId):
            AskRefBody(model: model, askId: askId)
        case .kb(let markdown, let revision, let backlinks):
            KBRefBody(model: model, markdown: markdown, revision: revision, backlinks: backlinks, path: opened?.ref.id)
        case .preview(let surfaceId, let path, let viewport, let builtBy):
            PreviewRefBody(model: model, surfaceId: surfaceId, path: path, viewport: viewport, builtBy: builtBy)
        case .run(let lines, let footer):
            RunRefBody(lines: lines, footer: footer)
        case .release(let release):
            ReleaseRefBody(model: model, release: release)
        case .thread(let root, let replies):
            ThreadView(model: model, root: root, replies: replies)
        case .agentNow(let now):
            AgentNowView(model: model, now: now)
        case .fact(let answer):
            ScrollView {
                FactCardView(answer: answer, timeZone: model.ownerTimeZone) { ref in RefActions.openInPreview(model: model, ref: ref) }
                    .padding(BrahmaTheme.spaceS)
            }
        case .answer(_, let claims, let refs, let refNotes, let verified, let by, let concierge):
            ScrollView {
                // Ruling C7a-1: "Concierge" only from the model's flag, never from a name.
                AnswerClaimsView(claims: claims, refs: refs, refNotes: refNotes, verified: verified,
                                 by: RefBodies.authorLabel(by: by, concierge: concierge)) { ref in
                    Task { await model.openRef(ref, origin: opened?.origin ?? .owner) }
                }
                .padding(BrahmaTheme.spaceM)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .unavailable(let text):
            if text == "LOADING" {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RefUnavailableView(text: text)
            }
        }
    }

    /// The AGENT-BUILT strip's name for an agent's or an outside file ("@eng-1", the source's detail); empty for the owner's.
    static func builtBy(_ p: Provenance, handles: [String: String]) -> String {
        switch p {
        case .agent(let id): handles[id].map { "@" + $0 } ?? "an agent"
        case .external: "outside content"
        case .owner, .engine: ""
        }
    }
}

// MARK: - Header

/// The ref header: kind chip, the model's gated title and subtitle, its chips (UNCOMMITTED, LIVE, TAINTED · <reason>, REDACTED,
/// LEASED BY, AS SHARED · VIEW LATEST, HIDDEN CHARACTERS, UNVERIFIED), and the actions the model lists (icon buttons with help).
struct RefHeaderView: View {
    let model: AppModel
    let header: RefHeader
    let opened: OpenedRef?
    var inspector = false
    @State private var original: OriginalText?

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
            HStack(alignment: .firstTextBaseline, spacing: BrahmaTheme.spaceS) {
                if let opened { MonoChip(text: opened.kindChip, color: BrahmaTheme.accent, fill: BrahmaTheme.accent.opacity(0.15)) }
                Text(verbatim: header.title)
                    .font(BrahmaTheme.bodyStrong)
                    .foregroundStyle(BrahmaTheme.text0)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(verbatim: header.title))
                Spacer(minLength: BrahmaTheme.spaceS)
                actions
            }
            if !header.subtitle.isEmpty {
                Text(verbatim: header.subtitle).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2).lineLimit(1).truncationMode(.middle)
            }
            if !header.chips.isEmpty { RefChipRow(chips: header.chips) }
        }
        .padding(.horizontal, BrahmaTheme.spaceS)
        .padding(.vertical, BrahmaTheme.spaceXS + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrahmaTheme.bg2)
        .refContextMenu(model: model, ref: opened?.ref, title: header.title, messageId: Self.messageId(opened))
        .sheet(item: $original) { o in OriginalSheet(original: o) }
    }

    static func messageId(_ opened: OpenedRef?) -> String? {
        guard let ref = opened?.ref, ref.kind == .message || ref.kind == .thread else { return nil }
        return ref.id
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 2) {
            if let ref = opened?.ref {
                ForEach(Array(header.actions.enumerated()), id: \.offset) { _, action in button(action, ref: ref) }
            }
            if inspector {
                iconButton("rectangle.portrait.and.arrow.right", "Open in preview") { Task { await model.moveInspectorToPreview() } }
                iconButton("xmark", "Close") { model.closeInspector() }
            } else if opened != nil {
                iconButton("xmark", "Close this tab") { model.closeOpened() }
            }
        }
    }

    @ViewBuilder private func button(_ action: RefAction, ref: WorkRef) -> some View {
        switch action {
        case .copyRef:
            iconButton("doc.on.doc", "Copy ref") { RefActions.copyRef(model: model, ref: ref) }
        case .shareTo:
            iconButton("square.and.arrow.up", "Share to…") { RefSheets.shared.share = RefSheets.Share(refs: [ref]) }
        case .askToExplain:
            iconButton("questionmark.bubble", "Ask to explain") { RefActions.askToExplain(model: model, ref: ref) }
        case .saveAs:
            iconButton("arrow.down.doc", "Save As…") {
                RefActions.saveAs(model: model, ref: ref, suggested: RefActions.suggestedName(ref, title: header.title))
            }
        case .openInChat:
            iconButton("bubble.left.and.bubble.right", "Open in chat") { Task { await model.openInChat(messageId: ref.id) } }
        case .viewOriginal:
            iconButton("eye", "View original") {
                Task {
                    guard let data = await model.viewOriginal(ref) else { return }
                    original = OriginalText(data: data)
                }
            }
        case .vouch:
            iconButton("checkmark.shield", "Vouch") { Task { await model.vouch(ref) } }
        case .purge:
            iconButton("trash", "Purge…", tint: BrahmaTheme.danger) { RefSheets.shared.purge = RefSheets.Purge(ref: ref, title: header.title) }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, tint: Color = BrahmaTheme.text1, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.bg3))
                .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.lineStrong, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(verbatim: help))
    }
}

/// View original's bytes (owner only, through `gatedBytes`: a vouched PDF is its flattened copy): text verbatim with markers,
/// capped; anything else as its size.
struct OriginalText: Identifiable {
    let id = UUID()
    let data: Data
    static let maxShown = 200_000
}

private struct OriginalSheet: View {
    let original: OriginalText
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            HStack {
                CapsLabel("Original", font: BrahmaTheme.panelTitle, color: BrahmaTheme.text1)
                Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(original.data.count), countStyle: .file))
                    .font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.brahma)
            }
            if original.data.prefix(8192).contains(0) {
                RefUnavailableView(caption: "BINARY", text: "Save it with Save As… to open it in another app.")
            } else {
                ScrollView {
                    RefStyle.marked(String(decoding: original.data.prefix(OriginalText.maxShown), as: UTF8.self))
                        .font(BrahmaTheme.monoSmall)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(BrahmaTheme.spaceS)
                }
                .background(BrahmaTheme.bg0)
            }
        }
        .padding(BrahmaTheme.spaceM)
        .frame(width: 620, height: 460)
        .background(BrahmaTheme.bg1)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Bodies

/// A live item diff in the OPENED tab: the CHANGES model's latest verified yield (`AppModel.changes`), or its refusal. LIVE is
/// drawn only over a diff the model verified; the header's chips are the model's (`liveOpenedBody`).
private struct LiveDiffBody: View {
    let model: AppModel
    let key: String
    let compare: CompareMode

    var body: some View {
        if let changes = model.changes, changes.selectedKey == key, changes.compare == compare {
            // Fix round 1 (M-4): a refusal first — a refused or failed generation never draws the previous diff.
            if let error = changes.error {
                RefUnavailableView(text: error)
            } else if let diff = changes.diff, let snapshot = changes.snapshot {
                // The model's chips are the header's (`liveOpenedBody`); the diff draws none of its own.
                DiffView(diff: diff, updatedAt: snapshot.computedAt)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// An item ref: its key, status, holder and type (engine fields), with "Open in backlog" for the item sheet. The title is the
/// header's (gated); the item's own text is read in the backlog.
private struct ItemRefBody: View {
    let model: AppModel
    let itemId: String

    var body: some View {
        if let item = model.work.items.first(where: { $0.id == itemId }) {
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                KeyValueGrid(rows: [
                    KeyValueRow(label: "Key", value: item.key, mono: true),
                    KeyValueRow(label: "Type", value: item.type.rawValue),
                    KeyValueRow(label: "Owner", value: item.ownerId.flatMap { model.handles[$0] }.map { "@" + $0 } ?? "—", mono: true),
                ])
                HStack(spacing: BrahmaTheme.spaceS) {
                    ItemStatusChip(status: item.status)
                    Spacer()
                    Button("Open in backlog") { model.apply(.item(key: item.key)) }.buttonStyle(.brahma)
                }
                Spacer(minLength: 0)
            }
            .padding(BrahmaTheme.spaceM)
        } else {
            RefUnavailableView(text: RefBodies.unavailableText)
        }
    }
}

/// An ask ref: a file request is its Inbox card (gated, with the drop zone); any other ask its status and "Open in Inbox".
private struct AskRefBody: View {
    let model: AppModel
    let askId: String

    var body: some View {
        if let row = model.inboxRows.first(where: { $0.id == askId }),
           let ask = model.work.inbox.first(where: { $0.id == askId }), FileRequests.isFileRequest(ask) {
            ScrollView { FileRequestCardView(model: model, row: row).padding(BrahmaTheme.spaceS) }
        } else {
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                if let row = model.inboxRows.first(where: { $0.id == askId }) {
                    KeyValueGrid(rows: [
                        KeyValueRow(label: "Ask", value: row.ref, mono: true),
                        KeyValueRow(label: "Kind", value: row.kindTitle),
                        KeyValueRow(label: "Risk", value: row.riskLabel),
                        KeyValueRow(label: "From", value: row.requester, mono: true),
                    ])
                } else {
                    Text(verbatim: "DECIDED OR CLOSED").font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                }
                HStack {
                    Spacer()
                    Button("Open in Inbox") { model.apply(.ask(id: askId)) }.buttonStyle(.brahma)
                }
                Spacer(minLength: 0)
            }
            .padding(BrahmaTheme.spaceM)
        }
    }
}

/// A handbook page: the gated Markdown through `SafeMarkdown` (links inert, images never fetched), its revision, the pages and
/// messages that mention it (each opens), and "Open in Handbook" for its revisions.
private struct KBRefBody: View {
    let model: AppModel
    let markdown: String
    let revision: String
    let backlinks: [Backlink]
    let path: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: BrahmaTheme.spaceS) {
                MonoChip(text: "REV \(revision)", color: BrahmaTheme.text1, fill: BrahmaTheme.bg4)
                Spacer()
                if let path { Button("Open in Handbook") { model.apply(.kb(path: path)) }.buttonStyle(.brahma) }
            }
            .padding(.horizontal, BrahmaTheme.spaceS)
            .frame(height: BrahmaTheme.rowHeight + 4)
            .background(BrahmaTheme.bg2)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                    Text(SafeMarkdown.render(markdown))
                        .font(BrahmaTheme.bodyLarge)
                        .foregroundStyle(BrahmaTheme.text0)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !backlinks.isEmpty {
                        Hairline()
                        CapsLabel("Mentioned in")
                        ForEach(Array(backlinks.enumerated()), id: \.offset) { _, link in
                            HStack(spacing: BrahmaTheme.spaceS) {
                                Text(verbatim: link.title).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text1).lineLimit(1)
                                Spacer(minLength: 0)
                                if let id = link.messageId {
                                    RefLinkChip(label: "MESSAGE") { Task { await model.openInChat(messageId: id) } }
                                }
                            }
                        }
                    }
                }
                .padding(BrahmaTheme.spaceM)
            }
        }
    }
}

/// A preview ref (`preview:web/checkout@iphone`): the surface's page at the ref's path and viewport, inside the AGENT-BUILT strip
/// (`WebPreviewView` draws it, with `PhoneFrame` for iPhone); the surface's status while it is not serving.
private struct PreviewRefBody: View {
    let model: AppModel
    let surfaceId: String
    let path: String
    let viewport: PreviewViewport
    let builtBy: String

    var body: some View {
        switch model.previewBody(forTab: PreviewTabID.surface(surfaceId)) {
        case .web(let url, let origin, _):
            WebPreviewView(url: url, origin: origin, path: path, viewport: viewport, builtBy: builtBy,
                           reloadKey: model.snapshot.preview.states[surfaceId]?.commit ?? "")
        case .status(let title, let detail, _):
            MonoEmptyState(title, detail: detail)
        default:
            MonoEmptyState("PREVIEW NOT RUNNING", detail: "Start the preview to see this page.")
        }
    }
}

/// A run's log (ANSI parsed by the model, every line gated) under its footer.
private struct RunRefBody: View {
    let lines: [[AnsiSpan]]
    let footer: String

    var body: some View {
        VStack(spacing: 0) {
            if lines.isEmpty {
                MonoEmptyState("NO OUTPUT")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, spans in
                            AnsiLinesView.line(spans).font(BrahmaTheme.monoSmall).textSelection(.enabled).fixedSize()
                        }
                    }
                    .padding(BrahmaTheme.spaceS)
                }
                .background(BrahmaTheme.bg0)
            }
            Hairline()
            HStack {
                Text(verbatim: footer).font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2).lineLimit(1)
                Spacer(minLength: 0)
                MonoChip(text: "\(lines.count)", color: BrahmaTheme.text2, fill: BrahmaTheme.bg3)
            }
            .padding(.horizontal, BrahmaTheme.spaceS)
            .frame(height: BrahmaTheme.denseRowHeight)
            .background(BrahmaTheme.bg2)
        }
    }
}

/// A release ref: its engine fields and "Open in Releases" for L's inspector (rollback stays there).
private struct ReleaseRefBody: View {
    let model: AppModel
    let release: Release

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
            KeyValueGrid(rows: [
                KeyValueRow(label: "Release", value: "R-\(release.number)", mono: true),
                KeyValueRow(label: "Status", value: release.status.rawValue.uppercased(), mono: true),
                KeyValueRow(label: "Commit", value: String(release.commit.prefix(7)), mono: true),
            ])
            HStack {
                Spacer()
                Button("Open in Releases") { model.apply(.release(ref: "R-\(release.number)")) }.buttonStyle(.brahma)
            }
            Spacer(minLength: 0)
        }
        .padding(BrahmaTheme.spaceM)
    }
}
