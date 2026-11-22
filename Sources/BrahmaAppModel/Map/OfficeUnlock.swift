import Foundation

/// The office easter egg's two routes (spec §4.1), as a pure state machine on map time: type `office` with each letter
/// within `keyWindow` of the previous one, or click the Board so that the last `boardClicks` clicks fall within `clickWindow`
/// (a sliding window, ruling R10: a stray earlier click never delays it). Each route reports true once, on the event that
/// completes it, and then starts over.
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
    /// The times of the latest Board clicks, oldest first; at most `boardClicks`.
    private var clicks: [TimeInterval] = []

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

    /// True on the click that makes the last `boardClicks` clicks span at most `clickWindow` (the boundary counts). A clock
    /// that went backwards starts the count over from this click.
    public mutating func boardClick(at t: TimeInterval) -> Bool {
        if let last = clicks.last, t < last { clicks = [] }
        clicks.append(t)
        if clicks.count > Self.boardClicks { clicks.removeFirst(clicks.count - Self.boardClicks) }
        guard clicks.count == Self.boardClicks, let first = clicks.first, t - first <= Self.clickWindow else { return false }
        clicks = []
        return true
    }

    /// Any click that is not on the Board breaks the run of Board clicks.
    public mutating func otherClick() {
        clicks = []
    }

    public mutating func reset() {
        self = OfficeUnlock()
    }
}
