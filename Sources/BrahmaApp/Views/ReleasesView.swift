import SwiftUI
import AppKit
import BrahmaCore
import BrahmaAppModel

/// Work › RELEASES: the PATH TO LIVE header (main's health with "Run Smoke"; Task 13 adds the milestone chips), the
/// HOSTING grid and the zebra table of releases with a mono inspector. Rollback asks the owner first and then goes through
/// `AppModel.rollback` (the engine runs the recorded commands; `main` is not changed).
struct ReleasesView: View {
    let model: AppModel
    @State private var selectedId: String?
    @State private var rollbackTarget: ReleaseRow?

    var body: some View {
        let rows = model.releaseRows
        VStack(spacing: BrahmaTheme.spaceS) {
            pathToLive
            HostingSummaryPanel(model: model)
            Panel(title: "Releases", padded: false, accessory: {
                MonoChip(text: "\(model.openReleaseCount) OPEN", color: model.openReleaseCount > 0 ? BrahmaTheme.text0 : BrahmaTheme.text1,
                         fill: BrahmaTheme.bg4)
            }, content: {
                if rows.isEmpty {
                    MonoEmptyState("NO RELEASES YET",
                                   detail: "DevOps proposes a deploy; you approve it in the Inbox; the engine deploys it and checks the live URL.")
                } else {
                    HStack(spacing: 0) {
                        table(rows)
                        if let row = rows.first(where: { $0.id == selectedId }) {
                            Hairline().frame(width: 1)
                            inspector(row).frame(width: 300)
                        }
                    }
                }
            })
            .frame(maxHeight: .infinity)
        }
        .padding(BrahmaTheme.spaceS)
        .background(BrahmaTheme.bg0)
        // `version` is "release <version>", so the title reads "Roll back release <version>?".
        .alert(Text(verbatim: "Roll back \(rollbackTarget?.version ?? "release")?"),
               isPresented: Binding(get: { rollbackTarget != nil }, set: { if !$0 { rollbackTarget = nil } }), presenting: rollbackTarget) { row in
            Button("Roll Back", role: .destructive) { Task { await model.rollback(releaseRef: row.ref) } }
            Button("Cancel", role: .cancel) { rollbackTarget = nil }
        } message: { row in
            Text(verbatim: "The engine runs the rollback recorded before this deploy: \(row.rollbackDisplay). main is not changed.")
        }
    }

    // MARK: Path to live

