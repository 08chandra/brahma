import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// 40 pt `bg2` top bar with a bottom hairline: company name · usage mode · state counts · usage meter · run control.
struct TopBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: BrahmaTheme.spaceL) {
            Text(verbatim: model.selectedCompany?.company.name ?? "Brahma")
                .font(BrahmaTheme.companyTitle)
                .foregroundStyle(BrahmaTheme.text0)
                .lineLimit(1)
                .layoutPriority(1)
            if let summary = model.selectedCompany {
                UsageModeControl(mode: summary.company.usageMode) { mode in
                    Task { await model.setUsageMode(mode) }
                }
                CountChips(counts: summary.counts)
                Spacer(minLength: BrahmaTheme.spaceM)
                usage
                let running = summary.company.status == .running
                Button {
                    Task { await model.setCompanyRunning(!running, companyId: summary.id) }
                } label: {
                    Label(running ? "Pause company" : "Run company", systemImage: running ? "pause.fill" : "play.fill")
                }
                .buttonStyle(BrahmaButtonStyle(primary: !running))
            } else {
                Spacer()
            }
        }
        .padding(.leading, BrahmaTheme.trafficLightInset)
        .padding(.trailing, BrahmaTheme.spaceM)
        .frame(height: BrahmaTheme.topBarHeight)
        .frame(maxWidth: .infinity)
        .background(BrahmaTheme.bg2)
        .overlay(alignment: .bottom) { Hairline() }
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
            UsageMeter(info: model.snapshot.usage, accessibilityText: model.usageLine)
        }
    }
}

/// Segmented LOW | BALANCED | MAX control (the modes display as "Low", "Balanced", "Max", uppercased here).
private struct UsageModeControl: View {
    let mode: UsageMode
    let select: (UsageMode) -> Void

    private static let modes: [(UsageMode, String)] = [(.low, "Low"), (.balanced, "Balanced"), (.max, "Max")]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.modes.enumerated()), id: \.offset) { index, entry in
                let (value, title) = entry
                let selected = value == mode
                if index > 0 { Hairline(axis: .vertical, color: BrahmaTheme.lineStrong) }
                Button { if !selected { select(value) } } label: {
                    Text(verbatim: title.uppercased())
                        .font(BrahmaTheme.label)
                        .tracking(BrahmaTheme.labelTracking)
                        .foregroundStyle(selected ? Color.white : BrahmaTheme.text1)
                        .padding(.horizontal, 9)
                        .frame(height: 20)
                        .background(selected ? BrahmaTheme.accent : BrahmaTheme.bg3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: title))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .fixedSize()
        .clipShape(RoundedRectangle(cornerRadius: BrahmaTheme.radius))
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.lineStrong, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Usage mode"))
        .help("Usage mode")
    }
}
