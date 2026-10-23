import SwiftUI
import BrahmaAppModel

struct NewCompanySheet: View {
    let model: AppModel
    @State private var form = CompanyForm()
    @State private var submitError: String?
    @State private var submitting = false
    @FocusState private var focus: Field?

    private enum Field { case name, goal }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "New company")
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
                    CapsLabel("Name")
                    TextField("Name", text: $form.name, prompt: Text(verbatim: "Company name"))
                        .focused($focus, equals: .name)
                        .brahmaField(focused: focus == .name)
                }
                VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
                    CapsLabel("Goal")
                    TextField("Goal", text: $form.goal, prompt: Text(verbatim: "What should this company achieve?"), axis: .vertical)
                        .lineLimit(3...6)
                        .focused($focus, equals: .goal)
                        .brahmaField(focused: focus == .goal)
                }
                HStack(alignment: .top, spacing: BrahmaTheme.spaceM) {
                    VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
                        CapsLabel("Agents")
                        HStack(spacing: BrahmaTheme.spaceS) {
                            TextField("Agents", value: $form.agentCount, format: .number)
                                .multilineTextAlignment(.trailing)
                                .font(BrahmaTheme.mono)
                                .brahmaField()
                                .frame(width: 64)
                                .accessibilityLabel(Text("Agents"))
                            // 0 means an empty company; the first step up lands on the smallest org (5).
                            Stepper("", onIncrement: { form.agentCount = form.agentCount < 5 ? 5 : min(500, form.agentCount + 1) },
                                    onDecrement: { form.agentCount = form.agentCount <= 5 ? 0 : form.agentCount - 1 })
                                .labelsHidden()
                        }
                        Text(verbatim: "0 for none, or 5 to 500").font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                    }
                    VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
                        CapsLabel("Industry pack")
                        Picker("Industry pack", selection: $form.packId) {
                            ForEach(model.store.catalog.packs, id: \.id) { Text(verbatim: $0.title).tag($0.id) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
                if let warning = form.warning {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                        Text(verbatim: warning).font(BrahmaTheme.monoSmall)
                    }
                    .foregroundStyle(BrahmaTheme.warning)
                }
                OrgPreviewView(preview: model.orgPreview(form), agentCount: form.agentCount)
                if let message = submitError ?? form.validate() {
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
                Button("Create") { create() }
                    .buttonStyle(.brahmaPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.validate() != nil || submitting)
            }
            .padding(BrahmaTheme.spaceM)
            .background(BrahmaTheme.bg2)
        }
        .frame(width: 480)
        .background(BrahmaTheme.bg1)
        .onAppear { focus = .name }
    }

    private func create() {
        submitting = true
        Task {
            do {
                _ = try await model.createCompany(form)
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
