import Testing
import Foundation
@testable import BrahmaCore
@testable import BrahmaAppModel

/// `ThemeHex` is the one color source: `BrahmaTheme` (SwiftUI) and `MapPalette` (NSColor) both read it, so these
/// values are the Plan 2 ops-console palette verbatim. Changing one here changes the app and the map together.
@Suite(.scratch) struct ThemeHexTests {
    @Test func backgroundTokens() {
        #expect(ThemeHex.bg0 == 0x0E1217)
        #expect(ThemeHex.bg1 == 0x141A21)
        #expect(ThemeHex.bg2 == 0x1A2129)
        #expect(ThemeHex.bg3 == 0x212A33)
        #expect(ThemeHex.bg4 == 0x2A3540)
        #expect(ThemeHex.zebra == 0x1D252E)
        #expect(ThemeHex.mapGrid == 0x18202A)
    }

    @Test func borderAndTextTokens() {
        #expect(ThemeHex.line == 0x2F3A45)
        #expect(ThemeHex.lineStrong == 0x3D4A57)
        #expect(ThemeHex.text0 == 0xE6EBF0)
        #expect(ThemeHex.text1 == 0xA7B3BF)
        #expect(ThemeHex.text2 == 0x6E7C89)
    }

    @Test func accentAndStatusTokens() {
        #expect(ThemeHex.accent == 0x2D72D2)
        #expect(ThemeHex.accentDim == 0x1F4F91)
        #expect(ThemeHex.running == 0x32A467)
        #expect(ThemeHex.ready == 0x4C90F0)
        #expect(ThemeHex.blocked == 0xE76A6E)
        #expect(ThemeHex.sleeping == 0x6E7C89)
        #expect(ThemeHex.killed == 0x404854)
        #expect(ThemeHex.warning == 0xEC9A3C)
        #expect(ThemeHex.success == 0x32A467)
        #expect(ThemeHex.danger == 0xE76A6E)
    }

    @Test func seriesTokens() {
        #expect(ThemeHex.series == [0x4C90F0, 0x32A467, 0xEC9A3C, 0xC774E8, 0x2EC4B6, 0xE76A6E])
    }

    /// Paused non-killed agents render like sleeping (Plan 2's `AgentNode` rule); killed stays killed.
    @Test func statusFollowsStateAndPause() {
        #expect(ThemeHex.status(.ready, paused: true) == ThemeHex.sleeping)
        #expect(ThemeHex.status(.running, paused: true) == ThemeHex.sleeping)
        #expect(ThemeHex.status(.blocked, paused: true) == ThemeHex.sleeping)
        #expect(ThemeHex.status(.killed, paused: true) == ThemeHex.killed)
        #expect(ThemeHex.status(.ready, paused: false) == ThemeHex.ready)
        #expect(ThemeHex.status(.running, paused: false) == ThemeHex.running)
        #expect(ThemeHex.status(.blocked, paused: false) == ThemeHex.blocked)
        #expect(ThemeHex.status(.sleeping, paused: false) == ThemeHex.sleeping)
        #expect(ThemeHex.status(.killed, paused: false) == ThemeHex.killed)
    }

    /// 3b's trust tokens: tier 0 warning, 1 text1, 2 success, 3 accent; out-of-range tiers clamp.
    @Test func trustTierTokens() {
        #expect(ThemeHex.trustTier(0) == ThemeHex.warning)
        #expect(ThemeHex.trustTier(1) == ThemeHex.text1)
        #expect(ThemeHex.trustTier(2) == ThemeHex.success)
        #expect(ThemeHex.trustTier(3) == ThemeHex.accent)
        #expect(ThemeHex.trustTier(-1) == ThemeHex.warning)
        #expect(ThemeHex.trustTier(9) == ThemeHex.accent)
    }

    /// `BrahmaTheme.roleColor`'s family table lives here now; unknown roles hash to a stable series index.
    @Test func roleSeriesIndexFamilies() {
        #expect(ThemeHex.roleSeriesIndex("frontend engineer") == 0)
        #expect(ThemeHex.roleSeriesIndex("ceo") == 3)
        #expect(ThemeHex.roleSeriesIndex("CEO") == 3)
        #expect(ThemeHex.roleSeriesIndex("ux designer") == 4)
        #expect(ThemeHex.roleSeriesIndex("product manager") == 2)
        #expect(ThemeHex.roleSeriesIndex("qa") == 1)
        #expect(ThemeHex.roleSeriesIndex("sales rep") == 5)
        let unknown = ThemeHex.roleSeriesIndex("zzz")
        #expect((0..<ThemeHex.series.count).contains(unknown))
        #expect(ThemeHex.roleSeriesIndex("zzz") == unknown)
    }
}
