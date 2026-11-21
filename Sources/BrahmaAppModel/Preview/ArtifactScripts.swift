import Foundation
import BrahmaCore

/// Whether an artifact's page runs JavaScript (Plan 4a final review C1). An agent-built page with scripts could reach the
/// network past the file-only rule list (WebRTC), so HTML from an agent or from outside, and any tainted artifact, runs with
/// scripts off until the owner turns them on for that one artifact (`AppModel.scriptEnabledArtifacts`, the owner's own
/// session state; no agent path writes it). The owner's and the engine's own untainted HTML keeps its scripts. SVG never
/// runs scripts. Whatever this says, the web view runs scripts only once WebRTC is verified off (`effective`).
public enum ArtifactScripts {
    /// The header button that turns scripts on for one artifact.
    public static let enableTitle = "Enable scripts for this artifact"
    /// The header button that turns them off again.
    public static let disableTitle = "Turn scripts off"
    public static let offChip = "SCRIPTS OFF"
    public static let onChip = "SCRIPTS ON"
    /// The enable button's help: engine-written, what turning scripts on means.
    public static let warning = "This page was built by an agent or came from outside. Its scripts run inside the app with "
        + "network loads blocked and WebRTC off. Turn them on only if you need the page to be interactive."

    /// Scripts stay off until the owner turns them on: HTML from an agent or from outside, or any tainted HTML. The header
    /// shows the toggle exactly for these.
    public static func ownerMustEnable(kind: ArtifactKind, provenance: Provenance, tainted: Bool) -> Bool {
        guard kind == .html else { return false }
        if tainted { return true }
        switch provenance {
        case .agent, .external: return true
        case .owner, .engine: return false
        }
    }

    /// Whether the policy lets this artifact's page run scripts: never for anything but HTML (an SVG is an image), always for
    /// the owner's and the engine's own untainted HTML, and for the rest only when the owner turned them on (`ownerEnabled`).
    public static func enabled(kind: ArtifactKind, provenance: Provenance, tainted: Bool, ownerEnabled: Bool) -> Bool {
        guard kind == .html else { return false }
        return ownerEnabled || !ownerMustEnable(kind: kind, provenance: provenance, tainted: tainted)
    }

    /// What the web view gets: scripts only when the policy allows them and WebRTC was verified off in its configuration
    /// (`WebRTCGuard.disable`). A missing switch keeps scripts off (fail closed).
    public static func effective(allowed: Bool, webRTCOff: Bool) -> Bool { allowed && webRTCOff }

    /// What an HTML artifact's body says over the page when WebRTC could not be turned off (`WebRTCGuard.unavailableMessage`;
    /// the page then runs without scripts), so the owner is told rather than left with a page that silently lost them. Nil
    /// otherwise, and for anything but HTML (an SVG never runs scripts).
    public static func webRTCNotice(kind: ArtifactKind, webRTCOff: Bool) -> String? {
        kind == .html && !webRTCOff ? WebRTCGuard.unavailableMessage : nil
    }
}

/// Turns WebRTC (`RTCPeerConnection`) off in a web view's preferences (Plan 4a final review C1, I1). Content rule lists and
/// the CSP never see ICE/STUN traffic, so a page with scripts could otherwise send UDP or TCP to any host it names. WebKit
/// has no public switch: this sets the private `peerConnectionEnabled` preference by key-value coding (WebKit's
/// `_setPeerConnectionEnabled:`), after checking that both its setter and getter exist (an unknown key would raise), and
/// reads it back. Anything short of a verified `false` is a failure, and the caller fails closed: an artifact's page runs
/// without scripts, a web preview is not shown. Takes the preferences as an `NSObject` (`WKPreferences` in the app), so the
/// model stays free of WebKit.
public enum WebRTCGuard {
    public static let key = "peerConnectionEnabled"
    static let setter = "_setPeerConnectionEnabled:"
    static let getter = "_peerConnectionEnabled"
    /// What the owner is told, in the web preview and the artifact view, when the switch is missing (engine-written).
    public static let unavailableMessage = "web previews disabled: this macOS can't turn off WebRTC"
    /// Why a web preview is not shown when the switch is missing.
    public static let previewRefusal = unavailableMessage

    /// Sets the preference off on `preferences` and returns whether it now reads back off.
    @discardableResult
    public static func disable(_ preferences: NSObject) -> Bool {
        guard preferences.responds(to: NSSelectorFromString(setter)), preferences.responds(to: NSSelectorFromString(getter)) else {
            return false
        }
        preferences.setValue(false, forKey: key)
        return (preferences.value(forKey: key) as? Bool) == false
    }
}
