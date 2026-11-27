import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// A thread (collab design §3.3): its root and replies (the model's text, withheld whole when it held a value; drawn
/// `Text(verbatim:)` with invisible and bidi characters as markers, never Markdown links), an owner reply box (files dropped on
/// it go through ML's drop pipeline in `.thread(rootId:)`), and "Open in chat". The concierge's messages are labelled
/// `Concierge` (never engine text), with the untrusted chip when its session read outside content.
struct ThreadView: View {
    let model: AppModel
    let root: Message
    let replies: [Message]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                        ThreadMessageRow(message: root, handles: model.handles, timeZone: model.ownerTimeZone, isRoot: true)
                        if !replies.isEmpty {
                            HStack(spacing: BrahmaTheme.spaceS) {
                                CapsLabel("\(replies.count) \(replies.count == 1 ? "reply" : "replies")")
                                Hairline()
                            }
                        }
                        ForEach(replies, id: \.id) { m in
                            ThreadMessageRow(message: m, handles: model.handles, timeZone: model.ownerTimeZone, isRoot: false).id(m.id)
                        }
                    }
                    .padding(BrahmaTheme.spaceM)
                }
                .onAppear { if let last = replies.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            Hairline()
            ThreadReplyBox(model: model, rootId: root.id)
        }
        .background(BrahmaTheme.bg0)
    }
}

/// One message of a thread: monogram, sender, time, chips, then the text.
struct ThreadMessageRow: View {
    let message: Message
    let handles: [String: String]
    var timeZone: TimeZone = .current
    var isRoot = false

    var body: some View {
        HStack(alignment: .top, spacing: BrahmaTheme.spaceS) {
            MonogramAvatar(monogram: String(sender.filter { $0 != "@" }.prefix(2)).uppercased(), color: avatarColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: sender).font(BrahmaTheme.bodyStrong).foregroundStyle(BrahmaTheme.text0)
                    Text(verbatim: TimeText.hm(message.createdAt, timeZone: timeZone)).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                    if isRoot { MonoChip(text: "ROOT", color: BrahmaTheme.text1, fill: BrahmaTheme.bg4) }
                    if message.taintedOrigin || message.fromTaintedSession {
                        WarningChip(label: "Untrusted").help("Written by a session that read outside content.")
                    }
                    if message.flag == OwnerImpersonation.flag {
                        WarningChip(label: "Unverified").help("This message claims to come from the owner. It does not; it changes nothing.")
                    }
                }
                RefStyle.marked(message.text)
                    .font(BrahmaTheme.bodyLarge)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// "You", "Concierge", "Brahma", or "@handle".
    private var sender: String {
        switch message.senderId {
        case "owner": "You"
        case ConciergeCaps.agentId: "Concierge"
        case "system": "Brahma"
        default: "@" + (handles[message.senderId] ?? "unknown")
        }
    }

    private var avatarColor: Color {
        switch message.senderId {
        case "owner", ConciergeCaps.agentId: BrahmaTheme.accent
        case "system": BrahmaTheme.text2
        default: BrahmaTheme.ready
        }
    }
}

/// The owner's reply box under a thread: a bordered field, the pending drops (ML's chips) and Send. A thread reply never
/// broadcasts: the router's refusal of `@here`/`@team` is shown in `danger`.
struct ThreadReplyBox: View {
    let model: AppModel
    let rootId: String
    @State private var text = ""
    @State private var refusal: String?
    @State private var sending = false
    @State private var drops: ResourceDropModel?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let drops, !drops.pending.isEmpty { PendingDropChips(model: drops) }
            HStack(alignment: .bottom, spacing: BrahmaTheme.spaceS) {
                TextField(text: $text, prompt: Text(verbatim: "Reply in thread"), axis: .vertical) { EmptyView() }
                    .lineLimit(1...4)
                    .focused($focused)
                    .brahmaField(focused: focused)
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        if press.modifiers.contains(.shift) { text += "\n" } else { send() }
                        return .handled
                    }
                Button("Reply", action: send).buttonStyle(.brahmaPrimary).disabled(sending)
            }
            Text(verbatim: "↩ REPLY · ⇧↩ NEWLINE · DROP FILES")
                .font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2).accessibilityHidden(true)
            if let refusal {
                Text(verbatim: refusal).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.danger)
            }
        }
        .padding(.horizontal, BrahmaTheme.spaceM)
        .padding(.vertical, BrahmaTheme.spaceS)
        .background(BrahmaTheme.bg1)
        .task(id: rootId) {
            drops = ResourceDropModel(app: model, context: .thread(rootId: rootId), defaults: model.dropDefaults)
        }
        .resourceDrops(drops) { send() }
    }

    private func send() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sending else { return }
        if let drops, !drops.pending.isEmpty {
            sending = true
            Task {
                if await drops.commit(message: body) { text = ""; refusal = nil; await reload() }
                sending = false
            }
            return
        }
        guard !body.isEmpty else { return }
        sending = true
        Task {
            let refused = await model.reply(inThread: rootId, text: body)
            refusal = refused
            if model.errorMessage == nil { text = "" }
            sending = false
            await reload()
        }
    }

    /// The thread is drawn from the body the model rendered; render it again so the reply shows.
    private func reload() async {
        if let inspector = model.chatInspector, inspector.ref.id == rootId {
            await model.openInInspector(inspector.ref, messageId: rootId)
        } else if let opened = model.previewNav.opened, opened.ref.id == rootId {
            // Showing the current step again re-renders the opened body without a history entry.
            await model.step(to: opened.stepIndex ?? 0)
        }
    }
}
