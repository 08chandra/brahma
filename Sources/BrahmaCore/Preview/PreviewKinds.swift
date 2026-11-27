import Foundation

// Plan 4a Task 4: previews beyond the web, on L's engine. The kinds' validation rules, their sandbox policies, the demo
// capture, the Apple protocols (implemented in Task 7) and the default adapter table (Tasks 5 and 7 register theirs).

extension PreviewKind {
    /// The kinds that answer on a loopback URL (and so get an allocated port); every other kind gets port 0 (`PORT=0`).
    public var usesURL: Bool { self == .web || self == .backend }
}

extension PreviewSurface {
    static let pathRefusal = "paths must be relative to the repo root"
    static let bundleIdRefusal = "bundle_id may contain letters, digits, '.' and '-'"
    static let deviceRefusal = "device names are 1–64 letters, digits, spaces and ()._-"
    static let kindRefusal = "kind must be web, backend, cli, ios or macos"
    /// The longest `app_path` or `openapi_path`.
    static let maxPath = 1024

    /// The kind and the fields it needs: web and backend `run` and `url`, cli `demo`, ios `build`, `app_path` and
    /// `bundle_id`, macos `build` and `app_path`; `artifact` is never a surface (artifacts are published).
    func validateKind() throws {
        guard let kind = previewKind else { throw WorkError.invalid(Self.kindRefusal) }
        switch kind {
        case .web:
            guard run != nil, url != nil else { throw WorkError.invalid("a web preview needs run and url") }
        case .backend:
            guard run != nil, url != nil else { throw WorkError.invalid("a backend preview needs run and url") }
        case .cli:
            guard demo != nil else { throw WorkError.invalid("a cli preview needs demo") }
        case .ios:
            guard build != nil, appPath != nil, bundleId != nil else {
                throw WorkError.invalid("an ios preview needs build, app_path and bundle_id")
            }
        case .macos:
            guard build != nil, appPath != nil else { throw WorkError.invalid("a macos preview needs build and app_path") }
        case .artifact:
            throw WorkError.invalid("artifacts appear automatically; use publish_artifact")
        }
    }

    /// `app_path` and `openapi_path` relative to the repo root (no leading `/`, no `..` component, no control character or
    /// backslash, 1–1024 characters); `bundle_id` 1–155 of `A-Za-z0-9.-`; `device` 1–64 of `A-Za-z0-9 ()._-`. Checked
    /// character by character (an ICU `$` would also match before a trailing newline).
    func validateAppleFields() throws {
        for path in [appPath, openapiPath].compactMap({ $0 }) where !Self.isRelativePath(path) {
            throw WorkError.invalid(Self.pathRefusal)
        }
        if let bundleId, !Self.only(bundleId, Self.bundleIdCharacters, max: 155) { throw WorkError.invalid(Self.bundleIdRefusal) }
        if let device, !Self.only(device, Self.deviceCharacters, max: 64) { throw WorkError.invalid(Self.deviceRefusal) }
    }

    static let asciiAlphanumerics = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".unicodeScalars)
    static let bundleIdCharacters = asciiAlphanumerics.union(".-".unicodeScalars)
    static let deviceCharacters = asciiAlphanumerics.union(" ()._-".unicodeScalars)

    static func only(_ s: String, _ allowed: Set<Unicode.Scalar>, max: Int) -> Bool {
        let scalars = s.unicodeScalars
        return !scalars.isEmpty && scalars.count <= max && scalars.allSatisfy(allowed.contains)
    }

    static func isRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= maxPath, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}

// MARK: Policies

extension PreviewPolicy {
    /// A one-shot preview command (a CLI's build and demo): writes only its own fresh export `run` (which holds its TMPDIR and,
    /// with the toolchain, its per-run HOME and caches), reads only `run`, and reaches the company's allowed domains only
    /// through the egress proxy; no listening. As L's `server`, neither the logs directory (the engine writes the log and the
    /// output, F1) nor the shared cache (PR-19, and 5-lite's "no writable shared cache at all") is writable, so nothing one
    /// run plants reaches another surface's build or a check. The factory's `.previewOneShot` rule (Plan S Task S7).
    public static func oneShot(_ l: EngineLayout, run: URL, company: Company, principals: PrincipalSet, baseline: SandboxBaseline) -> PolicyDecision {
        decide(.previewOneShot, run: run, company: company, principals: principals, baseline: baseline) { .previewOneShot(run: $0) }
    }

    /// An iOS or macOS build: `oneShot` with the toolchain. Its derived data goes inside the run (`derivedData(run:)`, carried
    /// as `BRAHMA_DERIVED_DATA`; the role guide says to pass `-derivedDataPath`), never in a cache another build reads. The
    /// factory's `.appleBuild` rule.
    public static func appleBuild(_ l: EngineLayout, run: URL, company: Company, principals: PrincipalSet, baseline: SandboxBaseline) -> PolicyDecision {
        decide(.appleBuild, run: run, company: company, principals: principals, baseline: baseline) { .appleBuild(run: $0) }
    }

