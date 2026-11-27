import Foundation

/// What a company's network allows a turn or a sandboxed command (moved from BrahmaCore's `SandboxScope.swift` in Plan S
/// Task S7, unchanged, so `SandboxPolicyFactory.decide` can take it; `CompanyNetwork.scope(...)` still builds it).
public struct NetworkScope: Equatable, Sendable {
    /// Bash egress (the proxy's allow-list).
    public var allowedDomains: [String]
    /// WebFetch.
    public var webDomains: [String]
    public var allowLocalBinding: Bool

    public init(allowedDomains: [String], webDomains: [String], allowLocalBinding: Bool) {
        self.allowedDomains = allowedDomains; self.webDomains = webDomains; self.allowLocalBinding = allowLocalBinding
    }

    /// No network: the scope of a purpose that reaches nothing.
    public static let none = NetworkScope(allowedDomains: [], webDomains: [], allowLocalBinding: false)

    /// A fixed allow-list (a hosting provider's pinned hosts: release tools, provider probes, a smoke's base host), taken as
    /// it is: no registry, no grant.
    public static func fixed(_ domains: [String]) -> NetworkScope {
        NetworkScope(allowedDomains: domains, webDomains: [], allowLocalBinding: false)
    }
}

/// Which engine check a `.check` purpose runs: a submission's (3a `VerificationRun` purpose `submit`), a merge check of a
/// verification run (`merge`), or a merge-queue run (4a `MergeRun`).
public enum CheckKind: String, Hashable, Sendable {
    case submit, merge, mergeQueue
}

/// The loopback port a preview server listens on (`PORT`). A number that is no port gives the policy no port at all, as
/// before Plan S.
public struct LoopbackPort: Hashable, Sendable {
    public let number: Int
    public init(_ number: Int) { self.number = number }

    var ports: [UInt16] { UInt16(exactly: number).map { [$0] } ?? [] }
}

/// Which of the sandbox canary's own runs a `.canary` purpose is (Ruling P3: named so it never shadows BrahmaCore's
/// `CanaryProbe`, the owner's probe file): the doctor's `sandbox-backend` read of the planted data-home token, or the
/// model-free layer's probes under the turn's scope (`sandbox-canary-local`).
public enum CanaryRunPlaces: String, Hashable, Sendable {
    case backend, localLayer
}

/// Every `brahma-helper` operation (spec §6.4.4). Declared here for `Purpose.helper` (Plan S Task S7); Task S8 implements
/// the helper and its protocol over these exact cases.
public enum HelperOp: String, Codable, Sendable, CaseIterable {
    case worktreeDiff, worktreeStatus, worktreeCommit, loopbackHTTP, httpsProbe, stageCopy, extractText, selftest
}

/// Why the engine runs something under Seatbelt (spec §6.3.1). Exhaustive: a new purpose must be added here and decided in
/// `SandboxPolicyFactory.decide`.
public enum Purpose: Hashable, Sendable {
    /// An engine check (3a's submit and merge checks, 4a's merge queue).
    case check(CheckKind)
    /// A preview server (L/4a web and backend kinds) listening on its own loopback port.
    case previewServer(port: LoopbackPort)
    /// A one-shot preview command: a CLI's build and demo.
    case previewOneShot
    /// An iOS or macOS preview build.
    case appleBuild
    /// A built macOS app, running.
    case guiApp(surface: String)
    /// A release's provider-tool step (L `ReleaseExecutor`: the pinned CLI's install, the token steps).
    case releaseTool
    /// The check-shaped run of a release: the main smoke (`Store+Release`) and the release build in its export.
    case releaseSmoke
    /// The owner's provider probe (`Hosting/ProviderProbe`), the release tool steps as the executor runs them.
    case providerProbe
    /// 5-lite: unzipping an imported extension.
    case extensionUnzip
    /// 5-lite: `claude plugin validate`/`details` on a staged extension.
    case extensionValidate
    /// `brahma doctor`'s `plugin-details-inert` item.
    case doctorExtensions
    /// One of the sandbox canary's own runs.
    case canary(CanaryRunPlaces)
    /// A `brahma-helper` call (spec §6.4).
    case helper(HelperOp)
    /// C2b: the `brahma-pdf` helper reading one held PDF under a deny-default profile, with a memory limit (spec §14.1: the
    /// policy site Plan C added after the spec's count, `Refs/SandboxedPDFReader.swift`).
    case pdfReader(memoryLimit: Int)

    /// Whether the purpose runs agent-written commands, the only ones the owner's Full opt-out may run unsandboxed
    /// (spec §6.3.2, rule 1).
    var runsAgentCommands: Bool {
        switch self {
        case .check, .previewServer, .previewOneShot, .appleBuild, .guiApp, .releaseTool, .releaseSmoke: true
        case .providerProbe, .extensionUnzip, .extensionValidate, .doctorExtensions, .canary, .helper, .pdfReader: false
        }
    }

    /// For refusal text.
    var name: String {
        switch self {
        case .check(let kind): "check (\(kind.rawValue))"
        case .previewServer: "preview server"
        case .previewOneShot: "one-shot preview"
        case .appleBuild: "Apple build"
        case .guiApp: "macOS app"
        case .releaseTool: "release tool"
        case .releaseSmoke: "release smoke"
        case .providerProbe: "provider probe"
        case .extensionUnzip: "extension unzip"
        case .extensionValidate: "extension validation"
        case .doctorExtensions: "doctor extension check"
        case .canary(let run): "canary (\(run.rawValue))"
        case .helper(let op): "helper (\(op.rawValue))"
        case .pdfReader: "PDF reader"
        }
    }
}

/// The places one purpose names, each a verified `Place` (spec §6.3.1): one case per `Purpose`, with typed places, so a
/// caller cannot slip an extra place in. `SandboxPolicyFactory.decide` refuses a case that is not its purpose's.
public enum PurposePlaces: Hashable, Sendable {
    case check(checkout: Place, workspace: Place)
    case previewServer(run: Place)
    case previewOneShot(run: Place)
    case appleBuild(run: Place)
    case guiApp(run: Place, appData: Place)
    case releaseTool(writable: [Place], readable: [Place])
    case releaseSmoke(dir: Place)
    case providerProbe(writable: [Place], readable: [Place])
    case extensionUnzip(unzipped: Place, held: Place)
    case extensionValidate(scratch: Place, readable: [Place])
    case doctorExtensions(scratch: Place, readable: [Place])
    case canary(writable: [Place], readable: [Place])
    case helper(op: HelperOp, targets: [Place], call: Place, helperDir: Place)
    case pdfReader(helper: Place, held: Place, out: Place)

    var name: String {
        switch self {
        case .check: "check"
        case .previewServer: "previewServer"
        case .previewOneShot: "previewOneShot"
        case .appleBuild: "appleBuild"
        case .guiApp: "guiApp"
        case .releaseTool: "releaseTool"
        case .releaseSmoke: "releaseSmoke"
        case .providerProbe: "providerProbe"
        case .extensionUnzip: "extensionUnzip"
        case .extensionValidate: "extensionValidate"
        case .doctorExtensions: "doctorExtensions"
        case .canary: "canary"
        case .helper: "helper"
        case .pdfReader: "pdfReader"
        }
    }
}
