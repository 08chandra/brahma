import SwiftUI
import BrahmaCore
import BrahmaAppModel

extension Color {
    /// `0xRRGGBB` in sRGB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Design tokens of the ops-console look (docs/superpowers/specs/2026-10-20-visual-design.md).
/// Views use these instead of ad-hoc colors, fonts and sizes. Every color reads `ThemeHex`, the one hex source the
/// SpriteKit map (`MapPalette`) shares, so the two can never drift apart.
enum BrahmaTheme {
    // MARK: Backgrounds, darkest to lightest
    static let bg0 = Color(hex: ThemeHex.bg0)  // window
    static let bg1 = Color(hex: ThemeHex.bg1)  // sidebar / rail
    static let bg2 = Color(hex: ThemeHex.bg2)  // panels
    static let bg3 = Color(hex: ThemeHex.bg3)  // panel headers, table header, hovered rows
    static let bg4 = Color(hex: ThemeHex.bg4)  // selected row
    /// Alternate (odd) row of a zebra-striped table over `bg2`.
    static let zebra = Color(hex: ThemeHex.zebra)
    /// Grid lines of the map placeholder over `bg0`.
    static let mapGrid = Color(hex: ThemeHex.mapGrid)

    // MARK: Borders
    static let line = Color(hex: ThemeHex.line)
    static let lineStrong = Color(hex: ThemeHex.lineStrong)

    // MARK: Text
    static let text0 = Color(hex: ThemeHex.text0)  // primary
    static let text1 = Color(hex: ThemeHex.text1)  // secondary
    static let text2 = Color(hex: ThemeHex.text2)  // tertiary / labels

    // MARK: Accent
    static let accent = Color(hex: ThemeHex.accent)
    static let accentDim = Color(hex: ThemeHex.accentDim)

    // MARK: Status
    static let running = Color(hex: ThemeHex.running)
    static let ready = Color(hex: ThemeHex.ready)
    static let blocked = Color(hex: ThemeHex.blocked)
    static let sleeping = Color(hex: ThemeHex.sleeping)
    static let killed = Color(hex: ThemeHex.killed)
    static let warning = Color(hex: ThemeHex.warning)
    static let success = Color(hex: ThemeHex.success)
    static let danger = Color(hex: ThemeHex.danger)

    // MARK: Charts / series
    static let series: [Color] = ThemeHex.series.map { Color(hex: $0) }

    // MARK: Typography (SF Pro / SF Mono, no bundled fonts)
    static let body = Font.system(size: 12)
    static let bodyLarge = Font.system(size: 13)
    static let bodyStrong = Font.system(size: 12, weight: .semibold)
    /// Panel titles and section labels: render uppercase with `labelTracking`.
    static let panelTitle = Font.system(size: 11, weight: .semibold)
    /// Chip labels, key-value labels, tiny section headers: render uppercase with `labelTracking`.
    static let label = Font.system(size: 10, weight: .semibold)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    static let monoTiny = Font.system(size: 10, weight: .medium, design: .monospaced)
    /// The largest text in the app: the company name in the top bar.
    static let companyTitle = Font.system(size: 15, weight: .semibold)
    static let labelTracking: CGFloat = 0.6

    // MARK: Spacing and radius
    static let spaceXS: CGFloat = 4
    static let spaceS: CGFloat = 8
    static let spaceM: CGFloat = 12
    static let spaceL: CGFloat = 16
    static let radius: CGFloat = 2
    static let radiusLarge: CGFloat = 3

    // MARK: Sizes
    static let railWidth: CGFloat = 52
    static let railTile: CGFloat = 32
    static let topBarHeight: CGFloat = 40
    static let panelHeaderHeight: CGFloat = 28
    static let panelPadding: CGFloat = 8
    static let rowHeight: CGFloat = 24
    static let denseRowHeight: CGFloat = 22
    static let chipHeight: CGFloat = 18
    static let avatar: CGFloat = 20
    /// Leading inset that keeps top-bar content clear of the window's traffic lights.
    static let trafficLightInset: CGFloat = 78

    // MARK: Motion (120–200 ms)
    static let fast = Animation.easeOut(duration: 0.12)
    static let medium = Animation.easeInOut(duration: 0.2)

    // MARK: Semantic helpers
    static func statusColor(for state: AgentState) -> Color {
        switch state {
        case .running: running
        case .ready: ready
        case .blocked: blocked
        case .sleeping: sleeping
        case .killed: killed
        }
    }

    /// Avatar color by role family (`ThemeHex.roleSeriesIndex`); unknown roles get a stable series color.
    static func roleColor(_ role: String?) -> Color {
        guard let role, !role.isEmpty else { return text2 }
        return series[ThemeHex.roleSeriesIndex(role)]
    }
}
