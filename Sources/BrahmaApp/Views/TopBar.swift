import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// `bg2` top bar with a bottom hairline. Row 1 (40 pt): company name · usage mode · state counts · search · run control.
/// Row 2 (30 pt): the sprint line · AUTONOMY · why nothing runs · usage meter and 7-day pace.
struct TopBar: View {
    let model: AppModel
    @State private var confirmAuto = false
    @State private var showWhy = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            primaryRow
            if let summary = model.selectedCompany { contextRow(summary) }
        }
        .frame(maxWidth: .infinity)
        .background(BrahmaTheme.bg2)
        .overlay(alignment: .bottom) { Hairline() }
        .task(id: model.search.query) {
            // Debounce: a newer keystroke cancels this task during the sleep.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await model.runSearch()
        }
        .alert("Switch to Auto?", isPresented: $confirmAuto) {
            Button("Switch") { Task { await model.setAutonomy(.auto) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: "PRD, architecture, sprint plan and release asks will no longer wait for you once the C-suite approves; you get an FYI instead. Reserved matters (money, contracts, pricing, legal, staffing, stage changes and similar) and questions always need you. Asks already waiting still need you.")
        }
    }

    private var primaryRow: some View {
        HStack(spacing: BrahmaTheme.spaceL) {
            Text(verbatim: model.selectedCompany?.company.name ?? "Brahma")
                .font(BrahmaTheme.companyTitle)
                .foregroundStyle(BrahmaTheme.text0)
                .lineLimit(1)
                .layoutPriority(1)
            if let summary = model.selectedCompany {
                Segmented(options: [(UsageMode.low, "Low"), (.balanced, "Balanced"), (.max, "Max")],
                          selection: summary.company.usageMode, label: "Usage mode") { mode in
                    Task { await model.setUsageMode(mode) }
                }
                CountChips(counts: summary.counts)
                if model.fullAccess {
                    Button { model.select(.companySettings) } label: { DangerChip(label: "Full access") }
                        .buttonStyle(.plain)
                        .help(SettingsModel.fullWarning)
                        .accessibilityLabel(Text(verbatim: "Full access: " + SettingsModel.fullWarning))
                }
                Spacer(minLength: BrahmaTheme.spaceM)
                searchField
                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 11)).foregroundStyle(BrahmaTheme.text1)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Auto-merge and budget")
                .accessibilityLabel(Text("Auto-merge and budget"))
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { CompanySettingsPopover(model: model) }
                let running = summary.company.status == .running
                Button {
                    Task { await model.setCompanyRunning(!running, companyId: summary.id) }
                } label: {
                    Label(running ? "Pause company" : "Run company", systemImage: running ? "pause.fill" : "play.fill")
                }
                .buttonStyle(BrahmaButtonStyle(primary: !running))
                .fixedSize()
            } else {
                Spacer()
            }
        }
        .padding(.leading, BrahmaTheme.trafficLightInset)
        .padding(.trailing, BrahmaTheme.spaceM)
        .frame(height: BrahmaTheme.topBarHeight)
    }

    private func contextRow(_ summary: CompanySummary) -> some View {
        HStack(spacing: BrahmaTheme.spaceL) {
            Text(verbatim: model.sprintLine ?? "No active sprint")
                .font(BrahmaTheme.monoSmall)
                .foregroundStyle(model.sprintLine == nil ? BrahmaTheme.text2 : BrahmaTheme.text1)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            HStack(spacing: BrahmaTheme.spaceS) {
                CapsLabel("Autonomy")
                Segmented(options: [(AutonomyPreset.everything, "Everything"), (.important, "Important"), (.auto, "Auto")],
                          selection: model.autonomy, label: "Autonomy") { preset in
                    if preset == .auto { confirmAuto = true } else { Task { await model.setAutonomy(preset) } }
                }
                .help(model.autonomy.title)
            }
            Spacer(minLength: BrahmaTheme.spaceM)
            if let why = model.stallLine { whyChip(why) }
            usage
            if let pace = model.paceLine {
                let ahead = model.work.pace.map { $0.state == .ahead || $0.state == .closed } ?? false
                Text(verbatim: pace.uppercased())
                    .font(BrahmaTheme.monoSmall)
                    .foregroundStyle(ahead ? BrahmaTheme.warning : BrahmaTheme.text1)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.leading, BrahmaTheme.trafficLightInset)
        .padding(.trailing, BrahmaTheme.spaceM)
        .frame(height: 30)
        .overlay(alignment: .top) { Hairline(color: BrahmaTheme.line.opacity(0.6)) }
    }

    /// `WHY: <first reason>`; the popover lists them all.
    private func whyChip(_ why: String) -> some View {
        Button { showWhy = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "questionmark.circle.fill").font(.system(size: 10))
                Text(verbatim: "WHY: " + why).font(BrahmaTheme.label).tracking(BrahmaTheme.labelTracking).lineLimit(1)
            }
            .foregroundStyle(BrahmaTheme.warning)
            .padding(.horizontal, 6)
            .frame(height: BrahmaTheme.chipHeight)
            .frame(maxWidth: 380)
            .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.warning.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.warning, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "Why nothing is running: " + why))
        .popover(isPresented: $showWhy, arrowEdge: .bottom) { WhyPopover(reasons: model.work.stall.reasons) }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(BrahmaTheme.text2)
            TextField(text: Bindable(model.search).query, prompt: Text(verbatim: "Search messages")) { EmptyView() }
                .textFieldStyle(.plain)
                .font(BrahmaTheme.body)
                .foregroundStyle(BrahmaTheme.text0)
                .accessibilityLabel(Text("Search messages"))
        }
        .padding(.horizontal, 7)
        .frame(width: 160, height: 22)
        .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.bg1))
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.lineStrong, lineWidth: 1))
    }

    @ViewBuilder private var usage: some View {
        if let gate = model.usageGateLine {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                Text(verbatim: gate.uppercased()).font(BrahmaTheme.monoSmall).lineLimit(1)
            }
            .foregroundStyle(BrahmaTheme.warning)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: gate))
        } else {
            UsageMeter(info: model.snapshot.usage, timeZone: model.ownerTimeZone, accessibilityText: model.usageLine)
        }
    }
}

/// Every reason nothing is running, as the engine reports them (derived from agent text, so shown verbatim).
private struct WhyPopover: View {
    let reasons: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            CapsLabel("Why nothing is running")
            ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "·").foregroundStyle(BrahmaTheme.text2)
                    Text(verbatim: reason).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text0)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(BrahmaTheme.spaceM)
        .frame(width: 340, alignment: .leading)
        .background(BrahmaTheme.bg1)
    }
}

/// The top bar's quick switches (Company › Settings holds the rest): the auto-merge toggle (off by default) and where this week's budget went, by work mode.
private struct CompanySettingsPopover: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
            CapsLabel("Auto-merge and budget")
            Toggle(isOn: Binding(get: { model.autoMergeSmall }, set: { on in Task { await model.setAutoMergeSmall(on) } })) {
                Text(verbatim: "Auto-merge small changes").font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text0)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Text(verbatim: "Tier S items with a passing, allowlisted check merge without waiting for you. Turning it off stops pending auto-merges.")
                .font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2).fixedSize(horizontal: false, vertical: true)
            Hairline()
            CapsLabel("Budget by mode")
            Text(verbatim: model.modeBreakdownLine ?? "No spend recorded this week.")
                .font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1).fixedSize(horizontal: false, vertical: true)
        }
        .padding(BrahmaTheme.spaceM)
        .frame(width: 340, alignment: .leading)
        .background(BrahmaTheme.bg1)
    }
}
