import Foundation
import GRDB

/// The hosting providers a company can deploy to. Cloudflare Pages is the default.
public enum HostingProviderID: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case cloudflarePages = "cloudflare-pages"
    case vercel

    public var title: String {
        switch self {
        case .cloudflarePages: "Cloudflare Pages"
        case .vercel: "Vercel"
        }
    }

    public static let `default`: HostingProviderID = .cloudflarePages
}

/// One company's hosting (table `hosting`, migration `vL-hosting`). The owner sets the provider, project, account and
/// production URL (`Store.setHosting`); an ops agent sets the build, output folder, smoke requests and expected text
/// (`Store.setDeployConfig`). `build`, `outputDir`, `smoke` and `expectText` are agent-written. The provider token is never
/// here: it is the company secret named by the adapter's `tokenSecret`, read only into the deploy step's environment.
public struct HostingSettings: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "hosting"

    public var companyId: String
    public var provider: HostingProviderID
    public var project: String
    /// Cloudflare: the account ID (`CLOUDFLARE_ACCOUNT_ID`). Vercel: the team or personal account ID (`VERCEL_ORG_ID`, PR-15).
    public var accountId: String?
    public var productionURL: String?
    /// Set by the owner in the provider's dashboard (the hosting human task); no CLI configures it.
    public var customDomain: String?
    public var build: String?
    public var outputDir: String?
    public var smoke: [SmokeRequest]
    public var expectText: String?
    public var configuredById: String?
    public var updatedAt: Date

    public init(companyId: String, provider: HostingProviderID = .default, project: String, accountId: String? = nil,
                productionURL: String? = nil, customDomain: String? = nil, build: String? = nil, outputDir: String? = nil,
                smoke: [SmokeRequest] = [], expectText: String? = nil, configuredById: String? = nil, updatedAt: Date) {
        self.companyId = companyId; self.provider = provider; self.project = project; self.accountId = accountId
        self.productionURL = productionURL; self.customDomain = customDomain; self.build = build; self.outputDir = outputDir
        self.smoke = smoke; self.expectText = expectText; self.configuredById = configuredById; self.updatedAt = updatedAt
    }

    public static let maxBuild = 2000
    public static let maxExpectText = 200

    static let projectMessage = "project names are 2–58 lowercase letters, digits and dashes"
    static let outputDirMessage = "output_dir must be a subfolder of the repo like dist or site/public (no dot folders, .git, .brahma or node_modules)"
    static let buildMessage = "build must be 1–2000 characters"
    static let expectTextMessage = "expect_text must be at most 200 characters"
    static let productionURLMessage = "production URL must start with https://"
    static let accountIdMessage = "account ID must be 1–64 letters, digits, dashes or underscores"
    static let smokeMessage = "up to 10 smoke requests, each path starting with /"

    /// Throws `WorkError.invalid` with the message for the first rule broken. What a deploy additionally needs (an output
    /// folder; the account ID) is checked by the adapter's `validate`.
    public func validate() throws {
        guard Self.isValidProject(project) else { throw WorkError.invalid(Self.projectMessage) }
        if let outputDir { guard Self.isValidOutputDir(outputDir) else { throw WorkError.invalid(Self.outputDirMessage) } }
        if let build {
            guard !build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, build.count <= Self.maxBuild else {
                throw WorkError.invalid(Self.buildMessage)
            }
        }
        if let expectText { guard expectText.count <= Self.maxExpectText else { throw WorkError.invalid(Self.expectTextMessage) } }
        if let productionURL { guard Self.isValidProductionURL(productionURL) else { throw WorkError.invalid(Self.productionURLMessage) } }
        if let accountId { guard Self.isValidAccountId(accountId) else { throw WorkError.invalid(Self.accountIdMessage) } }
        guard smoke.count <= SmokeRequest.max, smoke.allSatisfy({ SmokeRequest.isSmokePath($0.path) }) else {
            throw WorkError.invalid(Self.smokeMessage)
        }
    }

    /// `^[a-z0-9][a-z0-9-]{0,56}[a-z0-9]$`.
    public static func isValidProject(_ s: String) -> Bool {
        s.range(of: "^[a-z0-9][a-z0-9-]{0,56}[a-z0-9]$", options: .regularExpression) != nil
    }

    /// Builder-check 4: `^[A-Za-z0-9_][A-Za-z0-9_./-]*$`, no `..` or `//`, and no path component that is empty, `.`, starts
    /// with `.`, or is `.git`, `.brahma` or `node_modules` (any case: APFS is case-insensitive). So it is always a real
    /// subfolder of the repo, never the repo itself, a dot folder or the dependency tree.
    public static func isValidOutputDir(_ s: String) -> Bool {
        guard s.count <= 255, s.range(of: "^[A-Za-z0-9_][A-Za-z0-9_./-]*$", options: .regularExpression) != nil,
              !s.contains(".."), !s.contains("//") else { return false }
        let banned: Set<String> = [".git", ".brahma", "node_modules"]
        for part in s.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty || part == "." || part.hasPrefix(".") || banned.contains(part.lowercased()) { return false }
        }
        return true
    }

    /// `https://<host>[...]`, with a host, no user or password, and no spaces or control characters.
    public static func isValidProductionURL(_ s: String) -> Bool {
        guard s.count <= 2048, s.lowercased().hasPrefix("https://"),
              !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespaces.contains($0) }),
              let c = URLComponents(string: s), c.scheme?.lowercased() == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil else { return false }
        return true
    }

    /// `^[A-Za-z0-9_-]{1,64}$`: it goes into the deploy step's environment.
    public static func isValidAccountId(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil
    }
}

