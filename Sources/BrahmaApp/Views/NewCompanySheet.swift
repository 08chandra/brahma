import SwiftUI
import BrahmaAppModel

struct NewCompanySheet: View {
    let model: AppModel
    @State private var form = CompanyForm()
    @State private var submitError: String?
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Company").font(.title2.bold())
            TextField("Name", text: $form.name)
            TextField("Goal", text: $form.goal, axis: .vertical)
                .lineLimit(3...6)
            if let message = submitError ?? form.validate() {
                Text(verbatim: message).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.presentedSheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.validate() != nil || submitting)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 440)
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
