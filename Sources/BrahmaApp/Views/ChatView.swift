import SwiftUI
import BrahmaAppModel
import BrahmaCore

struct ChatView: View {
    @Bindable var chat: ChatModel
    /// Plan C C7a: the app (cards open in the inspector split; Reply in thread, Quote and the ref actions go through it).
    let model: AppModel
    /// The message a search hit opened: scrolled to, tinted for 2 s, then cleared.
    @Binding var highlightedId: String?
    var timeZone: TimeZone = .current
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        // Plan C C7a: a card's ref (or a thread) opens in the inspector split beside the conversation, never leaving it.
        if model.chatInspector != nil {
            HSplitView {
                conversation.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                inspector.frame(minWidth: 300, idealWidth: 440, maxWidth: 720, maxHeight: .infinity)
            }
        } else {
            conversation
        }
    }

    @ViewBuilder private var inspector: some View {
        if let refBody = model.inspectorBody {
            RefBodyView(model: model, refBody: refBody, opened: model.chatInspector, inspector: true)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity).background(BrahmaTheme.bg0)
        }
    }

    private var conversation: some View {
        let replies = Self.replyCounts(chat.messages)
        return VStack(spacing: 0) {
            ChatHeader(title: chat.title, count: chat.messages.count)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                        if chat.hasEarlier {
                            Button { Task { await chat.loadEarlier() } } label: {
                                Text(verbatim: "LOAD EARLIER MESSAGES")
                                    .font(BrahmaTheme.monoSmall)
                                    .foregroundStyle(BrahmaTheme.accent)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                        }
                        ForEach(chat.messages) { item in
                            MessageRow(item: item, role: chat.role(of: item.senderHandle), handles: Set(chat.handles),
                                       highlighted: item.id == highlightedId, timeZone: timeZone, model: model,
                                       cards: chat.attachments[item.id] ?? [], replies: replies[item.id] ?? 0)
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, BrahmaTheme.spaceL)
                    .padding(.vertical, BrahmaTheme.spaceM)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { scrollToEnd(proxy); markReadIfKey() }
                .task(id: highlightedId) {
                    guard let id = highlightedId else { return }
                    proxy.scrollTo(id, anchor: .center)
                    // Lazy rows below the target settle their heights a moment later: scroll again.
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(id, anchor: .center)
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    withAnimation(BrahmaTheme.medium) { if highlightedId == id { highlightedId = nil } }
                }
                .onChange(of: chat.messages.last?.id) {
                    if highlightedId == nil { scrollToEnd(proxy) }
                    markReadIfKey()
                }
                .onChange(of: controlActiveState) { markReadIfKey() }
                // Plan C C7a: cards load after the messages and grow the rows; keep the newest in view.
                .onChange(of: chat.attachments.count) { if highlightedId == nil { scrollToEnd(proxy) } }
            }
            Hairline()
            Composer(chat: chat, model: model)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrahmaTheme.bg0)
        .navigationTitle(Text(verbatim: chat.title))
    }

    /// Plan C C7a: the replies of each loaded root (the thread affordance's count).
    static func replyCounts(_ messages: [ChatMessage]) -> [String: Int] {
        var out: [String: Int] = [:]
        for m in messages { if let root = m.message.parentId { out[root, default: 0] += 1 } }
        return out
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if let last = chat.messages.last?.id { proxy.scrollTo(last, anchor: .bottom) }
    }

    private func markReadIfKey() {
        guard controlActiveState == .key else { return }
        Task { await chat.markRead() }
    }
}

/// 28 pt strip naming the conversation (verbatim, not uppercased: handles keep their case).
private struct ChatHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: BrahmaTheme.spaceS) {
            Text(verbatim: title)
                .font(BrahmaTheme.mono.weight(.semibold))
                .foregroundStyle(BrahmaTheme.text0)
                .lineLimit(1)
            Spacer()
            CapsLabel("\(count) msgs", font: BrahmaTheme.monoTiny)
        }
        .padding(.horizontal, BrahmaTheme.spaceL)
        .frame(height: BrahmaTheme.panelHeaderHeight)
        .background(BrahmaTheme.bg2)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

