import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// The drop-time secret sheet (collab §4.5): store the file as a secret instead, upload a redacted copy, upload it as is
/// (flagged; hidden when a finding is a value already stored as a secret), or cancel the drop.
struct ResourceSecretSheet: View {
    let model: ResourceDropModel
    /// The state the sheet was opened with; the live one (typed name, errors) is the model's.
    let presented: SecretSheetState

    init(model: ResourceDropModel, state: SecretSheetState) {
        self.model = model
        presented = state
    }

    private var state: SecretSheetState { model.secretSheet.flatMap { $0.id == presented.id ? $0 : nil } ?? presented }

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
            CapsLabel("Secret found")
            Text(verbatim: state.title)
                .font(BrahmaTheme.bodyLarge.weight(.semibold)).foregroundStyle(BrahmaTheme.text0)
                .fixedSize(horizontal: false, vertical: true)
            Hairline()
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
                TextField("Secret name", text: name, prompt: Text(verbatim: "SECRET_NAME"))
                    .font(BrahmaTheme.mono)
                    .brahmaField()
                    .disabled(!state.canStoreAsSecret)
                Button(SecretSheetState.storeTitle) {
                    Task { await model.resolveSecret(.storeAsSecret(name: state.secretName)) }
                }
                .buttonStyle(.brahmaPrimary)
                .disabled(!state.canStoreAsSecret || !state.nameIsValid || model.isWorking)
                .help(state.canStoreAsSecret ? "Name: A–Z, 0–9 and _, starting with a letter"
                                             : "Only one text file of up to 64 KB can be stored as a secret")
            }
            HStack(spacing: BrahmaTheme.spaceS) {
                Button(SecretSheetState.redactedTitle) { Task { await model.resolveSecret(.uploadRedacted) } }
                    .buttonStyle(.brahma)
                    .disabled(!state.canUploadRedacted || model.isWorking)
                if state.showsUploadAnyway {
                    Button(SecretSheetState.anywayTitle) { Task { await model.resolveSecret(.uploadAnyway) } }
                        .buttonStyle(.brahma)
                        .disabled(model.isWorking)
                }
                Spacer()
                Button(SecretSheetState.cancelTitle, role: .cancel) { Task { await model.resolveSecret(.none) } }
                    .buttonStyle(.brahma)
                    .keyboardShortcut(.cancelAction)
            }
            if let error = state.error {
                Text(verbatim: error).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(BrahmaTheme.spaceL)
        .frame(width: 460)
        .background(BrahmaTheme.bg1)
    }

    private var name: Binding<String> {
        Binding(get: { model.secretSheet?.secretName ?? "" }, set: { model.secretSheet?.secretName = $0 })
    }
}
