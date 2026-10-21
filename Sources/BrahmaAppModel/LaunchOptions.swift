import Foundation

public enum SelectTarget: Equatable, Sendable {
    case missionControl, activity, agents
    case agent(handle: String)
    case channel(name: String)
    case dm(handle: String)
    case search(String)
    case sheet(AppSheet)

    public init?(_ s: String) {
        switch s {
        case "mission": self = .missionControl
        case "activity": self = .activity
        case "agents": self = .agents
        case "hire": self = .sheet(.hire)
        case "new-company": self = .sheet(.newCompany)
        default:
            guard let colon = s.firstIndex(of: ":") else { return nil }
            let key = s[..<colon]
            let value = String(s[s.index(after: colon)...])
            guard !value.isEmpty else { return nil }
            switch key {
            case "agent": self = .agent(handle: value.lowercased())
            case "channel": self = .channel(name: value.lowercased())
            case "dm": self = .dm(handle: value.lowercased())
            case "search": self = .search(value)
            default: return nil
            }
        }
    }
}

public struct LaunchOptions: Equatable, Sendable {
    public var smokeTest = false
    public var smokeHold: Double = 0
    public var smokeCloseWindow = false
    public var snapshotPath: String?
    public var select: SelectTarget?

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
            switch args[i] {
            case "--smoke-test": o.smokeTest = true
            case "--smoke-close-window": o.smokeCloseWindow = true
            case "--smoke-hold":
                if i + 1 < args.count, let v = Double(args[i + 1]) { o.smokeHold = v; i += 1 }
            case "--ui-snapshot":
                if i + 1 < args.count { o.snapshotPath = args[i + 1]; i += 1 }
            case "--select":
                if i + 1 < args.count { o.select = SelectTarget(args[i + 1]); i += 1 }
            default: break
            }
            i += 1
        }
        return o
    }
}
