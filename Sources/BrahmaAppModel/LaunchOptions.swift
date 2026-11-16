import Foundation
import BrahmaCore

public enum SelectTarget: Equatable, Sendable {
    case missionControl, activity, agents
    case backlog, board, inbox
    /// Settings › Backups.
    case backups
    /// Inbox › Grants, Inbox › Digest, Company › Settings.
    case grants, digest, companySettings
    /// Work › Releases.
    case releases
    /// Work › Resources (Plan ML).
    case resources
    /// Handbook › PAGES (Plan ML).
    case handbook
    /// Handbook › MEMORY (the memory browser).
    case memory
    /// Work › Budget (Plan ML).
    case budget
    /// `replay:@<handle>[/yyyy-MM-dd]`: People with that agent's REPLAY open on that day (default today, owner's time zone).
    case replayAgent(handle: String, day: String?)
    /// `replay:<KEY>`: the backlog with that item's HISTORY open.
    case replayItem(key: String)
    /// `kb:<path>`: Handbook › PAGES with that page open (the path as given; pages are found case-insensitively).
    case kb(path: String)
    /// `preview:<name>` (a surface, lowercased) or `preview:live`: Mission Control's preview pane on that tab.
    case preview(name: String)
    case item(key: String)
    /// `release:<ref>`: Work › Releases with that release (`R-<n>`) selected in the inspector.
    case release(ref: String)
    /// `ask:<id>`: the Inbox, with that ask called out.
    case ask(id: String)
    case agent(handle: String)
    case channel(name: String)
    case dm(handle: String)
    case search(String)
    case sheet(AppSheet)
    /// Mission Control with the agent map.
    case map

    public init?(_ s: String) {
        switch s {
        case "mission": self = .missionControl
        case "activity": self = .activity
        case "agents": self = .agents
        case "backlog": self = .backlog
        case "board": self = .board
        case "inbox": self = .inbox
        case "backups": self = .backups
        case "grants": self = .grants
        case "digest": self = .digest
        case "settings": self = .companySettings
        case "releases": self = .releases
        case "resources": self = .resources
        case "handbook": self = .handbook
        case "memory": self = .memory
        case "budget": self = .budget
        case "new-item": self = .sheet(.newItem)
        case "hire": self = .sheet(.hire)
        case "new-company": self = .sheet(.newCompany)
        case "map": self = .map
        default:
            guard let colon = s.firstIndex(of: ":") else { return nil }
            let key = s[..<colon]
            let value = String(s[s.index(after: colon)...])
            guard !value.isEmpty else { return nil }
            switch key {
            case "agent": self = .agent(handle: value.lowercased())
            case "item": self = .item(key: value.uppercased())
            case "release": self = .release(ref: value.uppercased())
            case "ask": self = .ask(id: value)
            case "channel": self = .channel(name: value.lowercased())
            case "dm": self = .dm(handle: value.lowercased())
            case "search": self = .search(value)
            case "kb": self = .kb(path: value)
            case "replay":
                guard let target = Self.replay(value) else { return nil }
                self = target
            case "preview": self = .preview(name: value.lowercased())
            default: return nil
            }
        }
    }
}

extension SelectTarget {
    /// `@<handle>[/yyyy-MM-dd]` or `<KEY>`.
    static func replay(_ value: String) -> SelectTarget? {
        guard value.hasPrefix("@") else { return .replayItem(key: value.uppercased()) }
        let parts = value.dropFirst().split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let handle = parts.first, !handle.isEmpty else { return nil }
        guard parts.count == 2 else { return .replayAgent(handle: handle.lowercased(), day: nil) }
        // The day is checked as a calendar date (any zone will do for the form).
        guard Replay.dayInterval(parts[1], tz: TimeZone(identifier: "UTC")!) != nil else { return nil }
        return .replayAgent(handle: handle.lowercased(), day: parts[1])
    }
}

public struct LaunchOptions: Equatable, Sendable {
    public var smokeTest = false
    public var smokeHold: Double = 0
    public var smokeCloseWindow = false
    /// `--smoke-release=<path>`: the smoke hold ends as soon as this file exists (the script creates it once it has seen
    /// what it waits for); `smokeHold` is then only the upper bound.
    public var smokeRelease: String?
    public var snapshotPath: String?
    public var select: SelectTarget?
    /// Company name to select first (snapshots of the work screens use the seeded Initech).
    public var company: String?
    /// `--map-demo`: install the synthetic map company.
    public var mapDemo = false
    /// `--map-demo-agents=<n>`, clamped to `OrgGenerator.range`.
    public var mapDemoAgents = 300
    /// `--map-bench=<seconds>`: run the map benchmark for that long. It implies `--map-demo` (the bench runs on the demo
    /// company's map window), so `--map-demo` need not be given with it.
    public var mapBench: Double?

    public init() {}

    public static func parse(_ args: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 1
        while i < args.count {
            // `--smoke-hold=8` is the form the scripts use: a bare value argument ("8") makes AppKit treat the
            // launch as an open-file request, and SwiftUI then skips the main window.
            if args[i].hasPrefix("--smoke-hold="), let v = Double(args[i].dropFirst("--smoke-hold=".count)) {
                o.smokeHold = v
                i += 1
                continue
            }
            if args[i].hasPrefix("--map-demo-agents=") {
                if let n = Int(args[i].dropFirst("--map-demo-agents=".count)) {
                    o.mapDemoAgents = min(OrgGenerator.range.upperBound, max(OrgGenerator.range.lowerBound, n))
                }
                i += 1
                continue
            }
            if args[i].hasPrefix("--map-bench=") {
                if let v = Double(args[i].dropFirst("--map-bench=".count)), v.isFinite, v > 0 { o.mapBench = v }
                i += 1
                continue
            }
            if args[i].hasPrefix("--smoke-release=") {
                let path = String(args[i].dropFirst("--smoke-release=".count))
                if !path.isEmpty { o.smokeRelease = path }
                i += 1
                continue
            }
            switch args[i] {
            case "--smoke-test": o.smokeTest = true
            case "--smoke-close-window": o.smokeCloseWindow = true
            case "--map-demo": o.mapDemo = true
            case "--smoke-hold":
                if i + 1 < args.count, let v = Double(args[i + 1]) { o.smokeHold = v; i += 1 }
            case "--ui-snapshot":
                if i + 1 < args.count { o.snapshotPath = args[i + 1]; i += 1 }
            case "--company":
                if i + 1 < args.count { o.company = args[i + 1]; i += 1 }
            case "--select":
                if i + 1 < args.count { o.select = SelectTarget(args[i + 1]); i += 1 }
            default: break
            }
            i += 1
        }
        return o
    }
}
