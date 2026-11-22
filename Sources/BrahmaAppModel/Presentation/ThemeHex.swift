import Foundation
import BrahmaCore

/// The ops-console color tokens as `0xRRGGBB` sRGB values (docs/superpowers/specs/2026-10-20-visual-design.md).
///
/// This is the one color source: `BrahmaTheme` builds its SwiftUI `Color`s from these, and `BrahmaMapKit`'s
/// `MapPalette` builds its `NSColor`s from the same values, so the map and the chrome can never drift apart.
/// Plain integers only: this module imports neither AppKit nor CoreGraphics.
public enum ThemeHex {
    // MARK: Backgrounds, darkest to lightest
    public static let bg0: UInt32 = 0x0E1217  // window
    public static let bg1: UInt32 = 0x141A21  // sidebar / rail
    public static let bg2: UInt32 = 0x1A2129  // panels
    public static let bg3: UInt32 = 0x212A33  // panel headers, table header, hovered rows
    public static let bg4: UInt32 = 0x2A3540  // selected row
    /// Alternate (odd) row of a zebra-striped table over `bg2`.
    public static let zebra: UInt32 = 0x1D252E
    /// Grid lines of the map over `bg0`.
    public static let mapGrid: UInt32 = 0x18202A

    // MARK: Borders
    public static let line: UInt32 = 0x2F3A45
    public static let lineStrong: UInt32 = 0x3D4A57

    // MARK: Text
    public static let text0: UInt32 = 0xE6EBF0  // primary
    public static let text1: UInt32 = 0xA7B3BF  // secondary
    public static let text2: UInt32 = 0x6E7C89  // tertiary / labels

    // MARK: Accent
    public static let accent: UInt32 = 0x2D72D2
    public static let accentDim: UInt32 = 0x1F4F91

    // MARK: Status
    public static let running: UInt32 = 0x32A467
    public static let ready: UInt32 = 0x4C90F0
    public static let blocked: UInt32 = 0xE76A6E
    public static let sleeping: UInt32 = 0x6E7C89
    public static let killed: UInt32 = 0x404854
    public static let warning: UInt32 = 0xEC9A3C
    public static let success: UInt32 = 0x32A467
    public static let danger: UInt32 = 0xE76A6E

    // MARK: Charts / series
    public static let series: [UInt32] = [0x4C90F0, 0x32A467, 0xEC9A3C, 0xC774E8, 0x2EC4B6, 0xE76A6E]

    // MARK: Office (Plan 4c)
    /// The desk lamp's warm glow.
    public static let officeLamp: UInt32 = 0xF2C572
    /// The CEO office's glass wall.
    public static let officeGlass: UInt32 = 0x2EC4B6
    /// A pod's carpet: its department colour at this alpha over `officeFloor`.
    public static let officeCarpetAlpha: Double = 0.12
    public static let officeFloor = bg0
    public static let officeRoomFloor = bg2
    public static let officeWall = lineStrong
    public static let officeDeskTop = bg3
    public static let officeDeskFace = bg2

    // MARK: Colour math

    /// `fg` composited at `alpha` (clamped to 0…1) over the opaque `bg`, per channel, rounded.
    public static func blend(_ fg: UInt32, over bg: UInt32, alpha: Double) -> UInt32 {
        let a = min(1, max(0, alpha))
        var out: UInt32 = 0
        for shift: UInt32 in [16, 8, 0] {
            let f = Double((fg >> shift) & 0xFF), b = Double((bg >> shift) & 0xFF)
            out |= UInt32((f * a + b * (1 - a)).rounded()) << shift
        }
        return out
    }

    /// The WCAG 2 contrast ratio of two opaque colours, 1…21, symmetric in its arguments.
    public static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// WCAG relative luminance of an sRGB `0xRRGGBB`.
    static func relativeLuminance(_ hex: UInt32) -> Double {
        func linear(_ shift: UInt32) -> Double {
            let c = Double((hex >> shift) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
    }

    // MARK: Semantic helpers

    /// The status color of an agent. Paused non-killed agents render like sleeping (Plan 2's `AgentNode` rule).
    public static func status(_ s: AgentState, paused: Bool) -> UInt32 {
        if paused, s != .killed { return sleeping }
        switch s {
        case .running: return running
        case .ready: return ready
        case .blocked: return blocked
        case .sleeping: return sleeping
        case .killed: return killed
        }
    }

    /// 3b's trust-chip tokens: tier 0 warning, 1 text1, 2 success, 3 accent. Out-of-range tiers clamp.
    public static func trustTier(_ tier: Int) -> UInt32 {
        switch tier {
        case ...0: return warning
        case 1: return text1
        case 2: return success
        default: return accent
        }
    }

    /// Role families, first match on the lowercased role wins. (Moved here from `BrahmaTheme.roleColor`.)
    static let roleFamilies: [(keys: [String], index: Int)] = [
        (["ceo", "founder", "chief", "exec", "president", "director"], 3),
        (["cto", "eng", "dev", "architect", "backend", "frontend", "ops", "infra"], 0),
        (["design", "ux", "ui", "brand", "art"], 4),
        (["product", "pm", "manager", "lead"], 2),
        (["qa", "test", "quality"], 1),
        (["market", "sales", "growth", "writer", "content", "support"], 5),
    ]

    /// The `series` index of a role's family; unknown roles get a stable index from a scalar sum.
    public static func roleSeriesIndex(_ role: String) -> Int {
        let role = role.lowercased()
        for family in roleFamilies where family.keys.contains(where: { role.contains($0) }) {
            return family.index
        }
        let sum = role.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return sum % series.count
    }
}
