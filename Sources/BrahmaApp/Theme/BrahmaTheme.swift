import SwiftUI
import BrahmaCore

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
/// Views use these instead of ad-hoc colors, fonts and sizes.
enum BrahmaTheme {
    // MARK: Backgrounds, darkest to lightest
    static let bg0 = Color(hex: 0x0E1217)  // window
    static let bg1 = Color(hex: 0x141A21)  // sidebar / rail
    static let bg2 = Color(hex: 0x1A2129)  // panels
    static let bg3 = Color(hex: 0x212A33)  // panel headers, table header, hovered rows
    static let bg4 = Color(hex: 0x2A3540)  // selected row
    /// Alternate (odd) row of a zebra-striped table over `bg2`.
    static let zebra = Color(hex: 0x1D252E)
    /// Grid lines of the map placeholder over `bg0`.
    static let mapGrid = Color(hex: 0x18202A)

    // MARK: Borders
    static let line = Color(hex: 0x2F3A45)
    static let lineStrong = Color(hex: 0x3D4A57)

    // MARK: Text
    static let text0 = Color(hex: 0xE6EBF0)  // primary
    static let text1 = Color(hex: 0xA7B3BF)  // secondary
    static let text2 = Color(hex: 0x6E7C89)  // tertiary / labels

    // MARK: Accent
    static let accent = Color(hex: 0x2D72D2)
    static let accentDim = Color(hex: 0x1F4F91)

    // MARK: Status
    static let running = Color(hex: 0x32A467)
    static let ready = Color(hex: 0x4C90F0)
    static let blocked = Color(hex: 0xE76A6E)
    static let sleeping = Color(hex: 0x6E7C89)
    static let killed = Color(hex: 0x404854)
    static let warning = Color(hex: 0xEC9A3C)
    static let success = Color(hex: 0x32A467)
    static let danger = Color(hex: 0xE76A6E)

    // MARK: Charts / series
    static let series: [Color] = [
        Color(hex: 0x4C90F0), Color(hex: 0x32A467), Color(hex: 0xEC9A3C),
        Color(hex: 0xC774E8), Color(hex: 0x2EC4B6), Color(hex: 0xE76A6E),
    ]

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

    /// Avatar color by role family; unknown roles get a stable series color.
    static func roleColor(_ role: String?) -> Color {
        guard let role = role?.lowercased(), !role.isEmpty else { return text2 }
        let families: [(keys: [String], color: Color)] = [
            (["ceo", "founder", "chief", "exec", "president", "director"], series[3]),
            (["cto", "eng", "dev", "architect", "backend", "frontend", "ops", "infra"], series[0]),
            (["design", "ux", "ui", "brand", "art"], series[4]),
            (["product", "pm", "manager", "lead"], series[2]),
            (["qa", "test", "quality"], series[1]),
            (["market", "sales", "growth", "writer", "content", "support"], series[5]),
        ]
        for family in families where family.keys.contains(where: { role.contains($0) }) {
            return family.color
        }
        let sum = role.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return series[sum % series.count]
    }
}
