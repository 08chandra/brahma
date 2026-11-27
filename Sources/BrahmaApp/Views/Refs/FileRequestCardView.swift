import SwiftUI
import AppKit
import BrahmaCore
import BrahmaAppModel

/// An agent's file request in the Inbox (collab design §3.4): the engine's gated card (`AppModel.fileRequestCard`: every
/// agent-written field its final display string, `[withheld: …]` when it held a value, impersonation flagged), a drop zone that
/// answers it through ML's pipeline (`DropContext.inbox(askId:)`: scope chooser, trust chip, secret sheet), and "Can't provide →
/// reply" (`AppModel.declineFileRequest`: the engine records the decline, fix round 1 M-9). Without the stored values nothing the agent wrote is shown.
struct FileRequestCardView: View {
    let model: AppModel
    let row: InboxRow
    @State private var card: FileRequestCard?
    @State private var loaded = false
    @State private var drops: ResourceDropModel?
    @State private var showReply = false
    @State private var reply = ""
    @State private var busy = false
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            HStack(spacing: BrahmaTheme.spaceS) {
                CapsLabel("File request · \(row.ref)", font: BrahmaTheme.panelTitle, color: BrahmaTheme.text1)
                if card?.claimsOwner == true {
                    WarningChip(label: "Unverified").help("This request claims to come from the owner. It does not; it changes nothing.")
                }
                Spacer(minLength: 0)
            }
            if let card {
                Text(verbatim: card.title).font(BrahmaTheme.bodyLarge.weight(.semibold)).foregroundStyle(BrahmaTheme.text0)
                    .textSelection(.enabled)
                Text(verbatim: "from @" + card.requesterHandle.drop { $0 == "@" }).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
                Text(verbatim: card.question).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text0).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let details = card.details, !details.isEmpty {
                    Text(verbatim: details).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text1).textSelection(.enabled)
                }
                if card.status == .pendingOwner { dropArea; controls }
            } else if loaded {
                Text(verbatim: "REFUSED · the stored secrets can't be read, so this request isn't shown.")
                    .font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(BrahmaTheme.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrahmaTheme.bg2)
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.line, lineWidth: 1))
        .overlay(alignment: .leading) { Rectangle().fill(BrahmaTheme.accent).frame(width: 2) }
        .task(id: row.id) {
            card = await model.fileRequestCard(askId: row.id)
            loaded = true
            drops = ResourceDropModel(app: model, context: .inbox(askId: row.id), defaults: model.dropDefaults)
        }
        .resourceDrops(card?.status == .pendingOwner ? drops : nil) { send() }
    }

    /// The drop zone: drop files here (ML's chips once dropped), or choose them.
    private var dropArea: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
            if let drops, !drops.pending.isEmpty {
                PendingDropChips(model: drops)
            } else {
                HStack(spacing: BrahmaTheme.spaceS) {
                    Image(systemName: "tray.and.arrow.down").foregroundStyle(BrahmaTheme.text2)
                    Text(verbatim: "DROP THE FILE HERE").font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                    Spacer(minLength: 0)
                    Button("Choose…", action: choose).buttonStyle(.brahma)
                }
                .padding(BrahmaTheme.spaceS)
                .frame(maxWidth: .infinity, minHeight: 44)
                .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius)
                    .strokeBorder(BrahmaTheme.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: BrahmaTheme.spaceS) {
            Button("Send file") { send() }
                .buttonStyle(.brahmaPrimary)
                .disabled(busy || (drops?.pending.isEmpty ?? true))
            Button("Can't provide → reply") { showReply = true }
                .buttonStyle(.brahma)
                .disabled(busy)
                .popover(isPresented: $showReply, arrowEdge: .bottom) { replyPopover }
            Spacer(minLength: 0)
        }
    }

    private var replyPopover: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            CapsLabel("Reply instead")
            TextField("Reply", text: $reply, prompt: Text(verbatim: "Why you can't, or where it is"), axis: .vertical)
                .lineLimit(2...5)
                .brahmaField()
            HStack {
                Spacer()
                Button("Cancel") { showReply = false }.buttonStyle(.brahma)
                Button("Send reply") {
                    let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    busy = true
                    Task {
                        _ = await model.declineFileRequest(askId: row.id, note: text)
                        busy = false
                        showReply = false
                    }
                }
                .buttonStyle(.brahmaPrimary)
                .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(BrahmaTheme.spaceM)
        .frame(width: 320)
        .background(BrahmaTheme.bg1)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let drops else { return }
        let urls = panel.urls
        Task { await drops.add(urls: urls) }
    }

    private func send() {
        guard let drops, !drops.pending.isEmpty, !busy else { return }
        busy = true
        Task {
            _ = await drops.commit(message: "")
            busy = false
        }
    }
}
