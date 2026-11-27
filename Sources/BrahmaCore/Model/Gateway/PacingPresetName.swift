import Foundation

/// The owner-wide pacing preset (`ownerSettings.pacingPreset`, `"vX1-gateway"`); `PacingPreset` (Task 15) holds the numbers.
/// `conservative` is the default.
public enum PacingPresetName: String, Codable, Sendable, CaseIterable {
    case conservative, standard, full
}