/// One engine-composed command of a deploy or rollback. `okIfOutputContains`: a non-zero exit still counts as success when
/// the output contains this text (creating a project that already exists).
public struct DeployStep: Codable, Equatable, Sendable {
    /// A rollback step labelled so confirms its target with the token before any later step runs (Vercel's `vercel inspect
    /// <previous deploy URL>`, Task 8): the executor requires exit 0 and `HostingAdapter.verifiesDeployment`, else it fails
    /// closed with nothing rolled back.
    public static let verifyLabel = "verify"

    public var label: String
    public var argv: [String]
    public var okIfOutputContains: String?

    public init(label: String, argv: [String], okIfOutputContains: String? = nil) {
        self.label = label; self.argv = argv; self.okIfOutputContains = okIfOutputContains
    }
}

/// Exactly what the engine will run for a deploy or a rollback, rendered at propose time for the owner's approval and again
/// by the executor, which refuses to run when the hash differs. Every argv is engine-composed: no agent text is ever a shell
/// command here (the agent's `build` runs earlier, sandboxed, in the release build step). The token is never in it: it is
/// passed only as the `tokenSecret` variable of the step's environment.
public struct DeployPlan: Codable, Equatable, Sendable {
    public var steps: [DeployStep]
    /// Export-relative folders the stager copies into `upload/`.
    public var stageFrom: [String]
    /// Absolute: the directory every step runs in.
    public var cwdPath: String
    /// The hosts the steps' sandbox may reach (`.outbound(allow:)`).
    public var network: [String]
    /// The name of the company secret put in the steps' environment under the same name (never in argv).
    public var tokenSecret: String
    /// The adapter's fixed, non-secret environment, added after `ChildEnvironment.make` (PR-3).
    public var env: [String: String]
    public var build: String?
    public var outputDir: String?
    /// One line per step (`ShellQuote.joinArgv`); the token would appear only as `"$NAME"`.
    public var display: String
    /// The token-holding step that confirms a deploy URL belongs to the configured project before the engine stores it (the
    /// Task 7 ruling for Vercel): its argv with `deployURLPlaceholder` as the one element the URL replaces. Nil: the URL the
    /// adapter read from the deploy's stdout is trusted as it is. Shown as the last line of `display`.
    public var verify: [String]?
    /// `StableHash` of display, stageFrom, cwdPath, build and outputDir (builder-checks 5, 6), and also of the steps themselves
    /// (their `okIfOutputContains` decides success), the network, the token's name, the fixed env and the verify step, so no
    /// part of a stored plan can change without the hash changing.
    public var hash: String

    /// The element of `verify` the deploy URL replaces.
    public static let deployURLPlaceholder = "{deploy-url}"

    public init(steps: [DeployStep], stageFrom: [String], cwdPath: String, network: [String], tokenSecret: String,
                env: [String: String] = [:], build: String?, outputDir: String?, verify: [String]? = nil) throws {
        guard cwdPath.hasPrefix("/") else { throw WorkError.invalid("a deploy step must run in an absolute directory") }
        if let verify { guard verify.filter({ $0 == Self.deployURLPlaceholder }).count == 1 else {
            throw WorkError.invalid("a verify step names the deploy URL exactly once")
        } }
        self.steps = steps; self.stageFrom = stageFrom; self.cwdPath = cwdPath; self.network = network
        self.tokenSecret = tokenSecret; self.env = env; self.build = build; self.outputDir = outputDir; self.verify = verify
        display = (steps.map(\.argv) + (verify.map { [$0] } ?? [])).map { ShellQuote.joinArgv($0, rawRefs: [tokenSecret]) }
            .joined(separator: "\n")
        hash = ""
        hash = computedHash
    }

