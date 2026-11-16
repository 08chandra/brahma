import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// The drops waiting on a composer, above its field: the scope chip (a menu: the conversation's default, the company, a
/// team, an item), the ADVISORY chip where scopes are advisory, then per drop its kind chip, name, size, trust chip and ×.
/// Names, link hosts and skipped paths are text an outside source chose: always verbatim.
struct PendingDropChips: View {
    let model: ResourceDropModel

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
            HStack(spacing: BrahmaTheme.spaceS) {
                ScopeMenu(model: model)
                if model.showsAdvisory {
                    WarningChip(label: "Advisory").help(Text(verbatim: ResourceDropModel.advisoryText))
                }
                Spacer(minLength: 0)
            }
            ForEach(model.pending) { drop in PendingDropRow(model: model, drop: drop) }
        }
    }
}

private struct PendingDropRow: View {
    let model: ResourceDropModel
    let drop: PendingDrop

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: BrahmaTheme.spaceS) {
                StatusChip(label: drop.kindLabel, color: BrahmaTheme.text1)
                Text(verbatim: drop.name)
                    .font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text0)
                    .lineLimit(1).truncationMode(.middle)
                if !drop.sizeText.isEmpty {
                    Text(verbatim: drop.sizeText).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
                }
                if let skipped = drop.skippedNote {
                    MonoChip(text: skipped, color: BrahmaTheme.text1).help(Text(verbatim: drop.plan.skipped.joined(separator: "\n")))
                }
                switch drop.secretChoice {
                case .uploadRedacted: WarningChip(label: "Redacted")
                case .uploadAnyway: DangerChip(label: "Flagged")
                default: EmptyView()
                }
                Spacer(minLength: BrahmaTheme.spaceXS)
                Button { model.remove(drop.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(BrahmaTheme.text1)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove")
                .accessibilityLabel(Text(verbatim: "Remove \(drop.name)"))
            }
            TrustChipView(chip: drop.chip) { model.setTrust(drop.id, drop.chip.actionChoice) }
        }
        .padding(.vertical, 2)
    }
}

/// `EXTERNAL · agents read it as untrusted data; … · [I vouch for this file]` or `FROM YOU · [Mark untrusted]`.
struct TrustChipView: View {
    let chip: TrustChip
    var action: (() -> Void)?

    var body: some View {
        let parts = chip.text.components(separatedBy: " · ")
        HStack(alignment: .firstTextBaseline, spacing: BrahmaTheme.spaceS) {
            StatusChip(label: parts[0], color: chip.isExternal ? BrahmaTheme.warning : BrahmaTheme.success)
                .help(Text(verbatim: Self.tooltip(chip)))
            if parts.count > 1 {
                Text(verbatim: parts.dropFirst().joined(separator: " · "))
                    .font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action { Button(chip.action, action: action).buttonStyle(.brahma) }
        }
        .accessibilityElement(children: .combine)
    }

    static func tooltip(_ chip: TrustChip) -> String {
        if case .external(let reason) = chip { return chip.text + " (" + reason + ")" }
        return chip.text
    }
}

/// The scope chip: shows the resolved scope; picking another resolves it again (the engine checks it at Send).
private struct ScopeMenu: View {
    let model: ResourceDropModel

    var body: some View {
        let teams = model.teamChoices, itemKeys = model.itemChoices
        Menu {
            Button("This conversation's default") { set(.contextDefault, future: false) }
            Button("Company") { set(.company, future: false) }
            if !teams.isEmpty {
                Section("Team") { ForEach(teams, id: \.self) { t in Button { set(.team(t), future: false) } label: { Text(verbatim: t) } } }
            }
            if !itemKeys.isEmpty {
                Section("Item") { ForEach(itemKeys, id: \.self) { k in Button { set(.item(k), future: false) } label: { Text(verbatim: k) } } }
            }
            if isItemScope {
                Toggle("And future holders", isOn: Binding(get: { model.futureHolders },
                                                           set: { set(model.scope, future: $0) }))
            }
        } label: {
            MonoChip(text: (model.scopeLabel.isEmpty ? "SCOPE · …" : model.scopeLabel).uppercased(), color: BrahmaTheme.text0)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Who can read these files")
    }

    private var isItemScope: Bool {
        if case .item = model.scope { return true }
        if case .item = model.context, model.scope == .contextDefault { return true }
        return false
    }

    private func set(_ choice: ScopeChoice, future: Bool) {
        Task { await model.setScope(choice, futureHolders: future) }
    }
}
