import AppKit
import BrahmaCore
import BrahmaAppModel

/// `NSColor`s for the SpriteKit map, built only from `ThemeHex` so the map and the SwiftUI chrome share one palette.
@MainActor
public enum MapPalette {
    /// `0xRRGGBB` in sRGB, like `BrahmaTheme`'s `Color(hex:)`.
    public static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    /// The status bar color of an agent card; paused non-killed agents render like sleeping.
    public static func status(_ s: AgentState, paused: Bool) -> NSColor {
        color(ThemeHex.status(s, paused: paused))
    }

    /// The color family of a team band's stripe.
    public static func department(_ d: Department) -> NSColor {
        color(ThemeHex.series[seriesIndex(d)])
    }

    /// `ThemeHex.series` index per department; related departments share a family.
    static func seriesIndex(_ d: Department) -> Int {
        switch d {
        case .csuite: 3
        case .engineering: 0
        case .design: 4
        case .research: 3
        case .sales: 5
        case .operations: 2
        case .finance: 2
        case .people: 5
        case .quality: 1
        }
    }
}