    /// The verify step's argv for `url`, or nil when the plan has none.
    public func verifyArgv(url: URL) -> [String]? {
        verify?.map { $0 == Self.deployURLPlaceholder ? url.absoluteString : $0 }
    }

    /// The hash of every part but `hash`, JSON-encoded with sorted keys so no two different plans can join into the same text.
    /// A plan without a verify step hashes as it did before the step existed (the key is left out when nil).
    public var computedHash: String {
        struct Parts: Encodable {
            let steps: [DeployStep], display: String, stageFrom: [String], cwdPath: String, network: [String], tokenSecret: String
            let env: [String: String], build: String?, outputDir: String?, verify: [String]?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let parts = Parts(steps: steps, display: display, stageFrom: stageFrom, cwdPath: cwdPath, network: network,
                          tokenSecret: tokenSecret, env: env, build: build, outputDir: outputDir, verify: verify)
        // Encoding plain strings and arrays cannot fail; were it to, the hash would still differ from any real plan's.
        let data = (try? encoder.encode(parts)) ?? Data("unencodable".utf8)
        return StableHash.fnv1a64(data)
    }

    /// Whether `hash` still matches the plan's parts (a stored plan that was edited does not).
    public var hashIsCurrent: Bool { hash == computedHash }
}

/// What an adapter composes a plan from. For a rollback, `settings`, `commit` and `version` are the release being restored.
/// Every place is under the company's data-home `ReleaseLayout` (`releaseRoot`), never in a workspace (I3); `validate`
/// refuses anything else.
public struct DeployInput: Sendable {
    public var settings: HostingSettings
    public var commit: String
    public var version: String
    /// `ReleaseLayout.root`: the deploy's `GIT_CEILING_DIRECTORIES` and the boundary of `ProviderConfigCheck`.
    public var releaseRoot: URL
    /// `ReleaseLayout.releaseDir(n)`.
    public var releaseDir: URL
    /// `ReleaseLayout.deployTools(cli:)`: the engine-installed provider CLI (`node_modules/.bin/<cli>`).
    public var deployTools: URL
    /// The previous deployed release's `upload/` (Cloudflare rollback).
    public var previousUpload: URL?
    /// The previous deployed release's deploy URL (Vercel rollback).
    public var previousDeployURL: String?
    /// `ReleaseLayout.placeholderDir` (`Placeholder.write`).
    public var placeholderDir: URL
    /// Whether the commit's tree has a `functions` folder (`GitWorkspace.treeHasDirectory`, PR-24): decided from the commit,
    /// never from the export, so the plan is the same at propose time and when the executor renders it again.
    public var functionsInCommit: Bool

    public init(settings: HostingSettings, commit: String, version: String, releaseRoot: URL, releaseDir: URL, deployTools: URL,
                previousUpload: URL? = nil, previousDeployURL: String? = nil, placeholderDir: URL, functionsInCommit: Bool = false) {
        self.settings = settings; self.commit = commit; self.version = version; self.releaseRoot = releaseRoot
        self.releaseDir = releaseDir; self.deployTools = deployTools; self.previousUpload = previousUpload
        self.previousDeployURL = previousDeployURL; self.placeholderDir = placeholderDir; self.functionsInCommit = functionsInCommit
    }

    /// The places of release `number` of `layout`, with the adapter's tools.
    public init(settings: HostingSettings, commit: String, version: String, layout: ReleaseLayout, release number: Int, cli: String,
                previousUpload: URL? = nil, previousDeployURL: String? = nil, functionsInCommit: Bool = false) {
        self.init(settings: settings, commit: commit, version: version, releaseRoot: layout.root,
                  releaseDir: layout.releaseDir(number), deployTools: layout.deployTools(cli: cli), previousUpload: previousUpload,
                  previousDeployURL: previousDeployURL, placeholderDir: layout.placeholderDir, functionsInCommit: functionsInCommit)
    }

    /// The commit and version every adapter puts in argv, and every place inside `releaseRoot`.
    func validate() throws {
        guard commit.range(of: "^[0-9a-f]{7,64}$", options: .regularExpression) != nil else { throw WorkError.invalid("invalid commit") }
        guard version.range(of: "^[0-9A-Za-z][0-9A-Za-z.+-]{0,31}$", options: .regularExpression) != nil else {
            throw WorkError.invalid("invalid release version")
        }
        let root = releaseRoot.standardizedFileURL.path
        guard root.hasPrefix("/"), root != "/" else { throw WorkError.invalid("deploys run under the engine's releases folder") }
        for place in [releaseDir, deployTools, placeholderDir] + (previousUpload.map { [$0] } ?? []) {
            let path = place.standardizedFileURL.path
            guard path.hasPrefix(root + "/"), !place.path.contains("/../") else {
                throw WorkError.invalid("deploys run under the engine's releases folder")
            }
        }
    }

