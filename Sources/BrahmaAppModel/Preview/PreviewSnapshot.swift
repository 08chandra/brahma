import Foundation
import BrahmaCore

/// The selected company's preview surfaces, their engine states and the live site (Plan L Task 10), read off-main with the
/// snapshot. Log tails are read here too (only for building, starting and failed surfaces), so no view reads a file.
public struct PreviewSnapshot: Equatable, Sendable {
    public var surfaces: [PreviewSurface]
    public var states: [String: PreviewState]
    /// `productionURL` of the latest deployed release.
    public var live: URL?
    /// That release's ref (`R-<n>`): what the LIVE tab says built it.
    public var liveRef: String?
    /// Surface id → the handle of whoever set it ("owner" for the owner).
    public var setBy: [String: String] = [:]
    /// A state's `logPath` → the last `PreviewBodies.logLines` lines of that surface's log (agent-controlled text).
    public var logTails: [String: [String]] = [:]

    public static let empty = PreviewSnapshot(surfaces: [], states: [:], live: nil, liveRef: nil)

    public static func load(store: Store, company: Company) throws -> PreviewSnapshot {
        var p = PreviewSnapshot.empty
        p.surfaces = try store.previewSurfaces(companyId: company.id)
        p.states = try store.previewStates(companyId: company.id)
        let names = Dictionary(try store.agents(companyId: company.id).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for s in p.surfaces { p.setBy[s.id] = s.setById == "owner" ? "owner" : names[s.setById] ?? s.setById }
        if let latest = try store.releases(companyId: company.id, limit: 50).first(where: { $0.status == .deployed }),
           let url = latest.productionURL.flatMap(URL.init(string:)) {
            p.live = url
            p.liveRef = latest.ref
        }
        // Read through the core's hardened reader (`PreviewLog.tail`: EngineFiles, no links, no hard links), by surface name.
        let layout = EngineLayout(workspace: URL(fileURLWithPath: company.workspacePath, isDirectory: true))
        for s in p.surfaces {
            guard let state = p.states[s.id], [.building, .starting, .failed].contains(state.status), let path = state.logPath else { continue }
            p.logTails[path] = PreviewLog.tail(layout, name: s.name, lines: PreviewBodies.logLines)
        }
        return p
    }
}
