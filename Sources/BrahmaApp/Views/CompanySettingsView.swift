import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Company › SETTINGS: PERMISSIONS (the profile chooser with the Full confirmation and role overrides), NETWORK (Bash egress
/// and WebFetch domains, local binding, toolchain read paths), SECRETS (names and flags; values go to the vault through the
/// secret sheet) and NOTIFICATIONS (banners, quiet hours, digest time, phone alerts with `Send test`).
struct CompanySettingsView: View {
    let model: AppModel

    private var settings: SettingsModel { model.settings }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
                PermissionsPanel(settings: settings)
                NetworkPanel(settings: settings)
                SecretsPanel(settings: settings)
                NotificationsPanel(settings: settings)
            }
            .padding(BrahmaTheme.spaceS)
        }
        .background(BrahmaTheme.bg0)
        .task(id: model.selectedCompanyId) { await settings.reload() }
        // The pending value is handed to the actions: the binding's reset on dismissal never changes what is confirmed.
        .alert(Text(verbatim: "Switch to Full?"), isPresented: Binding(get: { settings.pendingFull != nil }, set: { if !$0 { settings.pendingFull = nil } }),
               presenting: settings.pendingFull) { pending in
            Button("Switch to Full", role: .destructive) { Task { await settings.confirmFull(pending) } }
            Button("Cancel", role: .cancel) { settings.pendingFull = nil }
        } message: { pending in
            Text(verbatim: settings.fullConfirmation(pending))
        }
    }
}

/// A `monoSmall` `danger` line for the model's last refusal.
private struct ErrorLine: View {
    let error: String?

