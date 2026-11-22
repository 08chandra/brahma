import Testing
import Foundation
@testable import BrahmaAppModel

@Suite(.scratch) struct OfficeUnlockTests {
    /// Feeds `word` one key at a time starting at `start`, `step` apart; returns each key's result.
    private func type(_ u: inout OfficeUnlock, _ word: String, start: TimeInterval, step: TimeInterval = 0.1) -> [Bool] {
        word.enumerated().map { i, c in u.key(c, at: start + Double(i) * step) }
    }

    /// Feeds Board clicks at `times`; returns each click's result.
    private func clicks(_ u: inout OfficeUnlock, _ times: [TimeInterval]) -> [Bool] {
        times.map { u.boardClick(at: $0) }
    }

    @Test func pinnedValues() {
        #expect(OfficeUnlock.word == "office")
        #expect(OfficeUnlock.keyWindow == 2)
        #expect(OfficeUnlock.boardClicks == 5)
        #expect(OfficeUnlock.clickWindow == 3)
    }

    @Test func wordUnlocksWithinWindow() {
        var u = OfficeUnlock()
        let r = zip("office", [0, 0.5, 1, 1.5, 2.0, 2.5]).map { u.key($0, at: $1) }
        #expect(r == [false, false, false, false, false, true])
    }

    @Test func upperCaseAccepted() {
        var u = OfficeUnlock()
        let upper = type(&u, "OFFICE", start: 0)
        #expect(upper == [false, false, false, false, false, true])
        var mixed = OfficeUnlock()
        let r = type(&mixed, "oFfIcE", start: 0)
        #expect(r.last == true)
    }

    @Test func slowKeysReset() {
        var u = OfficeUnlock()
        let slow = type(&u, "offic", start: 0, step: 0.4)
        // 2.4 s after the `c` at 1.6: the prefix is gone, and `e` alone is not a first letter.
        let late = u.key("e", at: 4.0)
        #expect(slow == [false, false, false, false, false])
        #expect(!late)
        let quick = type(&u, "office", start: 5)
        #expect(quick == [false, false, false, false, false, true])

        // Exactly at the window still counts; just past it does not.
        var edge = OfficeUnlock()
        let atWindow = type(&edge, "office", start: 0, step: 2)
        #expect(atWindow.last == true)
        var past = OfficeUnlock()
        let first = past.key("o", at: 0)
        let second = past.key("f", at: 2.01)
        let rest = type(&past, "ffice", start: 2.1)
        #expect(!first && !second)
        #expect(rest == [false, false, false, false, false])
    }

    @Test func wrongKeyRestartsPrefix() {
        var u = OfficeUnlock()
        let wrong = type(&u, "ofx", start: 0)
        let then = type(&u, "office", start: 1)
        #expect(wrong == [false, false, false])
        #expect(then.last == true)
        // The wrong letter is tried as a first letter: in "offoffice" the second `o` starts the word.
        var overlap = OfficeUnlock()
        let r = type(&overlap, "offoffice", start: 0)
        #expect(r == [false, false, false, false, false, false, false, false, true])
        // A non-letter key resets.
        var other = OfficeUnlock()
        let spaced = type(&other, "off ice", start: 0)
        #expect(!spaced.contains(true))
    }

    @Test func completingStartsOver() {
        var u = OfficeUnlock()
        let once = type(&u, "office", start: 0)
        // One more `e` right after does not complete it again; the whole word does.
        let extra = u.key("e", at: 0.7)
        let twice = type(&u, "office", start: 1)
        #expect(once.last == true)
        #expect(!extra)
        #expect(twice.last == true)
    }

    @Test func fiveBoardClicksWithinWindow() {
        var u = OfficeUnlock()
        let r = clicks(&u, [0, 0.5, 1, 1.5, 2.9])
        #expect(r == [false, false, false, false, true])
    }

    @Test func slowClicksReset() {
        var u = OfficeUnlock()
        // A sliding window (ruling R10): the last five clicks must fall within 3 s, the boundary included. At 4.5 the last
        // five (1…4.5) span 3.5 s; at 5.0 they (2, 3.5, 4, 4.5, 5) span exactly 3.0 s and unlock. The route then starts
        // over, so 6.2 alone does nothing.
        let r = clicks(&u, [0, 1, 2, 3.5, 4, 4.5, 5, 6.2])
        #expect(r == [false, false, false, false, false, false, true, false])
        // Just past the boundary does not.
        var past = OfficeUnlock()
        let p = clicks(&past, [0, 1, 2, 3, 3.01])
        #expect(!p.contains(true))
        // Clicks a second apart never get five into one window.
        var slow = OfficeUnlock()
        let s = clicks(&slow, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        #expect(!s.contains(true))
    }

    /// A stray earlier click never delays the unlock: the five clicks 2.5…3.3 unlock although the first click (0) is 3.3 s
    /// before the last.
    @Test func strayClickDoesNotDelay() {
        var u = OfficeUnlock()
        let r = clicks(&u, [0, 2.5, 2.7, 2.9, 3.1, 3.3])
        #expect(r == [false, false, false, false, false, true])
    }

    /// A clock that went backwards starts the count over from that click.
    @Test func backwardsClockRestartsClicks() {
        var u = OfficeUnlock()
        let r = clicks(&u, [10, 10.2, 10.4, 10.6, 1, 1.2, 1.4, 1.6, 1.8])
        #expect(r == [false, false, false, false, false, false, false, false, true])
    }

    @Test func otherClickResets() {
        var u = OfficeUnlock()
        let four = clicks(&u, [0, 0.2, 0.4, 0.6])
        u.otherClick()
        let fifth = u.boardClick(at: 0.8)
        #expect(!four.contains(true))
        #expect(!fifth)
    }

    @Test func resetClearsBothRoutes() {
        var u = OfficeUnlock()
        _ = type(&u, "offic", start: 0)
        _ = clicks(&u, [0, 0.2, 0.4, 0.6])
        u.reset()
        #expect(u == OfficeUnlock())
        let key = u.key("e", at: 0.6)
        let click = u.boardClick(at: 0.8)
        #expect(!key && !click)
    }
}
