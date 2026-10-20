import Foundation

public struct BrahmaPaths: Sendable, Equatable {
    public let home: URL
    public let workspaces: URL

    public init(home: URL, workspaces: URL) {
        self.home = home
        self.workspaces = workspaces
    }

    public var database: URL { home.appending(path: "brahma.sqlite") }
    public var runDir: URL { home.appending(path: "run", directoryHint: .isDirectory) }

    public static func fromEnvironment() -> BrahmaPaths {
        from(environment: ProcessInfo.processInfo.environment)
    }

    public static func from(environment env: [String: String]) -> BrahmaPaths {
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        let home = env["BRAHMA_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? userHome.appending(path: "Library/Application Support/Brahma", directoryHint: .isDirectory)
        let workspaces = env["BRAHMA_WORKSPACES"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? userHome.appending(path: "Brahma", directoryHint: .isDirectory)
        return BrahmaPaths(home: home, workspaces: workspaces)
    }
}
