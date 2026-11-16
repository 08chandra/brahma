import SwiftUI
import BrahmaAppModel

/// The owner's page editor: the whole page in a mono `TextEditor`, saved on the revision it was opened at. A conflict (the
/// page changed meanwhile) or any refusal shows the Store's text, exactly, and the sheet stays open with the edit.
struct KBEditSheet: View {
    let handbook: HandbookModel
    let path: String
    let baseRevision: Int
    let close: () -> Void
    @State private var text: String
    @State private var saving = false

    init(handbook: HandbookModel, path: String, baseRevision: Int, initial: String, close: @escaping () -> Void) {
        self.handbook = handbook
        self.path = path
        self.baseRevision = baseRevision
        self.close = close
        _text = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
            HStack(spacing: BrahmaTheme.spaceS) {
                CapsLabel("Edit page")
                Text(verbatim: "kb:\(path) · REV \(baseRevision)").font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
                    .lineLimit(1).truncationMode(.middle)
            }
            TextEditor(text: $text)
                .font(BrahmaTheme.mono)
                .foregroundStyle(BrahmaTheme.text0)
                .scrollContentBackground(.hidden)
                .padding(BrahmaTheme.spaceXS)
                .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.bg2))
                .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.lineStrong, lineWidth: 1))
                .frame(minHeight: 360)
            if let error = handbook.error {
                Text(verbatim: error).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.danger)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(verbatim: "Sections marked [restricted] stay restricted. Secrets are refused.")
                    .font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2)
                Spacer()
                Button("Cancel", role: .cancel) {
                    handbook.error = nil
                    close()
                }
                .buttonStyle(.brahma)
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    saving = true
                    Task {
                        let ok = await handbook.save(edit: text, baseRevision: baseRevision)
                        saving = false
                        if ok { close() }
                    }
                }
                .buttonStyle(.brahmaPrimary)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(saving || handbook.isWorking)
            }
        }
        .padding(BrahmaTheme.spaceL)
        .frame(width: 720, height: 520)
        .background(BrahmaTheme.bg1)
        .onAppear { handbook.error = nil }
    }
}
