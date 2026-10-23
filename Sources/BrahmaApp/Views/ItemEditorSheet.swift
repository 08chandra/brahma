import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// The item fields shared by the New Item sheet and the backlog inspector. The owner can set anything here except
/// the engine-owned results (`inReview`, `done`, a check verdict).
struct ItemFormFields: View {
    @Binding var form: ItemForm
    /// Handles of the company's agents, for the assignee and reviewer pickers.
    let handles: [String]
    var isNew = false
    /// Non-nil while the spec has not been confirmed by a trusted role: shown beside the intensity picker.
    var unconfirmedNote: String?

    private static let types = [WorkItemType.epic, .story, .task, .bug, .spike].map(\.rawValue)

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
            labeled("Title") {
                TextField("Title", text: $form.title, prompt: Text(verbatim: "What needs doing"))
                    .brahmaField()
            }
            HStack(alignment: .top, spacing: BrahmaTheme.spaceM) {
                labeled("Type") { picker($form.type, options: Self.types) { $0 } }
                labeled("Priority") {
                    picker($form.priority, options: ItemForm.priorities) { "P\($0)" }
                }
                labeled("Tier") { picker($form.tier, options: EffortTier.allCases) { $0.label } }
            }
            labeled("Intensity") {
                HStack(spacing: BrahmaTheme.spaceS) {
                    picker($form.intensity, options: WorkIntensity.allCases) { IntensityText.title($0) }
                    if unconfirmedNote != nil { WarningChip(label: "unconfirmed") }
                }
                if let unconfirmedNote {
                    Text(verbatim: unconfirmedNote).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.warning)
                }
            }
            labeled("Description") { editor($form.description, height: 70) }
            labeled("Acceptance criteria") { editor($form.acceptanceCriteria, height: 54) }
            labeled("Check command (run by the engine)") {
                TextField("Check", text: $form.checkCommand, prompt: Text(verbatim: "e.g. swift test"))
                    .font(BrahmaTheme.mono)
                    .brahmaField()
            }
            if !form.checkCommand.trimmingCharacters(in: .whitespaces).isEmpty {
                labeled("Check timeout (seconds)") {
                    Stepper(value: $form.checkTimeoutSeconds, in: 1...3600, step: 60) {
                        Text(verbatim: "\(form.checkTimeoutSeconds)").font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text0)
                    }
                    .controlSize(.small)
                }
            }
            labeled("Paths it changes (one glob per line)") { editor($form.touchPaths, height: 40, mono: true) }
            HStack(alignment: .top, spacing: BrahmaTheme.spaceM) {
                labeled("Assignee") { handlePicker($form.assignee) }
                labeled("Reviewer") { handlePicker($form.reviewer) }
            }
            if isNew {
                labeled("Parent (item key)") {
                    TextField("Parent", text: $form.parentKey, prompt: Text(verbatim: "optional, e.g. ACME-3"))
                        .font(BrahmaTheme.mono)
                        .brahmaField()
                }
                Toggle(isOn: $form.startReady) {
                    Text(verbatim: "Start Ready (agents can claim it now)").font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text1)
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
            CapsLabel(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func picker<T: Hashable>(_ selection: Binding<T>, options: [T], title: @escaping (T) -> String) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.self) { Text(verbatim: title($0)).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
    }

    private func handlePicker(_ selection: Binding<String>) -> some View {
        Picker("", selection: selection) {
            Text(verbatim: "Unassigned").tag("")
            ForEach(handles, id: \.self) { Text(verbatim: "@" + $0).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
    }

    private func editor(_ text: Binding<String>, height: CGFloat, mono: Bool = false) -> some View {
        TextEditor(text: text)
            .font(mono ? BrahmaTheme.monoSmall : BrahmaTheme.body)
            .foregroundStyle(BrahmaTheme.text0)
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.bg2))
            .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.lineStrong, lineWidth: 1))
    }
}

/// New Item: the owner creates an item; agents never see this form.
struct ItemEditorSheet: View {
    let model: AppModel
    @State private var form = ItemForm()
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "New item")
            ScrollView {
                ItemFormFields(form: $form, handles: model.snapshot.agents.filter { $0.state != .killed }.map(\.name).sorted(),
                               isNew: true)
                    .padding(BrahmaTheme.spaceL)
            }
            if let message = form.validate(knownHandles: Set(model.snapshot.agents.map(\.name))), !form.title.isEmpty {
                Text(verbatim: message).foregroundStyle(BrahmaTheme.danger).font(BrahmaTheme.monoSmall)
                    .padding(.horizontal, BrahmaTheme.spaceL)
            }
            Hairline()
            HStack(spacing: BrahmaTheme.spaceS) {
                Spacer()
                Button("Cancel") { model.presentedSheet = nil }
                    .buttonStyle(.brahma)
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    submitting = true
                    Task {
                        if await model.createItem(form) != nil { model.presentedSheet = nil }
                        submitting = false
                    }
                }
                .buttonStyle(.brahmaPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(form.validate(knownHandles: Set(model.snapshot.agents.map(\.name))) != nil || submitting)
            }
            .padding(BrahmaTheme.spaceM)
            .background(BrahmaTheme.bg2)
        }
        .frame(width: 520, height: 640)
        .background(BrahmaTheme.bg1)
    }
}
