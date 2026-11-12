import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// The Inbox card of a pending deploy or human task whose live card can't be built (`LiveCardFallback`, I3): read-only, with
/// no Approve. A deploy without its release record can only be rejected (its exact commands can't be shown); a human task
/// whose details don't parse can only be declined with a note.
struct LiveCardFallbackView: View {
    let model: AppModel
    let row: InboxRow
    let fallback: LiveCardFallback
    @State private var note = ""
    @State private var showPopover = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            HStack(spacing: BrahmaTheme.spaceS) {
                Text(verbatim: fallback.title(ref: row.ref)).font(BrahmaTheme.mono.weight(.semibold)).foregroundStyle(BrahmaTheme.text0)
                if fallback == .deployUnavailable { DangerChip(label: "High risk · reserved") } else { WarningChip(label: "Needs you") }
                Spacer(minLength: 0)
            }
            if !row.title.isEmpty {
                Text(verbatim: row.title).font(BrahmaTheme.bodyLarge.weight(.semibold)).foregroundStyle(BrahmaTheme.text0).textSelection(.enabled)
            }
            Text(verbatim: "from " + row.requester).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
            Text(verbatim: explanation).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: BrahmaTheme.spaceS) {
                if fallback.canReject {
                    Button("Reject…") { showPopover = true }.buttonStyle(.brahma).disabled(busy)
                        .popover(isPresented: $showPopover, arrowEdge: .bottom) { popover }
                }
                if fallback.canDecline {
                    Button("Can't do…") { showPopover = true }.buttonStyle(.brahma).disabled(busy)
                        .popover(isPresented: $showPopover, arrowEdge: .bottom) { popover }
                }
                Spacer()
            }
        }
        .padding(BrahmaTheme.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrahmaTheme.bg2)
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.line, lineWidth: 1))
        .overlay(alignment: .leading) { Rectangle().fill(BrahmaTheme.warning).frame(width: 2) }
    }

    private var explanation: String {
        switch fallback {
        case .deployUnavailable:
            "The engine has no release record for this deploy, so its exact commands can't be shown and it can't be approved here. Reject it and DevOps can propose it again."
        case .humanTaskUnreadable:
            "This task's details can't be read. You can decline it with a note."
        }
    }

    private var noteRequired: Bool { fallback.canDecline }

    private var popover: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
            CapsLabel(fallback.canReject ? "Reject \(row.ref)" : "Can't do \(row.ref)")
            TextField("Why", text: $note, prompt: Text(verbatim: noteRequired ? "Note (required)" : "Note (optional)"), axis: .vertical)
                .lineLimit(1...4).brahmaField()
            HStack {
                Spacer()
                Button("Cancel") { showPopover = false }.buttonStyle(.brahma)
                Button(fallback.canReject ? "Reject" : "Decline") {
                    showPopover = false
                    let askId = row.id, text = note, reject = fallback.canReject
                    busy = true
                    Task {
                        if reject { await model.rejectDeploy(askId: askId, note: text) }
                        else { await model.declineHumanTask(askId: askId, note: text) }
                        busy = false
                    }
                }
                .buttonStyle(.brahmaPrimary)
                .disabled(noteRequired && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(BrahmaTheme.spaceM)
        .frame(width: 320)
        .background(BrahmaTheme.bg1)
    }
}
