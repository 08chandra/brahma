import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Agent text shown in a sheet: Store and map errors can carry agent text (a handle, a note), so it is cleaned.
func mapErrorText(_ error: Error) -> String {
    MapText.clean((error as? LocalizedError)?.errorDescription ?? String(describing: error), max: 200)
}

/// The owner's add-an-open-seat sheet: role, manager, team and note. `VacancyForm.validate` says what is wrong before
/// anything is written; the Store checks again, and what it or the controller throws is shown here.
struct VacancySheet: View {
    let model: AppModel
    @State private var form: VacancyForm
    @State private var submitError: String?
    @State private var submitting = false
    @FocusState private var focus: Field?

    private enum Field { case team, note }

    /// `managerHandle` is the raw handle from the context menu (a lookup key); nil is the Board.
    init(model: AppModel, managerHandle: String?) {
        self.model = model
        _form = State(initialValue: VacancyForm(managerHandle: managerHandle))
    }

    private var company: Company? { model.selectedCompany?.company }
    private var pack: IndustryPack? { company.flatMap { model.store.catalog.pack($0.packId) } }

    /// Living agents, by handle; the Board is the nil choice.
    private var managers: [Agent] {
        model.snapshot.agents.filter { $0.state != .killed }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    private var validation: String? {
        if let message = form.validate(pack: pack, packId: company?.packId ?? "") { return message }
        if let handle = form.managerHandle, !managers.contains(where: { $0.name == handle }) {
            return "Pick a manager who is with the company"
        }
        return nil
    }

    /// An empty role is not an error yet: the button stays off and nothing is shown until a role is picked.
    private var shownError: String? {
        if let submitError { return submitError }
        guard let validation else { return nil }
        return form.role.isEmpty && pack != nil ? nil : MapText.clean(validation, max: 160)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Add vacancy")
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                field("Role") {
                    Picker("Role", selection: $form.role) {
                        Text(verbatim: "Pick a role").tag("")
                        ForEach(pack?.roles ?? [], id: \.id) { role in
                            Text(verbatim: role.title).tag(role.id)
                        }
                    }
                    .labelsHidden()
                }
                field("Manager") {
                    Picker("Manager", selection: $form.managerHandle) {
                        Text(verbatim: "Board").tag(String?.none)
                        // A manager handle from the menu that is no longer seated stays selectable, so the error names it.
                        ForEach(managers, id: \.id) { agent in
                            Text(verbatim: "@" + MapText.clean(agent.name, max: 40)).tag(String?.some(agent.name))
                        }
                    }
                    .labelsHidden()
                }
                field("Team") {
                    TextField("Team", text: $form.team, prompt: Text(verbatim: "optional, e.g. core"))
                        .focused($focus, equals: .team)
                        .brahmaField(focused: focus == .team)
                }
                VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
                    HStack {
                        CapsLabel("Note")
                        Spacer()
                        Text(verbatim: "\(form.note.count)/\(Store.vacancyNoteLimit)")
                            .font(BrahmaTheme.monoSmall)
                            .foregroundStyle(form.note.count > Store.vacancyNoteLimit ? BrahmaTheme.danger : BrahmaTheme.text2)
                    }
                    TextField("Note", text: $form.note, prompt: Text(verbatim: "What this seat is for (optional)"), axis: .vertical)
                        .lineLimit(3...5)
                        .focused($focus, equals: .note)
                        .brahmaField(focused: focus == .note)
                }
                if let message = shownError {
                    Text(verbatim: message).foregroundStyle(BrahmaTheme.danger).font(BrahmaTheme.monoSmall)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(BrahmaTheme.spaceL)
            Hairline()
            HStack(spacing: BrahmaTheme.spaceS) {
                Spacer()
                Button("Cancel") { model.presentedSheet = nil }
                    .buttonStyle(.brahma)
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .buttonStyle(.brahmaPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validation != nil || submitting)
            }
            .padding(BrahmaTheme.spaceM)
            .background(BrahmaTheme.bg2)
        }
        .frame(width: 440)
        .background(BrahmaTheme.bg1)
        .onChange(of: form) { submitError = nil }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
            CapsLabel(label)
            content()
        }
    }

    private func add() {
        guard validation == nil, !submitting else { return }
        submitting = true
        let form = self.form
        Task {
            defer { submitting = false }
            guard let controller = model.ensureMapController() else {
                submitError = "The map is not available for this company"
                return
            }
            do {
                let team = form.team.trimmingCharacters(in: .whitespacesAndNewlines)
                try await controller.addVacancy(role: form.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                                                managerHandle: form.managerHandle, team: team.isEmpty ? nil : team,
                                                note: form.note)
                model.presentedSheet = nil
            } catch {
                submitError = mapErrorText(error)
            }
        }
    }
}
