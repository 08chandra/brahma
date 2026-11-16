import SwiftUI
import BrahmaAppModel

/// Bordered `bg2` field with a monospace hint line. Files, folders and links dropped on it (and images pasted with ⌘V) wait
/// as chips above the field; Send commits them with the typed text as one message (`ChatModel.drops`).
struct Composer: View {
    @Bindable var chat: ChatModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = chat.readOnlyReason {
                Text(verbatim: reason.uppercased())
                    .font(BrahmaTheme.monoSmall)
                    .foregroundStyle(BrahmaTheme.text2)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            } else {
                let suggestions = chat.mentionSuggestions
                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(suggestions.enumerated()), id: \.element) { index, handle in
                            Button { chat.acceptMention(handle) } label: {
                                Text(verbatim: "@" + handle)
                                    .font(BrahmaTheme.mono)
                                    .foregroundStyle(index == 0 ? BrahmaTheme.text0 : BrahmaTheme.text1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .tableRow(index: index, selected: index == 0, height: BrahmaTheme.denseRowHeight)
                        }
                    }
                    .frame(maxWidth: 280)
                    .clipShape(RoundedRectangle(cornerRadius: BrahmaTheme.radius))
                    .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.line, lineWidth: 1))
                }
                if let drops = chat.drops, !drops.pending.isEmpty { PendingDropChips(model: drops) }
                TextField(text: $chat.draft, prompt: Text(verbatim: chat.placeholder), axis: .vertical) { EmptyView() }
                    .lineLimit(1...6)
                    .focused($focused)
                    .brahmaField(focused: focused)
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        if press.modifiers.contains(.shift) {
                            chat.draft += "\n"
                        } else {
                            Task { await chat.send() }
                        }
                        return .handled
                    }
                    .onKeyPress(.tab) {
                        guard let first = chat.mentionSuggestions.first else { return .ignored }
                        chat.acceptMention(first)
                        return .handled
                    }
                Text(verbatim: chat.drops == nil ? "↩ SEND · ⇧↩ NEWLINE · @ MENTION · ⇥ COMPLETE"
                                                 : "↩ SEND · ⇧↩ NEWLINE · @ MENTION · ⇥ COMPLETE · DROP FILES · ⌘V IMAGE")
                    .font(BrahmaTheme.monoTiny)
                    .foregroundStyle(BrahmaTheme.text2)
                    .accessibilityHidden(true)
            }
            if let error = chat.sendError {
                Text(verbatim: error).foregroundStyle(BrahmaTheme.danger).font(BrahmaTheme.monoSmall)
            }
        }
        .padding(.horizontal, BrahmaTheme.spaceL)
        .padding(.vertical, BrahmaTheme.spaceS)
        .background(BrahmaTheme.bg1)
        .resourceDrops(chat.drops, enabled: chat.readOnlyReason == nil) { Task { await chat.send() } }
        .modifier(PasteImageMonitor(active: focused && chat.drops != nil && chat.readOnlyReason == nil) { png in
            guard let drops = chat.drops else { return }
            Task { await drops.addPasteboardImage(png) }
        })
    }
}