    /// A built macOS app, running: writes only its own app-data place (`appData`), reads only `run` (its bundle is there),
    /// reaches the allowed domains through the proxy. The place is engine-only (`.brahma/preview` is write-denied to every
    /// turn and in no check's, build's or server's writable set), the engine makes it without following a link before each
    /// start (`prepareAppData`), and the policy names it logically (`Place.logical`), never resolved, so a link the app's
    /// previous run (the one thing that can write there) left at it or on its way fails `SandboxPolicyCheck` instead of
    /// widening the grant (fix round 1, I1). The factory's `.guiApp` rule.
    public static func guiApp(_ l: EngineLayout, run: URL, company: Company, surface: String, principals: PrincipalSet,
                              baseline: SandboxBaseline) -> PolicyDecision {
        decide(.guiApp(surface: surface), run: run, company: company, principals: principals, baseline: baseline) { run in
            let ws = l.workspace.resolvedForSandbox
            let workspace = try Place.verify(ws, kind: .directory, under: ws)
            return .guiApp(run: run, appData: try Place.logical(appData(l, surface: surface), under: workspace))
        }
    }

    /// Where every macOS app's data lives, relative to the workspace (under L's engine-only `.brahma/preview`).
    public static let appDataRelative = ".brahma/preview/apps"

    /// `<resolved workspace>/.brahma/preview/apps/<surface>`: only the workspace is resolved (the owner may keep it behind a
    /// link); every part under it is named as it is, never resolved (a surface name is one safe path component).
    public static func appData(_ l: EngineLayout, surface: String) -> URL {
        l.workspace.resolvedForSandbox.appending(path: "\(appDataRelative)/\(surface)", directoryHint: .notDirectory)
    }

    /// Makes the app-data place before a start: every part a real directory, opened one at a time with `O_NOFOLLOW`
    /// (`EngineFiles`), mode 0700. A link or anything else at the place itself (only the app's previous run can put one
    /// there) is removed by descriptor, never followed, and the directory made again; a link or odd file on a parent
    /// throws (`UnsafeEngineFile`), and the start is refused.
    static func prepareAppData(_ l: EngineLayout, surface: String) throws {
        let relative = "\(appDataRelative)/\(surface)"
        do {
            _ = try EngineFiles.directory(workspace: l.workspace, relative, mode: 0o700)
        } catch is UnsafeEngineFile {
            try EngineFiles.remove(workspace: l.workspace, dir: appDataRelative, name: surface)
            _ = try EngineFiles.directory(workspace: l.workspace, relative, mode: 0o700)
        }
    }

    /// `<run>/.build/DerivedData`: an Apple build's derived data, thrown away with its export.
    public static func derivedData(run: URL) -> URL { run.appending(path: ".build/DerivedData", directoryHint: .isDirectory) }

    static func allowedDomains(_ company: Company) -> [String] {
        CompanyNetwork.scope(company: company, grantDomains: [], grantWebDomains: []).allowedDomains
    }

    /// The route one start of `kind` runs under: its build and command (`policy`), and the long-running app's when that
    /// differs (`appPolicy`), or the owner's Full opt-out for the whole start, or a refusal. web and backend: L's `server` on
    /// `port`; cli: `oneShot`; ios: `appleBuild` (the Simulator runs the app itself, outside any sandbox, behind the owner's
    /// approval); macos: `appleBuild`, then `guiApp`. Plan S Task S7: every one is `SandboxPolicyFactory.decide`.
    static func forKind(_ kind: PreviewKind, layout: EngineLayout, run: URL, company: Company, port: Int, surface: String,
                        principals: PrincipalSet, baseline: SandboxBaseline) -> PreviewDecision {
        let first: PolicyDecision
        var app: PolicyDecision?
        switch kind {
        case .web, .backend: first = server(layout, run: run, company: company, port: port, principals: principals, baseline: baseline)
        case .cli, .artifact: first = oneShot(layout, run: run, company: company, principals: principals, baseline: baseline)
        case .ios: first = appleBuild(layout, run: run, company: company, principals: principals, baseline: baseline)
        case .macos:
            first = appleBuild(layout, run: run, company: company, principals: principals, baseline: baseline)
            app = guiApp(layout, run: run, company: company, surface: surface, principals: principals, baseline: baseline)
        }
        switch (first, app) {
        case (.refused(let why), _), (_, .refused(let why)?): return .refused(why)
        case (.fullOptOut(let optOut), nil), (.fullOptOut(let optOut), .fullOptOut?): return .fullOptOut(optOut)
        case (.sandboxed(let policy), nil): return .sandboxed(policy: policy, app: nil)
        case (.sandboxed(let policy), .sandboxed(let appPolicy)?): return .sandboxed(policy: policy, app: appPolicy)
        case (.fullOptOut, .sandboxed?), (.sandboxed, .fullOptOut?):
            return .refused("the build and the app of one preview were decided differently")
        }
    }
}

