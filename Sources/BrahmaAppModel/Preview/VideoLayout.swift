import Foundation

/// How a video artifact is framed (Plan 4a Task 8a): a portrait clip with a phone's aspect sits in the theme's phone
/// frame; everything else plays plain. The owner's "PHONE FRAME" toggle overrides the choice in the view.
public enum VideoLayout: Equatable, Sendable {
    case phone, plain

    /// Width ÷ height (after rotation) that reads as a phone screen: 9:16 is 0.5625.
    public static let phoneRange = 0.5...0.6

    /// `width` and `height` are the track's natural size; `rotationDegrees` its preferred transform's rotation. A ±90°
    /// rotation (or 270°) swaps them. Non-finite or empty sizes are plain.
    public static func layout(width: Double, height: Double, rotationDegrees: Double) -> VideoLayout {
        guard width.isFinite, height.isFinite, rotationDegrees.isFinite, width > 0, height > 0 else { return .plain }
        var w = width, h = height
        if abs(rotationDegrees.rounded().truncatingRemainder(dividingBy: 180)) == 90 { swap(&w, &h) }
        return phoneRange.contains(w / h) ? .phone : .plain
    }
}
