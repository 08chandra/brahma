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
        .frame(width: 440)
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