    /// `GIT_CEILING_DIRECTORIES`: the release root (and its resolved form when that differs), so git started by a provider
    /// CLI never discovers a repository above the deploy folder.
    var gitCeiling: String {
        let plain = releaseRoot.standardizedFileURL.path
        let resolved = releaseRoot.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved == plain ? plain : plain + ":" + resolved
    }

    /// `releaseDir/<name>`, absolute.
    func inRelease(_ name: String) -> String { releaseDir.appending(path: name, directoryHint: .isDirectory).path }

    /// `<deployTools>/node_modules/.bin/<name>`: the engine-installed binary (builder-check 2: never `npx`).
    func bin(_ name: String) -> String { deployTools.appending(path: "node_modules/.bin/\(name)", directoryHint: .notDirectory).path }
}

/// The executor's last check before a deploy or rollback step runs with the token (Task 7 calls it; I3): no provider
/// config a CLI would pick up may sit in the step's directory or above it. Fails closed.
public enum ProviderConfigCheck {
    /// What wrangler reads from its directory or any ancestor.
    public static let wranglerConfigs = ["wrangler.toml", "wrangler.json", "wrangler.jsonc"]

    /// Found only between the deploy folder and the release root: git stops at `GIT_CEILING_DIRECTORIES` above it, and the
    /// Vercel CLI reads `.vercel` only in its folder (and at a git root, which the ceiling keeps inside the release root).
    public static let boundedNames = [".git", ".vercel"]

    /// Throws when `cwd` is not inside `boundary`, when any of `names` exists (as anything, a link included) in `cwd` or any
    /// ancestor up to the file system root (wrangler searches that far), or when one of `boundedNames` exists in `cwd` or an
    /// ancestor up to and including `boundary`. Nothing is followed or read.
    public static func check(cwd: String, boundary: URL, names: [String]) throws {
        let root = boundary.standardizedFileURL.path
        let start = URL(fileURLWithPath: cwd).standardizedFileURL.path
        guard cwd.hasPrefix("/"), !cwd.contains("/../"), start == root || start.hasPrefix(root + "/") else {
            throw WorkError.invalid("the deploy folder \(cwd) is outside the engine's releases folder")
        }
        var dir = URL(fileURLWithPath: start, isDirectory: true)
        var insideBoundary = true
        while true {
            var found = names.filter { exists(dir.appending(path: $0).path) }
            if insideBoundary { found += boundedNames.filter { exists(dir.appending(path: $0).path) } }
            if let name = found.first {
                throw WorkError.invalid("refusing to deploy: \(dir.appending(path: name).path) would configure the provider CLI")
            }
            if dir.path == root { insideBoundary = false }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path || dir.path == "/" { return }
            dir = parent
        }
    }

    static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }
}

