import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// A ref attached to a chat message (collab design §3.5): a hairline panel with the kind chip, the engine title (gated by the
/// model), mono meta, the model's preview (≤ 6 highlighted lines, a diff stat bar, a ≤ 160 pt thumbnail made out of process, a
/// poster with a play glyph, an item's key/status/holder, a run's exit/duration/last failing line, an agent's state) and the
/// model's chips (TAINTED, UNCOMMITTED, REDACTED in `warning`). A locked card shows only `[LOCKED <KIND> · ASK THE OWNER]` in
/// `text2`. A click opens the ref in chat's inspector; the context menu has the ref actions.
struct AttachmentCardView: View {
    let model: AppModel
    let card: AttachmentCard
    let messageId: String

    var body: some View {
        if card.locked {
            Text(verbatim: card.meta == "purged" ? "[PURGED \(card.kindChip)]" : "[LOCKED \(card.kindChip) · ASK THE OWNER]")
                .font(BrahmaTheme.monoTiny)
                .tracking(BrahmaTheme.labelTracking)
                .foregroundStyle(BrahmaTheme.text2)
                .padding(.horizontal, 6)
                .frame(minHeight: BrahmaTheme.chipHeight)
                .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.line, lineWidth: 1))
                .help("You can't open this here. Ask the owner of the source.")
        } else {
            Button(action: open) { content }
                .buttonStyle(.plain)
                .refContextMenu(model: model, ref: card.ref, title: card.title, messageId: messageId)
                .help("Open beside the conversation")
        }
    }

    private func open() {
        guard let ref = card.ref else { return }
        Task { await model.openInInspector(ref, messageId: messageId) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
            HStack(spacing: BrahmaTheme.spaceS) {
                MonoChip(text: card.kindChip, color: BrahmaTheme.text1, fill: BrahmaTheme.bg4)
                Text(verbatim: card.title)
                    .font(BrahmaTheme.bodyStrong)
                    .foregroundStyle(BrahmaTheme.text0)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            if !card.meta.isEmpty {
                Text(verbatim: card.meta).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2).lineLimit(1)
            }
            if !card.chips.isEmpty { RefChipRow(chips: card.chips) }
            preview
        }
        .padding(BrahmaTheme.spaceS)
        .frame(maxWidth: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.bg2))
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.line, lineWidth: 1))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var preview: some View {
        switch card.preview {
        case .code(let lines):
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.prefix(AttachmentCards.previewLines).enumerated()), id: \.offset) { _, spans in
                    RefStyle.text(spans).font(BrahmaTheme.monoSmall).lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(BrahmaTheme.spaceXS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BrahmaTheme.bg0)
        case .diffStat(let added, let removed, let files):
            HStack(spacing: BrahmaTheme.spaceS) {
                DiffView.counts(added: added, removed: removed)
                Text(verbatim: "\(files) \(files == 1 ? "file" : "files")").font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2)
                StatBar(added: added, removed: removed, width: 60)
            }
        case .thumbnail(let url):
            QuickLookView(url: url, thumbnail: true)
                .frame(maxWidth: 240, maxHeight: 160)
                .clipShape(RoundedRectangle(cornerRadius: BrahmaTheme.radius))
        case .poster(let url):
            QuickLookView(url: url, thumbnail: true)
                .frame(maxWidth: 240, maxHeight: 160)
                .overlay {
                    Image(systemName: "play.circle.fill").font(.system(size: 28)).foregroundStyle(BrahmaTheme.text0.opacity(0.85))
                }
                .clipShape(RoundedRectangle(cornerRadius: BrahmaTheme.radius))
        case .item(let key, let status, let holder):
            HStack(spacing: BrahmaTheme.spaceS) {
                Text(verbatim: key).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text0)
                if let s = WorkItemStatus(rawValue: status) { ItemStatusChip(status: s) } else if !status.isEmpty {
                    MonoChip(text: status, color: BrahmaTheme.text1, fill: BrahmaTheme.bg4)
                }
                if let holder, !holder.isEmpty {
                    Text(verbatim: holder).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1).lineLimit(1)
                }
            }
        case .run(let exit, let duration, let lastFailing):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: BrahmaTheme.spaceS) {
                    if let exit {
                        StatusChip(label: "exit \(exit)", color: exit == 0 ? BrahmaTheme.success : BrahmaTheme.danger)
                    }
                    if !duration.isEmpty { Text(verbatim: duration).font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2) }
                }
                if let lastFailing, !lastFailing.isEmpty {
                    RefStyle.marked(lastFailing, color: BrahmaTheme.danger).font(BrahmaTheme.monoSmall).lineLimit(1)
                }
            }
        case .agent(let state):
            if !state.isEmpty { StatusChip(label: state, color: Self.stateColor(state), pulse: state.hasPrefix("running")) }
        case .none:
            EmptyView()
        }
    }

    static func stateColor(_ state: String) -> Color {
        let s = state.lowercased()
        if s.hasPrefix("running") { return BrahmaTheme.running }
        if s == "ready" { return BrahmaTheme.ready }
        if s == "blocked" { return BrahmaTheme.blocked }
        if s == "killed" { return BrahmaTheme.killed }
        return BrahmaTheme.sleeping
    }
}
