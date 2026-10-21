import SwiftUI
import BrahmaAppModel

struct HireSheet: View {
    let model: AppModel
    @State private var form = HireForm()
    @State private var submitError: String?
    @State private var submitting = false
    @FocusState private var focus: Field?

    private enum Field { case handle, role }

    private var validation: String? {
        form.validate(existingHandles: Set(model.snapshot.agents.map { $0.name.lowercased() }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Hire agent")
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
                    CapsLabel("Handle")
                    HStack(spacing: 4) {
                        Text(verbatim: "@").font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text2)
                        TextField("Handle", text: $form.handle, prompt: Text(verbatim: "qa1"))
                            .font(BrahmaTheme.mono)
                            .focused($focus, equals: .handle)
                            .textFieldStyle(.plain)
                    }
                    .brahmaFieldFrame(focused: focus == .handle)
                }
                VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
                    HStack {
                        CapsLabel("Role")
                        Spacer()
                        Menu("Suggestions") {
                            ForEach(HireForm.roleSuggestions, id: \.self) { r in
                                Button { form.role = r } label: { Text(verbatim: r) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .font(BrahmaTheme.label)
                    }
                    TextField("Role", text: $form.role, prompt: Text(verbatim: "engineer"))
                        .focused($focus, equals: .role)
                        .brahmaField(focused: focus == .role)
                }
                VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
                    CapsLabel("Model")
                    ModelControl(choice: $form.model)
                }
                if let message = submitError ?? validation {
                    Text(verbatim: message).foregroundStyle(BrahmaTheme.danger).font(BrahmaTheme.monoSmall)
                }
            }
            .padding(BrahmaTheme.spaceL)
            Hairline()
            HStack(spacing: BrahmaTheme.spaceS) {
                Spacer()
                Button("Cancel") { model.presentedSheet = nil }
                    .buttonStyle(.brahma)
                    .keyboardShortcut(.cancelAction)
                Button("Hire") { hire() }
                    .buttonStyle(.brahmaPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validation != nil || submitting)
            }
            .padding(BrahmaTheme.spaceM)
            .background(BrahmaTheme.bg2)
        }
        .frame(width: 440)
        .background(BrahmaTheme.bg1)
        .onAppear { focus = .handle }
        .onChange(of: form) { submitError = nil }
    }

    private func hire() {
        submitting = true
        Task {
            do {
                _ = try await model.hire(form)
                model.presentedSheet = nil
            } catch FormError.invalid(let message) {
                submitError = message
            } catch {
                submitError = "\(error)"
            }
            submitting = false
        }
    }
}

/// Segmented OPUS | SONNET | HAIKU control in the style of the top bar's usage-mode control.
private struct ModelControl: View {
    @Binding var choice: AgentModelChoice

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(AgentModelChoice.allCases.enumerated()), id: \.offset) { index, value in
                let selected = value == choice
                if index > 0 { Hairline(axis: .vertical, color: BrahmaTheme.lineStrong) }
                Button { choice = value } label: {
                    Text(verbatim: value.title.uppercased())
                        .font(BrahmaTheme.label)
                        .tracking(BrahmaTheme.labelTracking)
                        .foregroundStyle(selected ? Color.white : BrahmaTheme.text1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background(selected ? BrahmaTheme.accent : BrahmaTheme.bg3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: value.title))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: BrahmaTheme.radius))
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.lineStrong, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Model"))
    }
}

private extension View {
    /// Field chrome around a composite (prefix + text field) row.
    func brahmaFieldFrame(focused: Bool) -> some View {
        self.padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.bg2))
            .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius)
                .strokeBorder(focused ? BrahmaTheme.accent : BrahmaTheme.lineStrong, lineWidth: 1))
    }
}