    private var pathToLive: some View {
        let health = model.mainHealth
        return Panel(title: "Path to live") {
            HStack(spacing: BrahmaTheme.spaceS) {
                CapsLabel("Main")
                StatusChip(label: health.title, color: PreviewPane<EmptyView>.toneColor(health.tone), pulse: health.tone == .busy)
                Button("Run Smoke") { Task { await model.runMainSmoke() } }
                    .buttonStyle(.brahma)
                    .disabled(model.snapshot.releases.smokeCheck == nil || health.tone == .busy)
                    .help(model.snapshot.releases.smokeCheck == nil ? "No smoke check is set for this company" : "Run the smoke check on main now")
                Spacer(minLength: 0)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Table

    private func table(_ rows: [ReleaseRow]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: BrahmaTheme.spaceS) {
                ColumnHeader("Ref").frame(width: 44, alignment: .leading)
                ColumnHeader("Version").frame(minWidth: 110, alignment: .leading)
                ColumnHeader("Status").frame(width: 150, alignment: .leading)
                ColumnHeader("Commit").frame(width: 64, alignment: .leading)
                ColumnHeader("URL").frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                ColumnHeader("Smoke").frame(width: 64, alignment: .leading)
                ColumnHeader("By").frame(width: 90, alignment: .leading)
                ColumnHeader("When").frame(width: 112, alignment: .leading)
            }
            .padding(.horizontal, BrahmaTheme.spaceS)
            .frame(height: BrahmaTheme.denseRowHeight)
            .background(BrahmaTheme.bg3)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: BrahmaTheme.spaceS) {
                            Text(verbatim: row.ref).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text0).frame(width: 44, alignment: .leading)
                            Text(verbatim: row.version).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text0).lineLimit(1)
                                .frame(minWidth: 110, alignment: .leading)
                            HStack(spacing: 4) {
                                StatusChip(label: row.statusTitle, color: Self.toneColor(ReleaseTone(row.status)),
                                           pulse: ReleaseTone(row.status) == .running)
                                if let rb = row.rollbackTitle { StatusChip(label: rb, color: BrahmaTheme.warning) }
                            }
                            .frame(width: 150, alignment: .leading)
                            Text(verbatim: row.commit).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text1).frame(width: 64, alignment: .leading)
                            Text(verbatim: row.url).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1).lineLimit(1).truncationMode(.middle)
                                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                            Text(verbatim: row.smoke).font(BrahmaTheme.monoSmall).foregroundStyle(checkColor(row.smoke.lowercased()))
                                .frame(width: 64, alignment: .leading)
                            Text(verbatim: row.proposer).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text1).lineLimit(1)
                                .frame(width: 90, alignment: .leading)
                            Text(verbatim: row.when).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2).frame(width: 112, alignment: .leading)
                        }
                        .tableRow(index: index, selected: row.id == selectedId)
                        .onTapGesture { selectedId = row.id }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(row.id == selectedId ? .isSelected : [])
                    }
                }
            }
        }
    }

    private func inspector(_ row: ReleaseRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: row.ref)
            ScrollView {
                VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                    KeyValueGrid(rows: [
                        KeyValueRow(label: "Version", value: row.version, mono: true),
                        KeyValueRow(label: "Status", value: row.statusTitle, mono: true, valueColor: Self.toneColor(ReleaseTone(row.status))),
                        KeyValueRow(label: "Commit", value: row.commit, mono: true),
                        KeyValueRow(label: "URL", value: row.url, mono: true),
                        KeyValueRow(label: "Smoke", value: row.smoke, mono: true),
                        KeyValueRow(label: "By", value: row.proposer, mono: true),
                        KeyValueRow(label: "When", value: row.when, mono: true),
                    ] + (row.rollbackTitle.map { [KeyValueRow(label: "Rollback", value: $0, mono: true, valueColor: BrahmaTheme.warning)] } ?? []))
                    if row.url != "—", let url = URL(string: row.url), ["http", "https"].contains(url.scheme ?? "") {
                        Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.brahma)
                    }
                    Hairline()
                    CapsLabel("Rollback plan")
                    MonoBlock(text: row.rollbackDisplay.isEmpty ? "—" : row.rollbackDisplay, maxHeight: 160)
                    if row.canRollBack {
                        Button("Roll Back…") { rollbackTarget = row }.buttonStyle(.brahma)
                    }
                }
                .padding(BrahmaTheme.spaceM)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    static func toneColor(_ tone: ReleaseTone) -> Color {
        switch tone {
        case .ready: BrahmaTheme.ready
        case .running: BrahmaTheme.running
        case .success: BrahmaTheme.success
        case .danger: BrahmaTheme.danger
        case .muted: BrahmaTheme.text2
        }
    }
}

// MARK: - Hosting summary

/// The HOSTING grid on Releases: what is set and whether the token is present. "Edit…" opens Company › Settings › HOSTING.
private struct HostingSummaryPanel: View {
    let model: AppModel

    var body: some View {
        let r = model.snapshot.releases
        let h = r.hosting
        Panel(title: "Hosting", accessory: {
            HStack(spacing: BrahmaTheme.spaceXS) {
                if r.readiness.tokenPresent { StatusChip(label: "TOKEN PRESENT", color: BrahmaTheme.success) }
                else { StatusChip(label: "TOKEN MISSING", color: BrahmaTheme.danger) }
                Button("Edit…") { model.select(.companySettings) }.buttonStyle(.brahma)
            }
        }, content: {
            HStack(alignment: .top, spacing: BrahmaTheme.spaceM) {
                KeyValueGrid(rows: [
                    KeyValueRow(label: "Provider", value: h?.provider.title ?? "—"),
                    KeyValueRow(label: "Project", value: h?.project ?? "—", mono: true),
                    KeyValueRow(label: "URL", value: h?.productionURL ?? "—", mono: true),
                    KeyValueRow(label: "Domain", value: h?.customDomain ?? "—", mono: true),
                    KeyValueRow(label: "Token", value: r.readiness.tokenPresent ? "PRESENT" : "MISSING", mono: true,
                                valueColor: r.readiness.tokenPresent ? BrahmaTheme.success : BrahmaTheme.danger),
                    KeyValueRow(label: "Build", value: h?.build ?? "—", mono: true),
                    KeyValueRow(label: "Output", value: h?.outputDir ?? "—", mono: true),
                    KeyValueRow(label: "Smoke", value: Self.smokeLine(h), mono: true),
                ])
                if let text = h?.productionURL, let url = URL(string: text), url.scheme == "https" {
                    Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.brahma)
                }
            }
        })
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "GET / 200 · GET /pricing 200", or "—".
    static func smokeLine(_ h: HostingSettings?) -> String {
        guard let h, !h.smoke.isEmpty else { return "—" }
        return h.smoke.map { "\($0.method) \($0.path)" + ($0.expectStatus.map { " \($0)" } ?? "") }.joined(separator: " · ")
    }
}
