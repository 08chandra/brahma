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
    /// Log path → its last `PreviewBodies.logLines` lines (agent-controlled text).
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
        for state in p.states.values where [.building, .starting, .failed].contains(state.status) {
            if let path = state.logPath { p.logTails[path] = LogTail.read(URL(fileURLWithPath: path), lines: PreviewBodies.logLines) }
        }
        return p
    }
}

/// The last lines of a preview log: only its last 64 KB are read, and a missing or unreadable file is no lines. A symlink
/// is not followed.
enum LogTail {
    static let maxBytes: off_t = 64 * 1024

    static func read(_ url: URL, lines: Int) -> [String] {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return [] }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let end = try? handle.seekToEnd() else { return [] }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return [] }
        var all = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if start > 0, !all.isEmpty { all.removeFirst() }  // a partial first line
        if all.last == "" { all.removeLast() }
        return Array(all.suffix(lines))
    }
}