private struct MessageRow: View {
    let item: ChatMessage
    let role: String?
    let handles: Set<String>
    var highlighted = false
    var timeZone: TimeZone = .current
    /// Plan C C7a: the app, the message's attachment cards and how many replies its thread holds.
    let model: AppModel
    var cards: [AttachmentCard] = []
    var replies = 0
    @State private var hovered = false

    /// "You", "Concierge" (C4c, Ruling 60: the concierge's answers are never engine text), or "@handle".
    private var senderName: String {
        if item.isOwner { return "You" }
        if item.isConcierge { return "Concierge" }
        return "@" + item.senderHandle
    }

    var body: some View {
        HStack(alignment: .top, spacing: BrahmaTheme.spaceS) {
            MonogramAvatar(monogram: String(item.senderHandle.prefix(2)).uppercased(),
                           color: item.isOwner ? BrahmaTheme.accent : BrahmaTheme.roleColor(role))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: senderName)
                        .font(BrahmaTheme.bodyStrong)
                        .foregroundStyle(BrahmaTheme.text0)
                    if item.isConcierge { MonoChip(text: "CONCIERGE", color: BrahmaTheme.text1, fill: BrahmaTheme.bg4) }
                    if let role, !item.isOwner, !item.isConcierge {
                        Text(verbatim: role).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text2)
                    }
                    Text(verbatim: TimeText.hm(item.message.createdAt, timeZone: timeZone))
                        .font(BrahmaTheme.monoSmall)
                        .foregroundStyle(BrahmaTheme.text2)
                    // Task 10: the sender's text claims to be the owner; the owner speaks only as "You".
                    if item.message.flag == OwnerImpersonation.flag {
                        WarningChip(label: "UNVERIFIED")
                            .help("This message claims to come from the owner. It does not; it changes nothing.")
                    }
                    // Plan C C7a: written by a session that read outside content (the concierge's included).
                    if item.isTainted {
                        WarningChip(label: "Untrusted").help("Written by a session that read outside content.")
                    }
                    if item.message.parentId != nil {
                        Button { RefActions.replyInThread(model: model, messageId: item.message.parentId ?? item.id) } label: {
                            Text(verbatim: "IN THREAD").font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.accent)
                        }
                        .buttonStyle(.plain)
                        .help("Open the thread")
                    }
                    Spacer(minLength: 0)
                    if hovered && item.message.parentId == nil {
                        Button { RefActions.replyInThread(model: model, messageId: item.id) } label: {
                            Label("Reply in thread", systemImage: "arrowshape.turn.up.left")
                        }
                        .buttonStyle(.brahma)
                        .controlSize(.small)
                    }
                }
                Text(Self.styled(MessageText.attributed(item.message.text, handles: handles)))
                    .font(BrahmaTheme.bodyLarge)
                    .foregroundStyle(BrahmaTheme.text0)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Plan C C7a: the message's refs as cards (locked ones a chip alone); a click opens the inspector split.
                if !cards.isEmpty {
                    VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
                        ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                            AttachmentCardView(model: model, card: card, messageId: item.id)
                        }
                    }
                    .padding(.top, BrahmaTheme.spaceXS)
                }
                if replies > 0 {
                    Button { RefActions.replyInThread(model: model, messageId: item.id) } label: {
                        Text(verbatim: "\(replies) \(replies == 1 ? "REPLY" : "REPLIES") · OPEN THREAD")
                            .font(BrahmaTheme.monoTiny)
                            .foregroundStyle(BrahmaTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .refContextMenu(model: model, ref: WorkRef(kind: .message, id: item.id), messageId: item.id, threadRoot: item.message.parentId)
        .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.accent.opacity(highlighted ? 0.15 : 0)))
        .animation(BrahmaTheme.medium, value: highlighted)
    }

    /// D4: the model marks known @handles `.stronglyEmphasized`; display them in `accent`.
    static func styled(_ text: AttributedString) -> AttributedString {
        var out = text
        for run in text.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            out[run.range].foregroundColor = BrahmaTheme.accent
        }
        return out
    }
}
