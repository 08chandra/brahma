import Foundation

/// The office easter egg's two routes (spec §4.1), as a pure state machine on map time: type `office` with each letter
/// within `keyWindow` of the previous one, or click the Board `boardClicks` times within `clickWindow` of the first counted
/// click. Each route reports true once, on the event that completes it, and then starts over.
public struct OfficeUnlock: Equatable, Sendable {
    public static let word = "office"
    public static let keyWindow: TimeInterval = 2
    public static let boardClicks = 5
    public static let clickWindow: TimeInterval = 3

    /// One string per letter: a key is compared by its lowercased string, which never traps the way `Character(_:)` can.
    private static let letters = word.map { String($0) }

    /// How many letters of `word` have been typed, and when the last of them was.
    private var matched = 0
    private var lastKeyAt: TimeInterval?
    /// Board clicks counted in the current window, and when the window's first click was.
    private var clicks = 0
    private var firstClickAt: TimeInterval?

    public init() {}

    /// True on the keystroke that completes `word` (case-insensitive). A key later than `keyWindow` after the previous one,
    /// or a wrong letter, resets to the empty prefix, and that key is then tried as the word's first letter.
    public mutating func key(_ c: Character, at t: TimeInterval) -> Bool {
        if let last = lastKeyAt, t - last > Self.keyWindow || t < last { matched = 0 }
        let lower = c.lowercased()
        if lower != Self.letters[matched] {
            matched = 0
            guard lower == Self.letters[0] else { lastKeyAt = nil; return false }
        }
        matched += 1
        lastKeyAt = t
        guard matched == Self.letters.count else { return false }
        matched = 0
        lastKeyAt = nil
        return true
    }

    /// True on the `boardClicks`-th click within `clickWindow` of the first counted click; a click outside the window starts
    /// a new one.
    public mutating func boardClick(at t: TimeInterval) -> Bool {
        if let first = firstClickAt, t - first <= Self.clickWindow, t >= first {
            clicks += 1
        } else {
            firstClickAt = t
            clicks = 1
        }
        guard clicks >= Self.boardClicks else { return false }
        clicks = 0
        firstClickAt = nil
        return true
    }

    /// Any click that is not on the Board breaks the run of Board clicks.
    public mutating func otherClick() {
        clicks = 0
        firstClickAt = nil
    }

    public mutating func reset() {
        self = OfficeUnlock()
    }
}
