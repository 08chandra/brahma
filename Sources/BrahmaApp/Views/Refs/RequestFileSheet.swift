import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// "Request a file" (collab design §3.4): what the owner needs, in their own words (at most `FileAskLimits.descriptionMax`
/// characters), optionally for an item, sent as a file ask DM that wakes the agent (`AppModel.sendFileAsk`).
struct RequestFileSheet: View {
    let model: AppModel
    /// The agent asked, without `@`.
    let handle: String
    /// The item the request is for by default (the one it holds), if any.
    var item: String?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var itemKey = ""
    @State private var busy = false

    private var openItems: [WorkItem] { model.work.items.filter { $0.status != .done } }
    private var tooLong: Bool { text.count > FileAskLimits.descriptionMax }

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
            HStack(spacing: BrahmaTheme.spaceS) {
                CapsLabel("Request a file", font: BrahmaTheme.panelTitle, color: BrahmaTheme.text1)
                Text(verbatim: "@" + handle).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text0)
            }
            TextField("What you need", text: $text, prompt: Text(verbatim: "What file do you need, and why?"), axis: .vertical)
                .lineLimit(3...8)
                .brahmaField()
            HStack(spacing: BrahmaTheme.spaceS) {
                CapsLabel("For item")
                Picker("For item", selection: $itemKey) {
                    Text(verbatim: "None").tag("")
                    ForEach(openItems, id: \.id) { i in Text(verbatim: i.key).tag(i.key) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                Spacer()
                Text(verbatim: "\(text.count)/\(FileAskLimits.descriptionMax)")
                    .font(BrahmaTheme.monoTiny)
                    .foregroundStyle(tooLong ? BrahmaTheme.danger : BrahmaTheme.text2)
            }
            Text(verbatim: "The agent answers by sharing the file with you; it shows up in this conversation.")
                .font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.brahma)
                Button("Send request") { send() }
                    .buttonStyle(.brahmaPrimary)
                    .disabled(busy || tooLong || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(BrahmaTheme.spaceL)
        .frame(width: 420)
        .onAppear { itemKey = item ?? "" }
    }

    private func send() {
        busy = true
        Task {
            let ok = await model.sendFileAsk(to: handle, description: text, item: itemKey.isEmpty ? nil : itemKey)
            busy = false
            if ok { dismiss() }
        }
    }
}
