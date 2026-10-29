import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Adds a secret: the name, a `SecureField` for the value, and the `Test key` toggle. `save` returns whether it was stored (the
/// model shows why not); the value never leaves this sheet except to the vault.
struct SecretSheet: View {
    var title = "Add a secret"
    var initialName = ""
    let save: @MainActor (SecretsForm) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var form = SecretsForm()
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
            CapsLabel(title, font: BrahmaTheme.panelTitle, color: BrahmaTheme.text1)
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
                CapsLabel("Name")
                TextField("Name", text: $form.name, prompt: Text(verbatim: "STRIPE_TEST_KEY"))
                    .brahmaField()
                    .font(BrahmaTheme.mono)
                    .autocorrectionDisabled()
            }
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
                CapsLabel("Value")
                SecureField("Value", text: $form.value, prompt: Text(verbatim: "Pasted here, stored in the vault"))
                    .brahmaField()
                    .font(BrahmaTheme.mono)
            }
            Toggle(isOn: $form.isTest) {
                Text(verbatim: "Test key").font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text0)
            }
            .toggleStyle(.switch)
            .tint(BrahmaTheme.accent)
            .controlSize(.small)
            Text(verbatim: SecretsForm.testKeyCaption)
                .font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2).fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(verbatim: problem).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.danger).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.brahma).keyboardShortcut(.cancelAction)
                Button("Store") {
                    if let why = form.validate() { problem = why; return }
                    busy = true
                    Task {
                        let ok = await save(form)
                        busy = false
                        if ok { dismiss() } else { problem = "Not stored; see the message in the settings panel." }
                    }
                }
                .buttonStyle(.brahmaPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || form.name.isEmpty || form.value.isEmpty)
            }
        }
        .padding(BrahmaTheme.spaceL)
        .frame(width: 420)
        .background(BrahmaTheme.bg1)
        .onAppear { if form.name.isEmpty { form.name = initialName } }
    }
}
