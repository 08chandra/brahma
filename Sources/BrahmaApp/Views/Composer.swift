import SwiftUI
import AppKit
import BrahmaAppModel

/// Bordered `bg2` field with a monospace hint line. Files, folders and links dropped on it (and images pasted with ⌘V) wait
/// as chips above the field; Send commits them with the typed text as one message (`ChatModel.drops`).
struct Composer: View {
    @Bindable var chat: ChatModel
    /// Plan C C7a: the app, for "Request a file" in an agent DM (nil: no Collab menu).
    var model: AppModel? = nil
    @FocusState private var focused: Bool
    @State private var requestingFile = false

    /// The agent of an owner DM (its handle), the one "Request a file" asks.
    private var dmHandle: String? {
        guard case .dm(let h) = chat.target, h.lowercased() != "system" else { return nil }
        return h
    }

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
                if let replyTo = chat.replyTo {
                    // Plan C C7a: the next send replies in this thread.
                    HStack(spacing: BrahmaTheme.spaceS) {
                        Text(verbatim: "REPLYING IN THREAD").font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.accent)
                        if let model {
                            Button("Open thread") { RefActions.replyInThread(model: model, messageId: replyTo) }.buttonStyle(.plain)
                                .font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text1)
                        }
                        Button { chat.replyTo = nil } label: {
                            Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(BrahmaTheme.text2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Stop replying in the thread"))
                    }
                }
                HStack(alignment: .bottom, spacing: BrahmaTheme.spaceS) {
                    attachMenu
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
        .sheet(isPresented: $requestingFile) {
            if let model, let dmHandle {
                RequestFileSheet(model: model, handle: dmHandle)
                    .background(BrahmaTheme.bg1)
                    .preferredColorScheme(.dark)
            }
        }
    }

    /// Plan C C7a: attach files (ML's drop pipeline, as a drop would) and, in an agent DM, "Request a file".
    @ViewBuilder private var attachMenu: some View {
        if chat.drops != nil || (model != nil && dmHandle != nil) {
            Menu {
                if let drops = chat.drops {
                    Button("Attach files…") {
                        let panel = NSOpenPanel()
                        panel.allowsMultipleSelection = true
                        panel.canChooseDirectories = true
                        guard panel.runModal() == .OK else { return }
                        let urls = panel.urls
                        Task { await drops.add(urls: urls) }
                    }
                }
                if model != nil, let dmHandle {
                    Button("Request a file from @\(dmHandle)…") { requestingFile = true }
                }
            } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(BrahmaTheme.text1)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(height: 30)
            .help("Attach or request a file")
        }
    }
}