/// What one start of a preview runs under (`PreviewPolicy.forKind`).
enum PreviewDecision: Sendable, Equatable {
    case sandboxed(policy: ValidatedPolicy, app: ValidatedPolicy?)
    case fullOptOut(FullOptOut)
    case refused(String)
}

// MARK: Demo

/// What one preview showed for a demo (a sprint review): engine-composed `ok` and `line`, and where any captured output is.
/// `line` may quote agent-controlled text only as the engine composed it.
public struct DemoCapture: Equatable, Sendable {
    public var ok: Bool
    public var line: String
    public var outputPath: String?

    public init(ok: Bool, line: String, outputPath: String? = nil) {
        self.ok = ok; self.line = line; self.outputPath = outputPath
    }
}

// MARK: Apple

/// The iOS Simulator, through `xcrun simctl` (Task 7's `SimctlController`). Engine-fixed argv only.
public protocol SimulatorControlling: Sendable {
    /// Why the Simulator cannot be used on this machine, or nil.
    func availability() -> String?
    /// The engine's own device for `name` (created with `deviceType` when listed); its UDID.
    func ensureDevice(name: String, deviceType: String?) throws -> String
    func boot(_ udid: String) throws
    func install(_ udid: String, app: URL) throws
    func launch(_ udid: String, bundleId: String) throws
    func terminate(_ udid: String, bundleId: String) throws
    func shutdown(_ udid: String) throws
    func screenshot(_ udid: String, to: URL) throws
    /// Shuts down every booted device of the engine's own (`Brahma …`) that an earlier engine left (Task 7, obligation b);
    /// never an owner device. Returns their ids. The default does nothing.
    func shutdownLeftovers() throws -> [String]
}

extension SimulatorControlling {
    public func shutdownLeftovers() throws -> [String] { [] }
}

/// Resolves a built macOS app's executable inside its run (Task 7's `ProcessMacAppLauncher`).
public protocol MacAppLaunching: Sendable {
    func availability() -> String?
    func executable(inApp: URL, run: URL) throws -> URL
}

/// No Simulator here (off macOS, or before Task 7 registers one): every call refuses.
public struct UnavailableSimulator: SimulatorControlling {
    public static let message = "iOS previews need macOS with Xcode"
    public init() {}
    public func availability() -> String? { Self.message }
    public func ensureDevice(name: String, deviceType: String?) throws -> String { throw WorkError.invalid(Self.message) }
    public func boot(_ udid: String) throws { throw WorkError.invalid(Self.message) }
    public func install(_ udid: String, app: URL) throws { throw WorkError.invalid(Self.message) }
    public func launch(_ udid: String, bundleId: String) throws { throw WorkError.invalid(Self.message) }
    public func terminate(_ udid: String, bundleId: String) throws { throw WorkError.invalid(Self.message) }
    public func shutdown(_ udid: String) throws { throw WorkError.invalid(Self.message) }
    public func screenshot(_ udid: String, to: URL) throws { throw WorkError.invalid(Self.message) }
}

/// No macOS app launching here: every call refuses.
public struct UnavailableMacApps: MacAppLaunching {
    public static let message = "macOS app previews need macOS"
    public init() {}
    public func availability() -> String? { Self.message }
    public func executable(inApp: URL, run: URL) throws -> URL { throw WorkError.invalid(Self.message) }
}

// MARK: Adapters

/// The adapters a `PreviewRunner` uses by default, by kind. Plan L's web adapter, Task 5's backend and CLI adapters, Task 7's
/// iOS and macOS adapters (available where `deps.simulator` / `deps.macApps` are). A kind with no adapter is `unavailable`
/// (`PreviewRunner.noAdapterMessage`).
public enum PreviewAdapters {
    public static func defaults(_ deps: PreviewDependencies) -> [PreviewKind: any PreviewAdapter] {
        [.web: WebAdapter(deps: deps), .backend: BackendAdapter(deps: deps), .cli: CLIAdapter(deps: deps),
         .ios: IOSAdapter(deps: deps), .macos: MacAppAdapter(deps: deps)]
    }
}

// MARK: The iOS owner gate

/// The owner ask an iOS preview waits for: the Simulator installs and runs the app outside Brahma's sandbox (fix 4).
public enum SimulatorApproval {
    public static let waitingMessage = "waiting for the owner to allow a Simulator preview (it runs outside the sandbox)"
    /// The next `set_preview_command` or `brahma preview set` of the surface, even with unchanged values, files one fresh ask
    /// (`upsertPreviewSurface`); the engine never asks again by itself.
    public static let declinedMessage = "the owner did not allow a Simulator preview; set the preview again to ask again"
    public static let summary = "The iOS Simulator installs and runs the app outside Brahma's sandbox: it can read and write the "
        + "Simulator's own data and reach the network. Approve only if you trust this company's code."
    static let category = "permissions"
    static let subjectPrefix = "preview-simulator:"

    public static func title(_ name: String) -> String { "Allow iOS Simulator preview \(name)" }
}