    var body: some View {
        if let error {
            Text(verbatim: error).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.danger)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Permissions

private struct PermissionsPanel: View {
    let settings: SettingsModel
    @State private var overrideRole = ""
    @State private var overrideProfile: PermissionProfile = .sandboxed

    var body: some View {
        Panel(title: "Permissions", accessory: {
            if settings.profile == .full || settings.roleProfiles.values.contains(.full) { DangerChip(label: "Full access") }
        }, content: {
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                CapsLabel("Profile for every agent turn")
                VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
                    ForEach(SettingsModel.profileOrder, id: \.self) { profile in
                        ProfileOption(profile: profile, selected: settings.profile == profile) {
                            Task { await settings.setProfile(profile) }
                        }
                    }
                }
                Hairline()
                CapsLabel("Role overrides")
                if settings.roleProfiles.isEmpty {
                    Text(verbatim: "NONE: every role runs the company's profile").font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                }
                ForEach(settings.roleProfiles.sorted(by: { $0.key < $1.key }), id: \.key) { role, profile in
                    HStack(spacing: BrahmaTheme.spaceS) {
                        Text(verbatim: role).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text0).frame(width: 140, alignment: .leading)
                        StatusChip(label: SettingsModel.profileTitle(profile), color: profile == .full ? BrahmaTheme.danger : BrahmaTheme.ready)
                        Spacer()
                        Button("Remove") { Task { await settings.clearRoleProfile(role) } }.buttonStyle(.brahma)
                    }
                }
                HStack(spacing: BrahmaTheme.spaceS) {
                    Picker("Role", selection: $overrideRole) {
                        Text(verbatim: "Role…").tag("")
                        ForEach(settings.roles, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                    .labelsHidden().frame(width: 160)
                    Segmented(options: SettingsModel.profileOrder.map { ($0, SettingsModel.profileTitle($0)) },
                              selection: overrideProfile, label: "Override profile") { overrideProfile = $0 }
                    Button("Set for role") {
                        let (role, profile) = (overrideRole, overrideProfile)
                        Task { if await settings.setProfile(profile, role: role) { overrideRole = "" } }
                    }
                    .buttonStyle(.brahma).disabled(overrideRole.isEmpty)
                }
                ErrorLine(error: settings.error)
            }
        })
    }
}

/// One radio-style row of the profile chooser: title, detail, and the privacy caveat under Workspace and Full.
private struct ProfileOption: View {
    let profile: PermissionProfile
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: BrahmaTheme.spaceS) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? BrahmaTheme.accent : BrahmaTheme.text2)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: BrahmaTheme.spaceS) {
                        Text(verbatim: SettingsModel.profileTitle(profile)).font(BrahmaTheme.bodyStrong)
                            .foregroundStyle(profile == .full ? BrahmaTheme.danger : BrahmaTheme.text0)
                        if profile == .sandboxed { StatusChip(label: "Default", color: BrahmaTheme.text2) }
                    }
                    Text(verbatim: SettingsModel.profileDetail(profile)).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text1)
                        .fixedSize(horizontal: false, vertical: true)
                    if let caveat = SettingsModel.caveat(for: profile) {
                        Text(verbatim: caveat).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(BrahmaTheme.spaceS)
            .background(selected ? BrahmaTheme.bg4 : BrahmaTheme.bg2)
            .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(selected ? BrahmaTheme.accent : BrahmaTheme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Network

private struct NetworkPanel: View {
    let settings: SettingsModel
    @State private var domain = ""
    @State private var webDomain = ""
    @State private var toolPath = ""

    var body: some View {
        Panel(title: "Network") {
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                list(title: "Bash egress domains", owner: settings.domains, defaults: settings.defaultDomains, web: false, text: $domain)
                Hairline()
                list(title: "WebFetch domains", owner: settings.webDomains, defaults: settings.defaultWebDomains, web: true, text: $webDomain)
                Hairline()
                Toggle(isOn: Binding(get: { settings.localBinding }, set: { on in Task { await settings.setLocalBinding(on) } })) {
                    Text(verbatim: "Agents may listen on loopback (dev servers, test fixtures)").font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text0)
                }
                .toggleStyle(.switch).tint(BrahmaTheme.accent).controlSize(.small)
                Hairline()
                CapsLabel("Toolchain read paths")
                if settings.toolchainPaths.isEmpty {
                    Text(verbatim: "NONE").font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                }
                ForEach(settings.toolchainPaths, id: \.self) { path in
                    HStack(spacing: BrahmaTheme.spaceS) {
                        Text(verbatim: path).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text0).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { Task { await settings.removeToolchainPath(path) } }.buttonStyle(.brahma)
                    }
                }
                HStack(spacing: BrahmaTheme.spaceS) {
                    TextField("Path", text: $toolPath, prompt: Text(verbatim: "/opt/homebrew or ~/.rustup")).brahmaField()
                    Button("Add path") {
                        let p = toolPath
                        Task { if await settings.addToolchainPath(p) { toolPath = "" } }
                    }
                    .buttonStyle(.brahma).disabled(toolPath.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(verbatim: "Read-only on every turn when it exists. Paths overlapping your home's protected places, the data home or another workspace are refused.")
                    .font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2).fixedSize(horizontal: false, vertical: true)
                ErrorLine(error: settings.error)
            }
        }
    }

    private func list(title: String, owner: [String], defaults: [String], web: Bool, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            CapsLabel(title)
            FlowChips(items: defaults.map { ($0, false) } + owner.map { ($0, true) }) { domain in
                Task { await settings.removeDomain(domain, web: web) }
            }
            HStack(spacing: BrahmaTheme.spaceS) {
                TextField("Domain", text: text, prompt: Text(verbatim: web ? "docs.stripe.com or *.example.com" : "api.stripe.com")).brahmaField()
                Button("Add") {
                    let d = text.wrappedValue
                    Task { if await settings.addDomain(d, web: web) { text.wrappedValue = "" } }
                }
                .buttonStyle(.brahma).disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// Domain chips: defaults in `text2`, owner-added ones removable.
private struct FlowChips: View {
    let items: [(String, Bool)]
    let remove: (String) -> Void

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 240), spacing: BrahmaTheme.spaceXS, alignment: .leading)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: BrahmaTheme.spaceXS) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    Text(verbatim: item.0).font(BrahmaTheme.monoSmall).foregroundStyle(item.1 ? BrahmaTheme.text0 : BrahmaTheme.text2)
                        .lineLimit(1).truncationMode(.middle)
                    if item.1 {
                        Button { remove(item.0) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(BrahmaTheme.text1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: "Remove \(item.0)"))
                    } else {
                        Text(verbatim: "default").font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2)
                    }
                }
                .padding(.horizontal, 6)
                .frame(height: BrahmaTheme.chipHeight)
                .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(item.1 ? BrahmaTheme.bg4 : BrahmaTheme.bg3))
                .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(item.1 ? BrahmaTheme.lineStrong : BrahmaTheme.line, lineWidth: 1))
            }
        }
    }
}

