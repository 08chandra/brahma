import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// The Inbox card of a `deploy` ask: the release, main's health and the exact engine-composed commands the owner approves.
/// Approval goes through `AppModel.approveDeploy` (`ownerDecide`); the engine then runs exactly these commands once.
struct DeployCardView: View {
    let model: AppModel
    let card: DeployCard
    @State private var note = ""
    @State private var showReject = false
    @State private var busy = false

    private var mainRed: Bool { card.mainHealth.tone == .bad }

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            HStack(spacing: BrahmaTheme.spaceS) {
                Text(verbatim: "DEPLOY · " + card.ref).font(BrahmaTheme.mono.weight(.semibold)).foregroundStyle(BrahmaTheme.text0)
                DangerChip(label: "High risk · reserved")
                Spacer(minLength: 0)
            }
            Text(verbatim: card.title).font(BrahmaTheme.bodyLarge.weight(.semibold)).foregroundStyle(BrahmaTheme.text0).textSelection(.enabled)
            KeyValueGrid(rows: [
                KeyValueRow(label: "Version", value: card.version, mono: true),
                KeyValueRow(label: "Commit", value: card.commit, mono: true),
                KeyValueRow(label: "Provider", value: card.provider),
                KeyValueRow(label: "Proposed by", value: card.proposer, mono: true),
            ])
            HStack(spacing: BrahmaTheme.spaceS) {
                CapsLabel("Main")
                StatusChip(label: card.mainHealth.title, color: PreviewPane<EmptyView>.toneColor(card.mainHealth.tone),
                           pulse: card.mainHealth.tone == .busy)
            }
            CapsLabel("Commands")
            MonoBlock(text: card.commands, maxHeight: 180)
            Text(verbatim: "Smoke: " + card.smokeLine).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
            HStack(spacing: BrahmaTheme.spaceS) {
                Button("Approve & Deploy") { run { await model.approveDeploy(askId: card.askId) } }
                    .buttonStyle(.brahmaPrimary)
                    .disabled(busy || mainRed)
                    .help(mainRed ? "main is red" : "The engine runs exactly these commands once")
                Button("Reject…") { showReject = true }
                    .buttonStyle(.brahma)
                    .disabled(busy)
                    .popover(isPresented: $showReject, arrowEdge: .bottom) { rejectPopover }
                Spacer()
            }
            Text(verbatim: "The engine runs exactly these commands once. Your token stays in the Keychain.")
                .font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
        }
        .padding(BrahmaTheme.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrahmaTheme.bg2)
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.line, lineWidth: 1))
        .overlay(alignment: .leading) { Rectangle().fill(BrahmaTheme.warning).frame(width: 2) }
    }

    private var rejectPopover: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
            CapsLabel("Reject \(card.ref)")
            TextField("Why", text: $note, prompt: Text(verbatim: "Note for DevOps (optional)"), axis: .vertical).lineLimit(1...4).brahmaField()
            HStack {
                Spacer()
                Button("Cancel") { showReject = false }.buttonStyle(.brahma)
                Button("Reject") {
                    showReject = false
                    run { await model.rejectDeploy(askId: card.askId, note: note) }
                }
                .buttonStyle(.brahmaPrimary)
            }
        }
        .padding(BrahmaTheme.spaceM)
        .frame(width: 320)
        .background(BrahmaTheme.bg1)
    }

    private func run(_ work: @escaping @MainActor () async -> Void) {
        busy = true
        Task { await work(); busy = false }
    }
}
