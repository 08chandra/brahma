import SwiftUI
import BrahmaCore
import BrahmaAppModel

// Chrome instruments: company rail tile and usage meter.

/// 52 pt rail row holding a 32 pt square monogram tile: status dot bottom-right (running green,
/// paused grey), accent unread badge top-right, 2 pt accent bar on the rail's left edge when selected.
struct RailTile: View {
    let initials: String
    let selected: Bool
    let running: Bool
    let badge: Int
    @State private var hovered = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: BrahmaTheme.radiusLarge)
                .fill(selected ? BrahmaTheme.bg4 : (hovered ? BrahmaTheme.bg3 : BrahmaTheme.bg2))
            RoundedRectangle(cornerRadius: BrahmaTheme.radiusLarge)
                .strokeBorder(selected ? BrahmaTheme.accent : BrahmaTheme.line, lineWidth: 1)
            Text(verbatim: initials)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(selected ? BrahmaTheme.text0 : BrahmaTheme.text1)
        }
        .frame(width: BrahmaTheme.railTile, height: BrahmaTheme.railTile)
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(running ? BrahmaTheme.running : BrahmaTheme.sleeping)
                .frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(BrahmaTheme.bg1, lineWidth: 2).padding(-2))
                .offset(x: 3, y: 3)
        }
        .overlay(alignment: .topTrailing) {
            if badge > 0 {
                Text(verbatim: badge > 99 ? "99+" : "\(badge)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.accent))
                    .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.bg1, lineWidth: 1).padding(-1))
                    .offset(x: 6, y: -6)
            }
        }
        .frame(width: BrahmaTheme.railWidth, height: BrahmaTheme.railTile + 8)
        .overlay(alignment: .leading) {
            if selected {
                Rectangle().fill(BrahmaTheme.accent).frame(width: 2, height: BrahmaTheme.railTile)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(BrahmaTheme.fast) { hovered = inside } }
    }
}

/// `5H 52% ▮▮▮▯▯ · 7D 26% · RESETS 20:00` in monospace. Display only: the tested copy stays `AppModel.usageLine`.
struct UsageMeter: View {
    let info: RateLimitInfo?
    var now: Date = .now
    /// The owner's time zone, for the reset time.
    var timeZone: TimeZone = .current
    /// Accessibility text (the model's `usageLine`).
    var accessibilityText: String

    var body: some View {
        HStack(spacing: 6) {
            if let info {
                window("5H", info.fiveHourUtilization, bar: true)
                separator
                window("7D", info.sevenDayUtilization, bar: false)
                if let reset = info.resetsAt, reset > now {
                    separator
                    label("RESETS")
                    Text(verbatim: TimeText.hm(reset, timeZone: timeZone)).foregroundStyle(BrahmaTheme.text0)
                }
            } else {
                label("USAGE")
                Text(verbatim: "NO DATA").foregroundStyle(BrahmaTheme.text2)
            }
        }
        .font(BrahmaTheme.monoSmall)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    private var separator: some View { Text(verbatim: "·").foregroundStyle(BrahmaTheme.text2) }

    private func label(_ s: String) -> some View { Text(verbatim: s).foregroundStyle(BrahmaTheme.text2) }

    private func window(_ name: String, _ value: Double?, bar: Bool) -> some View {
        let color = Self.color(value)
        return HStack(spacing: 5) {
            label(name)
            Text(verbatim: value.map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a").foregroundStyle(color)
            if bar, let value {
                let filled = min(5, max(0, Int((value * 5).rounded())))
                Text(verbatim: String(repeating: "▮", count: filled)).foregroundStyle(color)
                    + Text(verbatim: String(repeating: "▯", count: 5 - filled)).foregroundStyle(BrahmaTheme.text2)
            }
        }
    }

    private static func color(_ value: Double?) -> Color {
        guard let value else { return BrahmaTheme.text2 }
        if value >= 0.9 { return BrahmaTheme.danger }
        if value >= 0.75 { return BrahmaTheme.warning }
        return BrahmaTheme.text0
    }
}
