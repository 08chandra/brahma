import AppKit
import SpriteKit
import BrahmaCore
import BrahmaAppModel

/// The office's level of detail, by living-agent count (spec §5.5).
public enum OfficeLOD: Equatable, Sendable {
    /// Everything moves: typing frames, glow pulses, walks and idle strolls.
    case full
    /// Figures appear where they belong but do not animate.
    case staticFigures
    /// No figures: desks show state by light, bubbles become 4 pt markers, the doors count.
    case deskOnly
}

/// Z offsets inside a layer, so labels and bubbles stay above the y-sorted figures (`zPosition = -position.y`, a few
/// thousand at most) whatever their depth.
@MainActor
enum OfficeZ {
    static let labels: CGFloat = 50_000
    static let overlay: CGFloat = 100_000
}
