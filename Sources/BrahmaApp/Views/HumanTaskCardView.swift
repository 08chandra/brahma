import SwiftUI
import AppKit
import BrahmaCore
import BrahmaAppModel

/// The Inbox card of a `humanTask` ask: what an agent (or the engine) needs the owner to do by hand, with numbered steps,
/// links as host plus Open, the editable launch post, and paste-back fields. Secret fields are `SecureField`s whose values
/// go to the owner's Keychain through `AppModel.completeHumanTask`; everything agent-written is `Text(verbatim:)`.
struct HumanTaskCardView: View {
    let model: AppModel
    let card: HumanTaskCard
    @State private var values: [String: String] = [:]
    @State private var editedPost = ""
    @State private var validation: String?
    @State private var showDecline = false
    @State private var declineNote = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            header
            if !card.reason.isEmpty { verbatim(card.reason, color: BrahmaTheme.text1) }
            if !card.steps.isEmpty { steps }
            if !card.links.isEmpty { links }
            if card.postText != nil { post }
            if !card.fields.isEmpty { fields }
            if let caption = card.caption {
                Text(verbatim: caption).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            controls
        }
        .padding(BrahmaTheme.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrahmaTheme.bg2)
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.line, lineWidth: 1))
        .overlay(alignment: .leading) { Rectangle().fill(BrahmaTheme.warning).frame(width: 2) }
        .onAppear { if editedPost.isEmpty { editedPost = card.postText ?? "" } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: BrahmaTheme.spaceS) {
                Text(verbatim: "HUMAN TASK · " + card.ref).font(BrahmaTheme.mono.weight(.semibold)).foregroundStyle(BrahmaTheme.text0)
                WarningChip(label: "Needs you")
                Spacer(minLength: 0)
            }
            Text(verbatim: card.title).font(BrahmaTheme.bodyLarge.weight(.semibold)).foregroundStyle(BrahmaTheme.text0).textSelection(.enabled)
            HStack(spacing: BrahmaTheme.spaceS) {
                Text(verbatim: "from " + card.requester).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
                if let key = card.itemKey {
                    Text(verbatim: "·").foregroundStyle(BrahmaTheme.text2)
                    Text(verbatim: key).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
                }
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 3) {
            CapsLabel("Steps")
            ForEach(Array(card.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: BrahmaTheme.spaceS) {
                    Text(verbatim: "\(index + 1).").font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text2).frame(width: 22, alignment: .trailing)
                    verbatim(step, color: BrahmaTheme.text0)
                }
            }
        }
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 3) {
            CapsLabel("Links")
            ForEach(Array(card.links.enumerated()), id: \.offset) { _, link in
                HStack(spacing: BrahmaTheme.spaceS) {
                    Text(verbatim: link.title).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text0).lineLimit(1)
                    Text(verbatim: link.host).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1).lineLimit(1)
                    Spacer(minLength: 0)
                    if let url = URL(string: link.url), url.scheme == "https" {
                        Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.brahma)
                    }
                }
            }
        }
    }

    private var post: some View {
        VStack(alignment: .leading, spacing: 3) {
            CapsLabel("Post text")
            TextEditor(text: $editedPost)
                .font(BrahmaTheme.body)
                .foregroundStyle(BrahmaTheme.text0)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: 60, maxHeight: 160)
                .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.bg0))
                .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.lineStrong, lineWidth: 1))
            Text(verbatim: "You post this from your own account; the engine never sends it.")
                .font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            ForEach(Array(card.fields.enumerated()), id: \.offset) { _, field in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: BrahmaTheme.spaceXS) {
                        CapsLabel(field.label + (field.required ? "" : " (optional)"))
                        if let prefix = field.prefix {
                            Text(verbatim: "· starts with " + prefix).font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2)
                        }
                    }
                    if field.isSecret {
                        SecureField(field.label, text: binding(field.name), prompt: Text(verbatim: field.prefix.map { $0 + "…" } ?? "Paste the key"))
                            .brahmaField()
                        Text(verbatim: "Saved to your Keychain. Test keys are given to agents; other keys stay with the engine.")
                            .font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                    } else {
                        TextField(field.label, text: binding(field.name), prompt: Text(verbatim: field.kind == .url ? "https://…" : "Paste the value"))
                            .font(BrahmaTheme.mono)
                            .brahmaField()
                    }
                }
            }
        }
    }

    @ViewBuilder private var controls: some View {
        if let validation {
            Text(verbatim: validation).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: BrahmaTheme.spaceS) {
            Button("Done") { done() }.buttonStyle(.brahmaPrimary).disabled(busy)
            Button("Can't do…") { showDecline = true }.buttonStyle(.brahma).disabled(busy)
                .popover(isPresented: $showDecline, arrowEdge: .bottom) { declinePopover }
            Spacer()
        }
    }

    private var declinePopover: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
            CapsLabel("Can't do \(card.ref)")
            Text(verbatim: "The requester is told the task was declined, with your note.")
                .font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text0).fixedSize(horizontal: false, vertical: true)
            TextField("Why", text: $declineNote, prompt: Text(verbatim: "Note (required)")).brahmaField()
            HStack {
                Spacer()
                Button("Cancel") { showDecline = false }.buttonStyle(.brahma)
                Button("Decline") {
                    showDecline = false
                    run { await model.declineHumanTask(askId: card.askId, note: declineNote) }
                }
                .buttonStyle(.brahmaPrimary)
                .disabled(declineNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(BrahmaTheme.spaceM)
        .frame(width: 320)
        .background(BrahmaTheme.bg1)
    }

    private func done() {
        // Secret entries leave `values` here, whether the form validates or not (not kept in view state).
        let form = HumanTaskForm.make(card, values: &values, editedPost: editedPost)
        if let message = form.validate(card) {
            validation = message
            return
        }
        validation = nil
        run { await model.completeHumanTask(askId: card.askId, form: form) }
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }

    private func run(_ work: @escaping @MainActor () async -> Void) {
        busy = true
        Task { await work(); busy = false }
    }

    private func verbatim(_ s: String, color: Color) -> some View {
        Text(verbatim: s).font(BrahmaTheme.body).foregroundStyle(color).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