// MARK: - Secrets

private struct SecretsPanel: View {
    let settings: SettingsModel
    @State private var showSheet = false
    @State private var confirmRemove: String?

    var body: some View {
        Panel(title: "Secrets", padded: false, accessory: {
            Button { showSheet = true } label: { Label("Add secret", systemImage: "plus") }.buttonStyle(.brahmaPrimary)
        }, content: {
            VStack(spacing: 0) {
                HStack(spacing: BrahmaTheme.spaceS) {
                    ColumnHeader("Name").frame(width: 220, alignment: .leading)
                    ColumnHeader("Kind").frame(width: 110, alignment: .leading)
                    ColumnHeader("Updated").frame(width: 130, alignment: .leading)
                    ColumnHeader("Last used").frame(maxWidth: .infinity, alignment: .leading)
                    Spacer().frame(width: 64)
                }
                .padding(.horizontal, BrahmaTheme.spaceS)
                .frame(height: BrahmaTheme.denseRowHeight)
                .background(BrahmaTheme.bg3)
                Hairline()
                if settings.secrets.isEmpty {
                    MonoEmptyState("No secrets", detail: "Values live in the vault; agents only ever see test keys, as environment variables.")
                        .frame(height: 80)
                }
                ForEach(Array(settings.secrets.enumerated()), id: \.element.id) { index, secret in
                    HStack(spacing: BrahmaTheme.spaceS) {
                        Text(verbatim: secret.name).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text0).frame(width: 220, alignment: .leading)
                        StatusChip(label: secret.isTest ? "Test key" : "Engine-held", color: secret.isTest ? BrahmaTheme.warning : BrahmaTheme.text2)
                            .frame(width: 110, alignment: .leading)
                        Text(verbatim: stamp(secret.updatedAt)).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1).frame(width: 130, alignment: .leading)
                        Text(verbatim: secret.lastUsedAt.map(stamp) ?? "never").font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Remove") { confirmRemove = secret.name }.buttonStyle(.brahma).frame(width: 64, alignment: .trailing)
                    }
                    .tableRow(index: index)
                }
                VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
                    Text(verbatim: SecretsForm.testKeyCaption).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                    ErrorLine(error: settings.error)
                }
                .padding(BrahmaTheme.panelPadding)
            }
        })
        .sheet(isPresented: $showSheet) {
            SecretSheet { form in await settings.addSecret(form) ? nil : (settings.error ?? "Not stored.") }
                .background(BrahmaTheme.bg1)
                .preferredColorScheme(.dark)
        }
        .alert(Text(verbatim: "Remove this secret?"), isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
               presenting: confirmRemove) { name in
            Button("Remove", role: .destructive) { Task { await settings.removeSecret(name: name) } }
            Button("Cancel", role: .cancel) {}
        } message: { name in
            Text(verbatim: "Remove \(name)? The value leaves the vault. Agents that were given it as a test key lose it from their next turn.")
        }
    }

    private func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = settings.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}

// MARK: - Notifications

private struct NotificationsPanel: View {
    let settings: SettingsModel
    @State private var draft = OwnerPrefs.defaults
    @State private var loadedFrom: OwnerPrefs?
    @State private var topic = ""
    @State private var server = ""
    @State private var token = ""
    @State private var appToken = ""
    @State private var userKey = ""
    @State private var provider: PushProvider?

