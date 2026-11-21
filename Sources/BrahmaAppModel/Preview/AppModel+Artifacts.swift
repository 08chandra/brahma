import Foundation
import BrahmaCore

/// The artifacts tab's model-side actions (Plan 4a Task 8b), and the backend OpenAPI parse the bodies wait on.
extension AppModel {
    /// The entry file's render mode and size, as the snapshot stat'd it (no view reads a file).
    public func fileBody(for a: Artifact) -> FileBody? { snapshot.preview.fileBodies[a.id] }

    /// Shows this artifact in the ARTIFACTS tab.
    public func selectArtifact(_ a: Artifact) {
        selectedArtifactId = a.id
        selectedPreviewTab = PreviewTabID.artifacts
    }

    /// Owner only: removes the artifact's row, memory doc and copy (`Store.deleteArtifact`).
    public func deleteArtifact(_ a: Artifact) async {
        if selectedArtifactId == a.id { selectedArtifactId = nil }
        phoneFrameOverride[a.id] = nil
        await ownerWrite("delete the artifact") { store in try store.deleteArtifact(id: a.id, by: .owner) }
    }

    /// Whether a video artifact sits in the phone frame: the owner's override for it, else what `VideoLayout` detected.
    public func phoneFrame(for artifactId: String, detected: VideoLayout) -> Bool {
        phoneFrameOverride[artifactId] ?? (detected == .phone)
    }

    /// The owner's "PHONE FRAME" toggle for one artifact (kept until the company changes).
    public func setPhoneFrame(_ on: Bool, artifactId: String) { phoneFrameOverride[artifactId] = on }

    // MARK: OpenAPI (the one parser the model runs)

    /// Parses, through `RendererCaps.parse`, the engine's OpenAPI copy of every running backend whose copy the cache has not
    /// seen (keyed by path, commit and start), and drops the entries of surfaces no longer serving one. Called after each
    /// snapshot refresh.
    func refreshOpenAPI() {
        let p = snapshot.preview
        openAPICache = openAPICache.filter { p.openAPIFiles[$0.key] != nil }
        for (sid, url) in p.openAPIFiles {
            let state = p.states[sid]
            let key = OpenAPIKey(path: url.path, commit: state?.commit, startedAt: state?.startedAt)
            if openAPICache[sid]?.key == key { continue }
            openAPICache[sid] = OpenAPICacheEntry(key: key, result: .loading)
            let companyId = selectedCompanyId
            Task { [weak self] in
                let result: PreviewOpenAPI
                do {
                    let operations = try await RendererCaps.parse { OpenAPISummary.load(url) }
                    result = .operations(operations ?? [])
                } catch RendererError.timedOut {
                    result = .timedOut
                } catch {
                    result = .operations([])
                }
                guard let self, self.selectedCompanyId == companyId, self.openAPICache[sid]?.key == key else { return }
                self.openAPICache[sid]?.result = result
            }
        }
    }

    /// The preview snapshot with the parsed OpenAPI results laid over it (what the bodies read).
    var previewWithOpenAPI: PreviewSnapshot {
        var p = snapshot.preview
        for (sid, entry) in openAPICache { p.openAPI[sid] = entry.result }
        return p
    }
}

struct OpenAPIKey: Hashable, Sendable {
    var path: String
    var commit: String?
    var startedAt: Date?
}

struct OpenAPICacheEntry: Equatable, Sendable {
    var key: OpenAPIKey
    var result: PreviewOpenAPI
}
