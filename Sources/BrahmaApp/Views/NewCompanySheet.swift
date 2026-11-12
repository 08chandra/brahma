import AppKit
import SwiftUI
import BrahmaAppModel

struct NewCompanySheet: View {
    let model: AppModel
    @State private var form = CompanyForm()
    @State private var submitError: String?
    @State private var submitting = false
    @State private var start: Start = .new
    @State private var repoText = ""
    @FocusState private var focus: Field?

    private enum Field { case name, goal, repo }
    /// Plan L Task 14: a new empty workspace, or an existing repo the engine clones into it.
    private enum Start: Hashable { case new, repo }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "New company")
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
                    CapsLabel("Start")
                    Picker("Start", selection: $start) {
                        Text(verbatim: "NEW").tag(Start.new)
                        Text(verbatim: "EXISTING REPO").tag(Start.repo)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if start == .repo { repoField }
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
                if submitting, start == .repo {
                    Text(verbatim: "Cloning and checking the repo…").font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                }
            }
            .padding(BrahmaTheme.spaceL)
            Hairline()
            HStack(spacing: BrahmaTheme.spaceS) {
                Spacer()
                // Not while a company is being created (an import may still be cloning): Cancel never pretends to stop it.
                Button("Cancel") { model.presentedSheet = nil }
                    .buttonStyle(.brahma)
                    .keyboardShortcut(.cancelAction)
                    .disabled(submitting)
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
        .interactiveDismissDisabled(submitting)
        .onChange(of: start) { syncSource() }
        .onChange(of: repoText) { syncSource() }
    }

    /// EXISTING REPO: a folder or an https URL, typed or chosen.
    private var repoField: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
            CapsLabel("Repository")
            HStack(spacing: BrahmaTheme.spaceS) {
                TextField("Repository", text: $repoText, prompt: Text(verbatim: "/path/to/folder or https://host/owner/repo"))
                    .font(BrahmaTheme.mono)
                    .focused($focus, equals: .repo)
                    .brahmaField(focused: focus == .repo)
                Button("Choose Folder…") { chooseFolder() }
                    .buttonStyle(.brahma)
            }
            Text(verbatim: "Brahma clones it into the company workspace. Your original is never changed or pushed to.")
                .font(BrahmaTheme.monoSmall)
                .foregroundStyle(BrahmaTheme.text2)
        }
    }

    private func syncSource() {
        form.source = start == .new ? .greenfield : .repo(repoText)
        submitError = nil
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { repoText = url.path }
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