    var body: some View {
        Panel(title: "Notifications", accessory: {
            if settings.prefs.pushProvider != nil { StatusChip(label: "Phone alerts on", color: BrahmaTheme.running) }
        }, content: {
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                Toggle(isOn: $draft.notificationsEnabled) {
                    Text(verbatim: "Desktop banners for asks and notices").font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text0)
                }
                .toggleStyle(.switch).tint(BrahmaTheme.accent).controlSize(.small)
                HStack(spacing: BrahmaTheme.spaceM) {
                    Toggle(isOn: $draft.quietEnabled) {
                        Text(verbatim: "Quiet hours").font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text0)
                    }
                    .toggleStyle(.switch).tint(BrahmaTheme.accent).controlSize(.small)
                    timeField("From", $draft.quietStart)
                    timeField("To", $draft.quietEnd)
                    Spacer()
                    timeField("Digest at", $draft.digestTime)
                }
                Text(verbatim: "Times are HH:MM in your time zone. Urgent asks break through quiet hours; the rest wait and collapse into one banner.")
                    .font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Save") { let p = draft; Task { if await settings.savePrefs(p) { loadedFrom = settings.prefs } } }
                        .buttonStyle(.brahmaPrimary).disabled(draft == settings.prefs)
                    if draft != settings.prefs { Button("Revert") { draft = settings.prefs }.buttonStyle(.brahma) }
                    if let message = settings.message { Text(verbatim: message).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.success) }
                }
                Hairline()
                CapsLabel("Phone alerts")
                HStack(spacing: BrahmaTheme.spaceM) {
                    Segmented(options: [(Optional<PushProvider>.none, "Off"), (.ntfy, "ntfy"), (.pushover, "Pushover")],
                              selection: provider, label: "Phone alert provider") { provider = $0 }
                    CapsLabel("Detail")
                    Segmented(options: PushDetail.allCases.map { ($0, $0.rawValue) }, selection: settings.prefs.pushDetail,
                              label: "Push detail") { detail in Task { await settings.setPushDetail(detail) } }
                }
                switch provider {
                case .ntfy:
                    HStack(spacing: BrahmaTheme.spaceS) {
                        TextField("Topic", text: $topic, prompt: Text(verbatim: "topic")).brahmaField().frame(width: 180)
                        TextField("Server", text: $server, prompt: Text(verbatim: OwnerPrefs.defaultPushServer)).brahmaField()
                        SecureField("Token", text: $token, prompt: Text(verbatim: "token (optional)")).brahmaField().frame(width: 160)
                        Button("Save") { let (t, s, k) = (topic, server, token); Task { if await settings.setPushNtfy(topic: t, server: s, token: k) { token = "" } } }
                            .buttonStyle(.brahmaPrimary).disabled(topic.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                case .pushover:
                    HStack(spacing: BrahmaTheme.spaceS) {
                        SecureField("App token", text: $appToken, prompt: Text(verbatim: "app token")).brahmaField()
                        SecureField("User key", text: $userKey, prompt: Text(verbatim: "user key")).brahmaField()
                        Button("Save") { let (a, u) = (appToken, userKey); Task { if await settings.setPushover(appToken: a, userKey: u) { appToken = ""; userKey = "" } } }
                            .buttonStyle(.brahmaPrimary).disabled(appToken.isEmpty || userKey.isEmpty)
                    }
                case nil:
                    if settings.prefs.pushProvider != nil {
                        Button("Turn phone alerts off") { Task { await settings.turnPushOff() } }.buttonStyle(.brahma)
                    }
                }
                HStack(spacing: BrahmaTheme.spaceS) {
                    Button("Send test") { Task { await settings.sendTestPush() } }.buttonStyle(.brahma).disabled(settings.prefs.pushProvider == nil)
                    Text(verbatim: "counts: engine text only · titles: each ask's own title, flattened and redacted. Tokens go to the vault.")
                        .font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2).lineLimit(2)
                }
                ErrorLine(error: settings.error)
            }
        })
        .onChange(of: settings.prefs, initial: true) { _, prefs in
            if loadedFrom != prefs { draft = prefs; loadedFrom = prefs }
            provider = prefs.pushProvider
            topic = prefs.pushTopic ?? ""
            server = prefs.pushServer
        }
    }

    private func timeField(_ label: String, _ text: Binding<String>) -> some View {
        HStack(spacing: BrahmaTheme.spaceXS) {
            CapsLabel(label)
            TextField(label, text: text, prompt: Text(verbatim: "HH:MM")).brahmaField().font(BrahmaTheme.mono).frame(width: 64)
        }
    }
}
