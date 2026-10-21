import SwiftUI
import BrahmaAppModel

struct Composer: View {
    @Bindable var chat: ChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = chat.readOnlyReason {
                Text(verbatim: reason).foregroundStyle(.secondary)
            } else {
                let suggestions = chat.mentionSuggestions
                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions, id: \.self) { handle in
                            Button { chat.acceptMention(handle) } label: {
                                Text(verbatim: "@" + handle).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
                TextField(text: $chat.draft, prompt: Text(verbatim: chat.placeholder), axis: .vertical) { EmptyView() }
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
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
            }
            if let error = chat.sendError {
                Text(verbatim: error).foregroundStyle(.red).font(.caption)
            }
        }
        .padding(12)
    }
}
