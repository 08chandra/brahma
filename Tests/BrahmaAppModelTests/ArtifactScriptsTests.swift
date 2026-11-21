import Foundation
import Testing
import WebKit
@testable import BrahmaCore
@testable import BrahmaAppModel

/// Plan 4a final review C1, I1: an agent's, an outside or a tainted HTML artifact runs without scripts until the owner turns
/// them on for it, and WebRTC is off in every artifact and web-preview view, failing closed when the switch is missing.
@MainActor @Suite(.scratch) struct ArtifactScriptsTests {
    // MARK: The policy

    @Test func policyMatrix() {
        let provenances: [Provenance] = [.owner, .engine, .agent("eng-1"), .external("web page")]
        for p in provenances {
            for tainted in [false, true] {
                for owner in [false, true] {
                    let mustEnable = tainted || p == .agent("eng-1") || p == .external("web page")
                    let html = ArtifactScripts.enabled(kind: .html, provenance: p, tainted: tainted, ownerEnabled: owner)
                    #expect(html == (!mustEnable || owner), "html \(p) tainted \(tainted) owner \(owner)")
                    #expect(ArtifactScripts.ownerMustEnable(kind: .html, provenance: p, tainted: tainted) == mustEnable)
                    // SVG (an image) and every other kind never run scripts, and never show the toggle.
                    for kind in [ArtifactKind.image, .markdown, .pdf, .text, .video] {
                        #expect(!ArtifactScripts.enabled(kind: kind, provenance: p, tainted: tainted, ownerEnabled: owner), "\(kind) \(p)")
                        #expect(!ArtifactScripts.ownerMustEnable(kind: kind, provenance: p, tainted: tainted))
                    }
                }
            }
        }
        // The web view runs scripts only when WebRTC was verified off.
        #expect(ArtifactScripts.effective(allowed: true, webRTCOff: true))
        #expect(!ArtifactScripts.effective(allowed: true, webRTCOff: false))
        #expect(!ArtifactScripts.effective(allowed: false, webRTCOff: true))
    }

    // MARK: The model (the header's toggle)

