import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Inbox › GRANTS: the ledger (REF, KIND, VALUE, SCOPE, EXPIRES, APPROVED BY, USES, LAST USED) with `SHOW INACTIVE` and
/// `Revoke`, and the presets panel.
struct GrantsView: View {
    let model: AppModel
    @State private var confirmRevoke: GrantRow?

    private var access: AccessModel { model.access }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
                ledger
                presets
            }
            .padding(BrahmaTheme.spaceS)
        }
        .background(BrahmaTheme.bg0)
        .task(id: model.selectedCompanyId) { await access.reload() }
        .alert(confirmRevoke.map(access.revokeConfirmation) ?? "", isPresented: Binding(
            get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } })) {
            Button("Revoke", role: .destructive) {
                if let row = confirmRevoke { Task { await access.revoke(number: row.number) } }
                confirmRevoke = nil
            }
            Button("Cancel", role: .cancel) { confirmRevoke = nil }
        }
    }

    private static let columns: [(String, CGFloat?)] = [
        ("Ref", 48), ("Kind", 110), ("Value", nil), ("Scope", 150), ("Expires", 130), ("Approved by", 150), ("Uses", 44), ("Last used", 120),
    ]

    private var ledger: some View {
        Panel(title: "Grants", padded: false, accessory: {
            HStack(spacing: BrahmaTheme.spaceM) {
                if access.cards.count > 0 {
                    Button { model.select(.inbox) } label: { MonoChip(text: "\(access.cards.count) waiting", color: .white, fill: BrahmaTheme.accent) }
                        .buttonStyle(.plain)
                        .help("Access requests waiting in the Inbox")
                }
                Toggle(isOn: Binding(get: { access.showInactive }, set: { on in
                    access.showInactive = on
                    Task { await access.reload() }
                })) { CapsLabel("Show inactive", color: BrahmaTheme.text1) }
                .toggleStyle(.switch)
                .tint(BrahmaTheme.accent)
                .controlSize(.mini)
            }
        }, content: {
            VStack(spacing: 0) {
                HStack(spacing: BrahmaTheme.spaceS) {
                    ForEach(Array(Self.columns.enumerated()), id: \.offset) { _, column in
                        ColumnHeader(column.0).frame(width: column.1, alignment: .leading)
                            .frame(maxWidth: column.1 == nil ? .infinity : nil, alignment: .leading)
                    }
                    Spacer().frame(width: 64)
                }
                .padding(.horizontal, BrahmaTheme.spaceS)
                .frame(height: BrahmaTheme.denseRowHeight)
                .background(BrahmaTheme.bg3)
                Hairline()
                if access.grants.isEmpty {
                    MonoEmptyState(access.showInactive ? "No grants" : "No active grants",
                                   detail: "Approve an access request in the Inbox to grant a domain or a read path.")
                        .frame(height: 90)
                } else {
                    ForEach(Array(access.grants.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: BrahmaTheme.spaceS) {
                            cell(row.ref, 48, mono: true, color: row.isActive ? BrahmaTheme.text0 : BrahmaTheme.text2)
                            cell(row.kind, 110, mono: true, color: BrahmaTheme.text1)
                            cell(row.value, nil, mono: true, color: row.isActive ? BrahmaTheme.text0 : BrahmaTheme.text2)
                            cell(row.scopeText, 150, mono: false, color: BrahmaTheme.text0)
                            cell(row.expiresText, 130, mono: true, color: row.isActive ? BrahmaTheme.text1 : BrahmaTheme.warning)
                            cell(row.approvedBy, 150, mono: true, color: BrahmaTheme.text1)
                            cell(row.uses, 44, mono: true, color: BrahmaTheme.text1)
                            cell(row.lastUsed, 120, mono: true, color: BrahmaTheme.text2)
                            Group {
                                if row.isActive {
                                    Button("Revoke") { confirmRevoke = row }.buttonStyle(.brahma)
                                } else {
                                    StatusChip(label: "Inactive", color: BrahmaTheme.sleeping)
                                }
                            }
                            .frame(width: 64, alignment: .trailing)
                        }
                        .tableRow(index: index, height: BrahmaTheme.rowHeight)
                        .accessibilityElement(children: .combine)
                    }
                }
                if let error = access.error {
                    Hairline()
                    Text(verbatim: error).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.danger)
                        .textSelection(.enabled).padding(BrahmaTheme.panelPadding)
                }
            }
        })
    }

    private func cell(_ text: String, _ width: CGFloat?, mono: Bool, color: Color) -> some View {
        Text(verbatim: text)
            .font(mono ? BrahmaTheme.monoSmall : BrahmaTheme.body)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private var presets: some View {
        Panel(title: "Presets") {
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                ForEach(AccessModel.presetRows) { row in
                    HStack(alignment: .top, spacing: BrahmaTheme.spaceM) {
                        Toggle(isOn: Binding(get: { access.presets.contains(row.preset) }, set: { on in
                            Task { await access.setPreset(row.preset, enabled: on) }
                        })) { EmptyView() }
                        .toggleStyle(.switch)
                        .tint(BrahmaTheme.accent)
                        .controlSize(.small)
                        .labelsHidden()
                        .accessibilityLabel(Text(verbatim: row.title))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: BrahmaTheme.spaceS) {
                                Text(verbatim: row.title).font(BrahmaTheme.bodyStrong).foregroundStyle(BrahmaTheme.text0)
                                Text(verbatim: row.preset.rawValue).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                            }
                            Text(verbatim: row.detail).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text1)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Hairline()
                Text(verbatim: AccessModel.presetsCaption)
                    .font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
            }
        }
    }
}
