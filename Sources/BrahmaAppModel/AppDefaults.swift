import Foundation

/// Final-wave item 20 (FW-B2): the smoke, UI-snapshot and map demo/bench runs never write the owner's real `dev.brahma.app`
/// defaults. Everything the app keeps in `UserDefaults` (preview navigation, the CHANGES layout, drop choices, the map's
/// settings) and everything AppKit keeps there for it (window frames, split-view sizes) goes to the process's standard
/// domain, which is its bundle identifier. So a harness run runs a copy of the app under a throwaway identifier
/// (`dev.brahma.harness.<random>`, `scripts/harness-app.sh`), whose domain the script removes afterwards; a harness launch
/// of the owner's own bundle is refused before any window opens (`AppDelegate`).
public enum AppDefaults {
    /// The owner's app: its bundle identifier, and so its defaults domain.
    public static let ownerDomain = "dev.brahma.app"
    /// The bundle identifiers (and defaults domains) of harness copies.
    public static let harnessPrefix = "dev.brahma.harness."

    /// A launch for the scripts, not for the owner: `--smoke-test`, `--ui-snapshot`, `--map-demo`, `--map-bench`.
    public static func isHarness(_ options: LaunchOptions) -> Bool {
        options.smokeTest || options.snapshotPath != nil || options.mapDemo || options.mapBench != nil
    }

    public enum Decision: Equatable, Sendable {
        /// Use the standard defaults (the owner's app, or a harness copy whose domain is its own).
        case standard
        /// A harness launch of a bundle whose defaults are not a harness copy's: nothing runs.
        case refuse(String)
    }

    /// The owner's launch uses the standard defaults; a harness launch only under a harness copy's bundle identifier.
    public static func decide(options: LaunchOptions, bundleIdentifier: String?) -> Decision {
        guard isHarness(options) else { return .standard }
        guard let id = bundleIdentifier, id.hasPrefix(harnessPrefix), id.count > harnessPrefix.count else {
            return .refuse("a smoke, snapshot or map-demo run would write the defaults of \(bundleIdentifier ?? "an unidentified app") "
                           + "(the owner's are \(ownerDomain)); run it through the scripts (scripts/harness-app.sh), which launch a copy "
                           + "under a throwaway \(harnessPrefix)<id> identifier")
        }
        return .standard
    }
}
