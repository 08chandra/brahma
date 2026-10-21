import SwiftUI
import BrahmaAppModel

struct ChatView: View {
    @Bindable var chat: ChatModel
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        VStack(spacing: 0) {
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
                            MessageRow(item: item, role: chat.role(of: item.senderHandle), handles: Set(chat.handles))
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, BrahmaTheme.spaceL)
                    .padding(.vertical, BrahmaTheme.spaceM)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { scrollToEnd(proxy); markReadIfKey() }
                .onChange(of: chat.messages.last?.id) {
                    scrollToEnd(proxy)
                    markReadIfKey()
                }
                .onChange(of: controlActiveState) { markReadIfKey() }
            }
            Hairline()
            Composer(chat: chat)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrahmaTheme.bg0)
        .navigationTitle(Text(verbatim: chat.title))
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

    var body: some View {
        HStack(alignment: .top, spacing: BrahmaTheme.spaceS) {
            MonogramAvatar(monogram: String(item.senderHandle.prefix(2)).uppercased(),
                           color: item.isOwner ? BrahmaTheme.accent : BrahmaTheme.roleColor(role))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: item.isOwner ? "You" : "@" + item.senderHandle)
                        .font(BrahmaTheme.bodyStrong)
                        .foregroundStyle(BrahmaTheme.text0)
                    if let role, !item.isOwner {
                        Text(verbatim: role).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text2)
                    }
                    Text(verbatim: TimeText.hm(item.message.createdAt))
                        .font(BrahmaTheme.monoSmall)
                        .foregroundStyle(BrahmaTheme.text2)
                }
                Text(Self.styled(MessageText.attributed(item.message.text, handles: handles)))
                    .font(BrahmaTheme.bodyLarge)
                    .foregroundStyle(BrahmaTheme.text0)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
