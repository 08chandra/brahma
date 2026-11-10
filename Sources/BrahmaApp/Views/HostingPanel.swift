import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Company › Settings › HOSTING: provider, project, account ID and the optional production URL. Validation is the core's
/// (`HostingForm.validate` → `HostingSettings.validate`, PR-39); the token itself is a secret (SECRETS panel), never typed here.
struct HostingPanel: View {
    let model: AppModel
    @State private var form: HostingForm
    @State private var error: String?
    @State private var saved = false
    @State private var busy = false

    init(model: AppModel) {
        self.model = model
        _form = State(initialValue: HostingForm(model.snapshot.releases.hosting, companySlug: model.selectedCompany?.company.slug ?? ""))
    }

    var body: some View {
        let readiness = model.snapshot.releases.readiness
        Panel(title: "Hosting", accessory: {
            if readiness.tokenPresent { StatusChip(label: "TOKEN PRESENT", color: BrahmaTheme.success) }
            else { StatusChip(label: "TOKEN MISSING", color: BrahmaTheme.danger) }
        }, content: {
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
                    CapsLabel("Provider")
                    Picker("Provider", selection: $form.provider) {
                        ForEach(HostingProviderID.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    if let note = form.providerNote {
                        Text(verbatim: note).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.warning)
                    }
                }
                field("Project", text: $form.project, prompt: "initech-demo", help: "2–58 lowercase letters, digits and dashes")
                field("Account ID", text: $form.accountId, prompt: form.provider == .vercel ? "Vercel team or account ID" : "Cloudflare account ID",
                      help: form.provider == .vercel ? "Optional for Vercel" : "Required for Cloudflare Pages")
                field("Production URL (optional)", text: $form.productionURL, prompt: "https://…",
                      help: "The site's https:// URL; the LIVE preview tab and the smoke check use it")
                Text(verbatim: "The provider token is a secret: set " + (form.provider == .vercel ? "VERCEL_TOKEN" : "CLOUDFLARE_API_TOKEN")
                     + " in SECRETS above. It stays in your Keychain and is passed to the provider CLI through the environment, never argv.")
                    .font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2).fixedSize(horizontal: false, vertical: true)
                if let error {
                    Text(verbatim: error).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.danger)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: BrahmaTheme.spaceS) {
                    Button("Save") { save() }.buttonStyle(.brahmaPrimary).disabled(busy)
                    if saved { StatusChip(label: "Saved", color: BrahmaTheme.success) }
                    Spacer()
                }
            }
        })
        .onChange(of: model.snapshot.releases.hosting) { _, hosting in
            // The engine's record is authoritative once saved (or when another window changes it).
            form = HostingForm(hosting, companySlug: model.selectedCompany?.company.slug ?? "")
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
            CapsLabel(label)
            TextField(label, text: text, prompt: Text(verbatim: prompt))
                .font(BrahmaTheme.mono)
                .brahmaField()
                .frame(maxWidth: 420)
                .help(help)
        }
    }

    private func save() {
        saved = false
        if let message = form.validate() {
            error = message
            return
        }
        error = nil
        busy = true
        Task {
            let before = model.errorMessage
            await model.saveHosting(form)
            if model.errorMessage != before, let message = model.errorMessage { error = message } else { saved = true }
            busy = false
        }
    }
}
