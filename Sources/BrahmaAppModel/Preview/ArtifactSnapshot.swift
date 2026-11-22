import Foundation
import BrahmaCore

/// The 4a half of `PreviewSnapshot.load` (Task 8b): the company's artifacts and their file bodies, the latest sprint demo, the
/// output tail of a ran CLI demo, a running backend's log tail and the engine's OpenAPI copies to parse. Read off-main with the
/// snapshot, through the core's hardened readers; the OpenAPI copies are only located here and parsed by the model
/// (`AppModel.refreshOpenAPI`, through `RendererCaps.parse`).
extension PreviewSnapshot {
    /// How many sprints back the snapshot looks for a demo.
    static let demoSprintsSearched = 3

    /// Whether anything (a file, a link, a directory) sits at `url`; nothing is followed or read.
    static func entryExists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    mutating func loadArtifacts(store: Store, company: Company, layout: EngineLayout) throws {
        workspace = layout.workspace
        artifacts = try store.artifacts(companyId: company.id)
        for a in artifacts { fileBodies[a.id] = PreviewBodies.fileBody(a, workspace: layout.workspace) }
        for sprint in try store.sprints(companyId: company.id).reversed().prefix(Self.demoSprintsSearched) {
            let found = try store.previewDemos(sprintId: sprint.id)
            if !found.isEmpty {
                demos = found
                break
            }
        }
        for s in surfaces {
            guard let state = states[s.id], let kind = s.previewKind else { continue }
            switch (kind, state.status) {
            case (.cli, .ran):
                if let path = state.outputPath { logTails[path] = PreviewLog.outputTail(layout, name: s.name, lines: PreviewBodies.terminalLines) }
            case (.backend, .running):
                if let path = state.logPath { logTails[path] = PreviewLog.tail(layout, name: s.name, lines: PreviewBodies.logLines) }
                // Located here (an lstat by path: any entry at the copy's name, a planted link included, so the hardened read
                // can refuse it and the body can say the copy couldn't be read); read by the model through `PreviewLog.openAPICopy`.
                if Self.entryExists(layout.previewOpenAPI(name: s.name)) {
                    openAPICopies[s.id] = OpenAPICopy(layout: layout, name: s.name)
                }
            default:
                continue
            }
        }
    }
}
