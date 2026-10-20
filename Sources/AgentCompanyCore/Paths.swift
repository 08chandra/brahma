import Foundation

public struct AgentCoPaths: Sendable, Equatable {
    public let home: URL
    public let workspaces: URL

    public init(home: URL, workspaces: URL) {
        self.home = home
        self.workspaces = workspaces
    }

    public var database: URL { home.appending(path: "agentco.sqlite") }
    public var runDir: URL { home.appending(path: "run", directoryHint: .isDirectory) }

    public static func fromEnvironment() -> AgentCoPaths {
        from(environment: ProcessInfo.processInfo.environment)
    }

    public static func from(environment env: [String: String]) -> AgentCoPaths {
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        let home = env["AGENTCO_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? userHome.appending(path: "Library/Application Support/AgentCompany", directoryHint: .isDirectory)
        let workspaces = env["AGENTCO_WORKSPACES"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? userHome.appending(path: "AgentCompany", directoryHint: .isDirectory)
        return AgentCoPaths(home: home, workspaces: workspaces)
    }
}
