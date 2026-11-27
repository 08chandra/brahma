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
    /// `<home>/run/exports/<runId>`: the engine-private, `.git`-free export a merge check runs in (`GitWorkspace.exportPath`).
    public func exportDir(runId: String) -> URL { runDir.appending(path: "exports/\(runId)", directoryHint: .isDirectory) }
    /// `<home>/run/checkouts/<runId>`: the engine-private detached checkout a submission's check runs in
    /// (`GitWorkspace.checkoutPath`).
    public func checkoutDir(runId: String) -> URL { runDir.appending(path: "checkouts/\(runId)", directoryHint: .isDirectory) }

    /// `<home>/run/releases`: every company's engine-only deploy folders (`ReleaseLayout`), outside every workspace.
    public var releasesDir: URL { runDir.appending(path: "releases", directoryHint: .isDirectory) }

    /// `<home>/run/.sentinel`: the file whose readability tells the agent shell prefix the sandbox is not active (Task 1b).
    public var sentinel: URL { runDir.appending(path: ".sentinel") }

    /// `<home>/extensions`: the extension store (`store/<id>/<hash12>`), its import staging area and its state.
    public struct ExtensionDirs: Sendable, Equatable {
        public let root: URL
        public var store: URL { root.appending(path: "store", directoryHint: .isDirectory) }
        public var staging: URL { root.appending(path: "staging", directoryHint: .isDirectory) }
        public var state: URL { root.appending(path: "state", directoryHint: .isDirectory) }
    }
    public var extensionsDir: ExtensionDirs { ExtensionDirs(root: home.appending(path: "extensions", directoryHint: .isDirectory)) }

    /// `<home>/tmp`: where the engine stages temporary files (snapshot, export and restore staging). 0700 directory, 0600 files;
    /// never the system temp directory. Created on demand by `ensureTmpDir()`.
    public var tmpDir: URL { home.appending(path: "tmp", directoryHint: .isDirectory) }
    /// `<home>/backups`: every backup the engine makes (DB snapshots, repo bundles; later the data-home snapshots).
    public var backupsDir: URL { home.appending(path: "backups", directoryHint: .isDirectory) }
    /// Verified DB snapshots (`BackupService.snapshot`).
    public var dbBackups: URL { backupsDir.appending(path: "db", directoryHint: .isDirectory) }
    /// Per-company git bundles (`repoBackups/<companyId>/<yyyyMMdd>.bundle`).
    public var repoBackups: URL { backupsDir.appending(path: "repos", directoryHint: .isDirectory) }

    /// `<home>/transcripts/<companyId>/<agentId>/<sessionId>/<turnId>.jsonl.<zst|gz>`: the redacted, compressed record of every
    /// turn (`TranscriptCapture`). Part of the data-home backup set.
    public var transcriptsDir: URL { home.appending(path: "transcripts", directoryHint: .isDirectory) }
    /// `<home>/archive/<companySlug>/`: the company archive Memory-lite writes (notes and SQLite files). Part of the backup set.
    public var archiveDir: URL { home.appending(path: "archive", directoryHint: .isDirectory) }
    /// Data-home snapshots (`HomeSnapshot`): `<backups>/home/home-<stamp>/{tree,MANIFEST.json}`.
    public var homeSnapshots: URL { backupsDir.appending(path: "home", directoryHint: .isDirectory) }

    /// `<home>/vault`: the engine-only store of owner resources (`ContentVault`), outside every workspace. 0700.
    public var vaultDir: URL { home.appending(path: "vault", directoryHint: .isDirectory) }
    /// `<home>/vault/<companyId>`: one company's vault root (`resources/F-<n>.<ext>` below it). 0700.
    public func vaultDir(companyId: String) -> URL { vaultDir.appending(path: companyId, directoryHint: .isDirectory) }

    /// Creates `url` (and parents) as a 0700 directory, and tightens an existing one.
    public static func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(url.path, 0o700)
    }

    @discardableResult
    public func ensureTmpDir() throws -> URL {
        try Self.ensurePrivateDirectory(tmpDir)
        return tmpDir
    }

    public var packsDir: URL { home.appending(path: "packs", directoryHint: .isDirectory) }
    /// Not used for checks: their saved scripts live in the workspace under `.brahma/checks` (`CheckPaths`), submission
    /// checkouts under `run/checkouts` (`checkoutDir(runId:)`) and merge-check exports under `run/exports` (`exportDir(runId:)`).
    public var checksDir: URL { home.appending(path: "checks", directoryHint: .isDirectory) }
    public func companyDir(_ id: String) -> URL { home.appending(path: "companies/\(id)", directoryHint: .isDirectory) }

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

extension ToolPaths {
    /// The engine's tools (B9, spec §6.5), resolved once from this process's `PATH` with every company workspace and the data
    /// home (and the default workspaces directory) as forbidden roots, and installed as `ToolPaths.engine()`: the
    /// orchestrator at its start, the CLI when it opens the store, the app at launch and again once the login shell's `PATH`
    /// is in. Until one of them ran, nothing is looked up (Ruling S-c1: `ToolPathsError.notInstalled`).
    @discardableResult
    public static func installForEngine(paths: BrahmaPaths, workspacePaths: [String],
                                        path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> Result<ToolPaths, ToolPathsError> {
        install(forbiddenRoots: [paths.home, paths.workspaces] + workspacePaths.map { URL(fileURLWithPath: $0, isDirectory: true) },
                path: path)
    }

    /// `brahma mcp`'s tools (Ruling S5-4): only the git the engine passed (`--git`), re-checked against the data home, the
    /// database's own home, the workspaces directory and the company's workspace (`installFromEngine`). No git given, no
    /// company workspace known, or a refused one: every git of the server refuses (`gitMissing`); never a `PATH` walk.
    @discardableResult
    public static func installForMCPServer(git: String?, paths: BrahmaPaths, databaseHome: URL,
                                           companyWorkspace: String?) -> Result<ToolPaths, ToolPathsError> {
        let roots = [paths.home, databaseHome, paths.workspaces] + (companyWorkspace.map { [URL(fileURLWithPath: $0, isDirectory: true)] } ?? [])
        return installFromEngine(git: companyWorkspace == nil ? nil : git, forbiddenRoots: roots)
    }
}