    static func artifact(_ w: WorkWorld, id: String, number: Int, by: String, kind: ArtifactKind = .html, tainted: Bool = false) throws -> Artifact {
        let a = Artifact(id: id, companyId: w.company.id, number: number, title: "Page \(number)", kind: kind,
                         storedPath: ".brahma/artifacts/\(number)-page", entryFile: kind == .image ? "p.svg" : "index.html", sourcePath: "x",
                         publishedById: by, itemId: nil, bytes: 11, createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(number)),
                         tainted: tainted, taintReason: tainted ? "written by a session that read a web page" : nil)
        try w.store.writer.write { db in try a.insert(db) }
        return a
    }

    @Test func ownerToggleIsPerArtifactAndPerCompany() async throws {
        let w = try await WorkWorld.make()
        // A real publication (so the owner's delete has a copy to remove), made the agent's.
        var agentHTML = try QueueModelLayerTests.publish(w, "page.html", title: "Page")
        let (publishedId, engId) = (agentHTML.id, w.eng.id)
        try await w.store.writer.write { db in
            try db.execute(sql: "UPDATE artifact SET publishedById = ? WHERE id = ?", arguments: [engId, publishedId])
        }
        agentHTML.publishedById = engId
        let otherAgentHTML = try Self.artifact(w, id: "ar2", number: 2, by: w.eng.id)
        let ownerHTML = try Self.artifact(w, id: "ar3", number: 3, by: "owner")
        let taintedOwnerHTML = try Self.artifact(w, id: "ar4", number: 4, by: "owner", tainted: true)
        let agentSVG = try Self.artifact(w, id: "ar5", number: 5, by: w.eng.id, kind: .image)
        let m = w.model
        // By default: the agent's and the tainted pages run without scripts and show the toggle; the owner's own page runs
        // them with no toggle; an SVG never runs them and shows none.
        #expect(!m.artifactScriptsEnabled(agentHTML) && m.artifactScriptsNeedOwner(agentHTML))
        #expect(!m.artifactScriptsEnabled(taintedOwnerHTML) && m.artifactScriptsNeedOwner(taintedOwnerHTML))
        #expect(m.artifactScriptsEnabled(ownerHTML) && !m.artifactScriptsNeedOwner(ownerHTML))
        #expect(!m.artifactScriptsEnabled(agentSVG) && !m.artifactScriptsNeedOwner(agentSVG))
        // The owner turns them on for one artifact only.
        m.setArtifactScripts(true, artifact: agentHTML)
        #expect(m.artifactScriptsEnabled(agentHTML) && !m.artifactScriptsEnabled(otherAgentHTML))
        m.setArtifactScripts(true, artifact: taintedOwnerHTML)
        #expect(m.artifactScriptsEnabled(taintedOwnerHTML))
        // Nothing to turn on where scripts are never run, or already are.
        m.setArtifactScripts(true, artifact: agentSVG)
        m.setArtifactScripts(true, artifact: ownerHTML)
        #expect(!m.artifactScriptsEnabled(agentSVG) && m.scriptEnabledArtifacts == [agentHTML.id, "ar4"])
        // And off again.
        m.setArtifactScripts(false, artifact: taintedOwnerHTML)
        #expect(!m.artifactScriptsEnabled(taintedOwnerHTML) && m.scriptEnabledArtifacts == [agentHTML.id])
        // Deleting the artifact drops the choice.
        await m.deleteArtifact(agentHTML)
        #expect(m.scriptEnabledArtifacts.isEmpty)
        // The choice never outlives the company selection.
        m.setArtifactScripts(true, artifact: otherAgentHTML)
        await m.selectCompany(w.company.id)
        #expect(m.scriptEnabledArtifacts.isEmpty && !m.artifactScriptsEnabled(otherAgentHTML))
    }

    // MARK: WebRTC (the configuration builder's switch)

    /// The real WebKit preferences have the switch, and it reads back off once set: what both web views rely on.
    @Test func webKitPreferencesTurnPeerConnectionsOff() {
        let config = WKWebViewConfiguration()
        #expect((config.preferences.value(forKey: WebRTCGuard.key) as? Bool) == true, "WebRTC is on by default")
        #expect(WebRTCGuard.disable(config.preferences))
        #expect((config.preferences.value(forKey: WebRTCGuard.key) as? Bool) == false)
        // The view made from that configuration keeps it.
        let view = WKWebView(frame: .zero, configuration: config)
        #expect((view.configuration.preferences.value(forKey: WebRTCGuard.key) as? Bool) == false)
    }

    /// Preferences without the switch: the guard says so (no exception from an unknown key), and the caller keeps scripts off.
    @Test func missingSwitchFailsClosed() {
        #expect(!WebRTCGuard.disable(NoSwitch()))
        #expect(!WebRTCGuard.disable(SetterOnly()))
        #expect(!WebRTCGuard.disable(StuckSwitch()), "a switch that does not read back off is a failure")
        let working = WorkingSwitch()
        #expect(WebRTCGuard.disable(working) && !working.value)
        // The artifact view: no verified switch, no scripts, even for the owner's own page.
        let allowed = ArtifactScripts.enabled(kind: .html, provenance: .owner, tainted: false, ownerEnabled: false)
        #expect(allowed && !ArtifactScripts.effective(allowed: allowed, webRTCOff: WebRTCGuard.disable(NoSwitch())))
        #expect(ArtifactScripts.effective(allowed: allowed, webRTCOff: WebRTCGuard.disable(WorkingSwitch())))
        // The web preview: no verified switch, no web view.
        let ready = PreviewGuardState<Int>.ready(1, cspScript: "csp")
        #expect(!ready.requiringWebRTCOff(WebRTCGuard.disable(NoSwitch())).showsWebView)
        if case .failed(let why) = ready.requiringWebRTCOff(false) { #expect(why == WebRTCGuard.previewRefusal) } else { Issue.record("not failed") }
        #expect(ready.requiringWebRTCOff(WebRTCGuard.disable(WorkingSwitch())).showsWebView)
        #expect(!PreviewGuardState<Int>.failed("rules").requiringWebRTCOff(true).showsWebView)
    }
}

/// No such preference at all.
private final class NoSwitch: NSObject {}

/// A setter with no getter: the value cannot be verified.
private final class SetterOnly: NSObject {
    @objc(_setPeerConnectionEnabled:) func setPeerConnection(_ on: Bool) {}
}

/// A switch that ignores the write.
private final class StuckSwitch: NSObject {
    @objc(_setPeerConnectionEnabled:) func setPeerConnection(_ on: Bool) {}
    @objc(_peerConnectionEnabled) var peerConnection: Bool { true }
}

/// WebKit's shape: `_setPeerConnectionEnabled:` and `_peerConnectionEnabled`.
private final class WorkingSwitch: NSObject {
    var value = true
    @objc(_setPeerConnectionEnabled:) func setPeerConnection(_ on: Bool) { value = on }
    @objc(_peerConnectionEnabled) var peerConnection: Bool { value }
}