/// Shell quoting for displaying argv (the steps are executed as argv, never through a shell).
public enum ShellQuote {
    /// `s` as is when it matches `^[A-Za-z0-9_./:=@+-]+$`, else single-quoted (`'` becomes `'\''`).
    public static func quote(_ s: String) -> String {
        if s.range(of: "^[A-Za-z0-9_./:=@+-]+$", options: .regularExpression) != nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The argv as one shell line. Only an element equal to `"$<name>"` with `<name>` in `rawRefs` is emitted double-quoted
    /// and expandable; every other `$` is single-quoted (builder-check 4). Executed commands pass `rawRefs: []` (PR-11):
    /// tokens are env-only.
    public static func joinArgv(_ argv: [String], rawRefs: [String]) -> String {
        argv.map { arg in
            if arg.hasPrefix("$"), rawRefs.contains(String(arg.dropFirst())), SecretName.isValid(String(arg.dropFirst())) {
                return "\"\(arg)\""
            }
            return quote(arg)
        }.joined(separator: " ")
    }
}

/// A hosting provider: composes deploy and rollback plans from engine records, and reads the deploy's output. Adapters never
/// run anything themselves; the release executor runs their plans under `SandboxedRunner` with `.outbound(allow: network)`.
public protocol HostingAdapter: Sendable {
    var id: HostingProviderID { get }
    /// The company secret holding the provider token; put only in the deploy step's environment.
    var tokenSecret: String { get }
    /// The exact npm package the engine installs (token-free) into `deployTools(cli:)`: `"wrangler@<exact>"`.
    var cli: String { get }
    /// The hosts the token-free install step may reach.
    var toolNetwork: [String] { get }
    /// The hosts the deploy and rollback steps may reach.
    var network: [String] { get }
    func validate(_ s: HostingSettings) throws
    func deployPlan(_ i: DeployInput) throws -> DeployPlan
    /// The previous release, else the placeholder.
    func rollbackPlan(_ i: DeployInput) throws -> DeployPlan
    /// The deploy URL, read from the deploy step's STDOUT only (never stderr, never streamed build logs).
    func deployURL(fromOutput: String, settings: HostingSettings) -> URL?
    func smokeBase(_ s: HostingSettings, deployURL: URL?) -> URL?
    /// The provider config files `ProviderConfigCheck` refuses in or above a deploy folder, up to the file system root
    /// (`.git` and `.vercel` are always refused up to the release root).
    var providerConfigNames: [String] { get }
    /// Whether the output of the plan's verify step (`DeployPlan.verify`) says the deployment belongs to `settings.project`.
    /// Only asked when the plan has a verify step; fail closed (false) on anything it cannot read.
    func verifiesDeployment(output: String, settings: HostingSettings) -> Bool
    /// Why a release on this provider needs the owner's production URL in HOSTING (final-fix2 R2), or nil when it does not.
    /// `Store.proposeDeploy` refuses with it when none is set, and the executor refuses with it again before any token step.
    var productionURLRequired: String? { get }
}

extension HostingAdapter {
    /// The site may be smoked at the verified deploy URL: no production URL needed.
    public var productionURLRequired: String? { nil }

    /// No verify step: nothing to confirm.
    public func verifiesDeployment(output: String, settings: HostingSettings) -> Bool { false }

    /// The executable `cli` installs into `node_modules/.bin`: the package name without its version (and scope).
    public var cliBin: String {
        var name = cli
        if let at = name.lastIndex(of: "@"), at != name.startIndex { name = String(name[..<at]) }
        return name.split(separator: "/").last.map(String.init) ?? name
    }

    /// `ProviderConfigCheck` for a plan of this adapter: what the executor calls before every step (Task 7).
    public func refuseProviderConfig(_ plan: DeployPlan, releaseRoot: URL) throws {
        try ProviderConfigCheck.check(cwd: plan.cwdPath, boundary: releaseRoot, names: providerConfigNames)
    }
}

/// The production adapters. Immutable: tests inject their own lookup (`ReleaseExecutor(adapters:)`,
/// `Store.proposeDeploy(adapters:)`; PR-25), never by changing a shared registry.
public enum HostingAdapters {
    public typealias Lookup = @Sendable (HostingProviderID) -> any HostingAdapter

    /// Every provider's production adapter (computed, never mutable).
    public static var registry: [HostingProviderID: any HostingAdapter] {
        Dictionary(uniqueKeysWithValues: HostingProviderID.allCases.map { ($0, adapter($0)) })
    }

    public static func adapter(_ id: HostingProviderID) -> any HostingAdapter {
        switch id {
        case .cloudflarePages: CloudflarePagesAdapter()
        case .vercel: VercelAdapter()
        }
    }

    public static let production: Lookup = { adapter($0) }

    /// What every adapter checks before composing a plan: the settings' own rules, then an output folder.
    static func validateForDeploy(_ s: HostingSettings) throws {
        try s.validate()
        guard s.outputDir != nil else { throw WorkError.invalid("no output_dir is set yet; set it with set_deploy_config") }
    }
}

/// What a company still needs before it can deploy.
public struct HostingReadiness: Codable, Equatable, Sendable {
    /// A hosting row with an output folder.
    public var configured: Bool
    /// The provider token secret is stored.
    public var tokenPresent: Bool
    /// The account ID is set (both providers need it).
    public var accountPresent: Bool
    /// `npm` is on the engine's PATH (the provider CLI is installed with it).
    public var npmPresent: Bool

    public init(configured: Bool, tokenPresent: Bool, accountPresent: Bool, npmPresent: Bool) {
        self.configured = configured; self.tokenPresent = tokenPresent; self.accountPresent = accountPresent
        self.npmPresent = npmPresent
    }

    public var ready: Bool { configured && tokenPresent && accountPresent && npmPresent }

    /// Whether an executable `npm` is in one of `PATH`'s directories, or the usual Homebrew and /usr/local places.
    public static func npmOnPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        return dirs.contains { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: "\($0)/npm") }
    }
}
