import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// The owner's merge settings (Plan 4a Task 10) over `MergeSettingsForm`: the batch size `Stepper` (1–8), the strategy
/// `Picker`, the main check command and its timeout. The first rule broken shows in `danger`; Save goes through
/// `AppModel.saveMergeSettings` (the owner-only `Store.setMergeSettings`). A blank command clears the main check.
struct MergeSettingsSheet: View {
    let model: AppModel
    @State private var form: MergeSettingsForm
    @State private var saving = false
    @FocusState private var focus: Field?

    private enum Field { case command, timeout }

    init(model: AppModel) {
        self.model = model
        _form = State(initialValue: model.mergeSettingsForm)
    }

    private var batchSize: Binding<Int> {
        Binding(get: { Int(form.batchSize.trimmingCharacters(in: .whitespaces)) ?? MergeSettings.defaultBatchSize },
                set: { form.batchSize = String($0) })
    }

    var body: some View {
        let validation = form.validate()
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Merge settings")
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                HStack(spacing: BrahmaTheme.spaceM) {
                    VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
                        CapsLabel("Batch size")
                        Stepper(value: batchSize, in: MergeSettings.batchRange) {
                            Text(verbatim: form.batchSize).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text0).frame(width: 20)
                        }
                        .accessibilityLabel(Text("Batch size"))
                    }
                    VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
                        CapsLabel("Strategy")
                        Picker("Strategy", selection: $form.strategy) {
                            ForEach(MergeStrategy.allCases, id: \.self) { s in Text(verbatim: s.title).tag(s) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
                VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
                    CapsLabel("Main check")
                    TextField("Main check", text: $form.mainCheckCommand, prompt: Text(verbatim: "swift test  (blank: none)"))
                        .font(BrahmaTheme.mono)
                        .focused($focus, equals: .command)
                        .brahmaField(focused: focus == .command)
                    Text(verbatim: "Every merge candidate must pass it, in a fresh export, before it lands.")
                        .font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                }
                VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
                    CapsLabel("Timeout (seconds)")
                    TextField("Timeout", text: $form.timeoutSeconds, prompt: Text(verbatim: "600"))
                        .font(BrahmaTheme.mono)
                        .focused($focus, equals: .timeout)
                        .brahmaField(focused: focus == .timeout)
                        .frame(width: 120)
                        .disabled(form.mainCheckCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let validation {
                    Text(verbatim: validation).foregroundStyle(BrahmaTheme.danger).font(BrahmaTheme.monoSmall)
                }
            }
            .padding(BrahmaTheme.spaceL)
            Hairline()
            HStack(spacing: BrahmaTheme.spaceS) {
                Spacer()
                Button("Cancel") { model.presentedSheet = nil }
                    .buttonStyle(.brahma)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.brahmaPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validation != nil || saving)
            }
            .padding(BrahmaTheme.spaceM)
            .background(BrahmaTheme.bg2)
        }
        .frame(width: 460)
        .background(BrahmaTheme.bg1)
    }

    private func save() {
        saving = true
        Task {
            await model.saveMergeSettings(form)
            saving = false
            model.presentedSheet = nil
        }
    }
}
