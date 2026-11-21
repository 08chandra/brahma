import Foundation
import BrahmaCore

/// The artifacts tab's model-side actions (Plan 4a Task 8b), and the backend OpenAPI parse the bodies wait on.
extension AppModel {
    public static let artifactDeletedTitle = "ARTIFACT DELETED"
    public static let artifactDeletedNotice = "This artifact was deleted"

    /// The entry file's render mode and size, as the snapshot stat'd it (no view reads a file); a pinned older artifact's body
    /// was stat'd when it was looked up.
    public func fileBody(for a: Artifact) -> FileBody? {
        snapshot.preview.fileBodies[a.id] ?? (pinnedArtifact?.artifact.id == a.id ? pinnedArtifact?.body : nil)
    }

    /// Shows this artifact in the ARTIFACTS tab. An owner's pick supersedes any lookup still running (`openArtifact`).
    public func selectArtifact(_ a: Artifact) {
        selectedArtifactId = a.id
        selectedPreviewTab = PreviewTabID.artifacts
        artifactNotice = nil
        artifactSelectionGeneration += 1
    }

    /// `artifact:AR-n`: the artifact among the newest ones the snapshot holds (when that snapshot is this company's), else
    /// looked up in the Store (detached, with the company's workspace read in the same task) and pinned so the tab can show one
    /// older than the snapshot's list. "No artifact AR-n" only when the company has none by that number. A result that lands
    /// after the owner picked something else is dropped.
    public func openArtifact(number: Int) async {
        select(.missionControl)
        guard let companyId = selectedCompanyId else { return }
        if let a = snapshot.preview.artifacts.first(where: { $0.number == number && $0.companyId == companyId }) {
            selectArtifact(a)
            return
        }
        let generation = artifactSelectionGeneration
        let store = self.store
        do {
            let found = try await Task.detached { () -> PinnedArtifact? in
                guard let company = try store.company(id: companyId),
                      let a = try store.artifact(companyId: companyId, number: number) else { return nil }
                let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
                return PinnedArtifact(artifact: a, body: PreviewBodies.fileBody(a, workspace: workspace))
            }.value
            applyLookup(found, number: number, companyId: companyId, generation: generation)
        } catch {
            report(error)
        }
    }

    /// The second half of `openArtifact`: pins and selects what the lookup found, unless the company changed or the owner
    /// selected another artifact while it ran (`generation`).
    func applyLookup(_ found: PinnedArtifact?, number: Int, companyId: String, generation: Int) {
        guard companyId == selectedCompanyId, generation == artifactSelectionGeneration else { return }
        guard let found else {
            errorMessage = "No artifact AR-\(number)"
            return
        }
        pinnedArtifact = found
        selectArtifact(found.artifact)
    }

    /// After each snapshot refresh: a pinned artifact deleted outside the app (the CLI) is unpinned and the tab says so, rather
    /// than keeping a body over a missing path. One indexed read, only while something is pinned.
    func checkPinnedArtifact() async {
        guard let pinned = pinnedArtifact, let companyId = selectedCompanyId else { return }
        let store = self.store
        let (number, id) = (pinned.artifact.number, pinned.artifact.id)
        guard let stillThere = try? await Task.detached { try store.artifact(companyId: companyId, number: number) != nil }.value,
              !stillThere, pinnedArtifact?.artifact.id == id, companyId == selectedCompanyId else { return }
        pinnedArtifact = nil
        if selectedArtifactId == id {
            selectedArtifactId = nil
            artifactNotice = Self.artifactDeletedNotice
        }
        phoneFrameOverride[id] = nil
    }

    /// Owner only: removes the artifact's row, memory doc and copy (`Store.deleteArtifact`). The selection and the phone-frame
    /// choice go only once the delete went through; a refusal leaves them as they were.
    public func deleteArtifact(_ a: Artifact) async {
        let deleted = await ownerWrite("delete the artifact") { store in
            try store.deleteArtifact(id: a.id, by: .owner)
            return true
        }
        guard deleted == true else { return }
        if selectedArtifactId == a.id { selectedArtifactId = nil }
        if pinnedArtifact?.artifact.id == a.id { pinnedArtifact = nil }
        artifactNotice = nil
        phoneFrameOverride[a.id] = nil
    }

    /// Whether a video artifact sits in the phone frame: the owner's override for it, else what `VideoLayout` detected.
    public func phoneFrame(for artifactId: String, detected: VideoLayout) -> Bool {
        phoneFrameOverride[artifactId] ?? (detected == .phone)
    }

    /// The owner's "PHONE FRAME" toggle for one artifact (kept until the company changes).
    public func setPhoneFrame(_ on: Bool, artifactId: String) { phoneFrameOverride[artifactId] = on }

    // MARK: OpenAPI (the one parser the model runs)

    /// The production parser: the engine's copy read through `PreviewLog.openAPICopy` (the hardened walk, ≤ `OpenAPISummary.maxBytes`)
    /// and summarised, under `RendererCaps.parse`'s timeout. Nil when there is no readable OpenAPI document.
    public static let defaultOpenAPIParser: @Sendable (OpenAPICopy) async throws -> [OpenAPIOperation]? = { copy in
        try await RendererCaps.parse {
            PreviewLog.openAPICopy(copy.layout, name: copy.name, maxBytes: OpenAPISummary.maxBytes).flatMap(OpenAPISummary.parse)
        }
    }

    /// Parses the engine's OpenAPI copy of every running backend whose copy the cache has not seen (keyed by path, commit and
    /// start), and drops the entries of surfaces no longer serving one. Called after each snapshot refresh. A timeout shows as
    /// `.timedOut`; nothing readable as OpenAPI (or any other failure) as `.unreadable`.
    func refreshOpenAPI() {
        let p = snapshot.preview
        openAPICache = openAPICache.filter { p.openAPICopies[$0.key] != nil }
        for (sid, copy) in p.openAPICopies {
            let state = p.states[sid]
            let key = OpenAPIKey(path: copy.url.path, commit: state?.commit, startedAt: state?.startedAt)
            if openAPICache[sid]?.key == key { continue }
            openAPICache[sid] = OpenAPICacheEntry(key: key, result: .loading)
            let companyId = selectedCompanyId
            let parse = openAPIParser
            Task { [weak self] in
                let result: PreviewOpenAPI
                do {
                    result = try await parse(copy).map(PreviewOpenAPI.operations) ?? .unreadable
                } catch RendererError.timedOut {
                    result = .timedOut
                } catch {
                    result = .unreadable
                }
                guard let self, self.selectedCompanyId == companyId, self.openAPICache[sid]?.key == key else { return }
                self.openAPICache[sid]?.result = result
            }
        }
    }

    /// The preview snapshot as the bodies read it: the parsed OpenAPI results laid over it, and a pinned older artifact added
    /// to the list when the snapshot's newest ones do not hold it.
    var previewForBodies: PreviewSnapshot {
        var p = snapshot.preview
        for (sid, entry) in openAPICache { p.openAPI[sid] = entry.result }
        if let pinned = pinnedArtifact, !p.artifacts.contains(where: { $0.id == pinned.artifact.id }) {
            p.artifacts.append(pinned.artifact)
        }
        return p
    }
}

/// An artifact older than the snapshot's newest ones, looked up by number, with its body stat'd off-main.
struct PinnedArtifact: Equatable, Sendable {
    var artifact: Artifact
    var body: FileBody
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
