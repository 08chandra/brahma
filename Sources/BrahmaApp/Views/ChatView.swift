import SwiftUI
import BrahmaAppModel

struct ChatView: View {
    @Bindable var chat: ChatModel
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if chat.hasEarlier {
                            Button("Load earlier messages") { Task { await chat.loadEarlier() } }
                                .buttonStyle(.link)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(chat.messages) { item in
                            MessageRow(item: item, role: chat.role(of: item.senderHandle), handles: Set(chat.handles))
                                .id(item.id)
                        }
                    }
                    .padding(16)
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
            Divider()
            Composer(chat: chat)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

private struct MessageRow: View {
    let item: ChatMessage
    let role: String?
    let handles: Set<String>

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: String(item.senderHandle.prefix(1)).uppercased())
                .font(.headline)
                .frame(width: 32, height: 32)
                .background(Circle().fill(item.isOwner ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.2)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: item.isOwner ? "You" : "@" + item.senderHandle).bold()
                    if let role, !item.isOwner {
                        Text(verbatim: role).foregroundStyle(.secondary)
                    }
                    Text(verbatim: TimeText.hm(item.message.createdAt)).font(.caption).foregroundStyle(.secondary)
                }
                Text(MessageText.attributed(item.message.text, handles: handles))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
