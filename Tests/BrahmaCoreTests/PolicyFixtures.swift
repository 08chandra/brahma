import Foundation
@testable import BrahmaCore
@testable import BrahmaSafety

// Tests only (Plan S Task S7): fixtures for the factory-decided policies. Production code obtains a `ValidatedPolicy` only
// from `SandboxPolicyFactory.decide`; tests that drive a runner or an adapter directly, with a context of their own, take one
// from here (through `@testable`), and the pre-S7 assertions keep their shape.

extension ValidatedPolicy {
    /// Tests only (Plan S Task S7): the policy recorded for a call through a fake's `UnsandboxedRunning` side, which has none.
    static let optedOut = ValidatedPolicy(writable: [], readable: [], network: .none, toolchain: false, memoryLimit: nil, confined: nil)

    /// Tests only: a fixture policy taken as validated, for adapters and runners driven directly with a context of their own
    /// (no factory, no baseline); the strings are the URLs' paths.
    static func fixture(writable: [URL], readable: [URL] = [], network: SandboxNetwork = .none, toolchain: Bool = false) -> ValidatedPolicy {
        ValidatedPolicy(writable: writable.map(\.path), readable: readable.map(\.path), network: network, toolchain: toolchain,
                        memoryLimit: nil, confined: nil)
    }

    /// Tests only: `policy` validated as the factory validates it (`SandboxPolicyCheck`), against `baseline`.
    static func validated(_ policy: SandboxPolicy, baseline: SandboxBaseline) throws -> ValidatedPolicy {
        try SandboxPolicyCheck.validate(policy, baseline: baseline)
    }
}

extension FullOptOut {
    /// Tests only: an opt-out for a fake's Full route driven directly.
    static let fixture = FullOptOut(reason: "test fixture: the company and every subject run Full")
}

extension PolicyDecision {
    /// Tests only: the validated policy of a `.sandboxed` decision, else nil.
    var validated: ValidatedPolicy? {
        if case .sandboxed(let policy) = self { return policy }
        return nil
    }
}

extension PrincipalSet {
    /// Tests only: one Sandboxed-profile agent of `companyId` holding `grants`, in a Sandboxed company: the subject a
    /// fixture's preview policy is decided for when the test only looks at the policy's shape.
    static func testAgent(companyId: String, grants: [String] = []) -> PrincipalSet {
        PrincipalSet(companyId: companyId, members: [.agent(AgentPrincipal(agentId: "test-agent", companyId: companyId, role: "engineer",
                                                                            profile: .sandboxed, grantDomains: grants))],
                     ownerProfile: .sandboxed)
    }
}

extension PreviewPolicy {
    // Tests only (Plan S Task S7): the factory's decision for a fixture start, for a Sandboxed agent subject (holding
    // `grantDomains`) against the owner's baseline, as the pre-S7 static forms gave the policy; nil when it is refused.

    static func server(_ l: EngineLayout, run: URL, company: Company, port: Int, grantDomains: [String] = []) -> ValidatedPolicy? {
        server(l, run: run, company: company, port: port, principals: .testAgent(companyId: company.id, grants: grantDomains),
               baseline: SandboxBaseline.owner()).validated
    }

    static func oneShot(_ l: EngineLayout, run: URL, company: Company, sandbox: SandboxLayout) -> ValidatedPolicy? {
        oneShot(l, run: run, company: company, principals: .testAgent(companyId: company.id), baseline: SandboxBaseline.owner()).validated
    }

    static func appleBuild(_ l: EngineLayout, run: URL, company: Company, sandbox: SandboxLayout) -> ValidatedPolicy? {
        appleBuild(l, run: run, company: company, principals: .testAgent(companyId: company.id), baseline: SandboxBaseline.owner()).validated
    }

    static func guiApp(_ l: EngineLayout, run: URL, company: Company, sandbox: SandboxLayout, surface: String) -> ValidatedPolicy? {
        guiApp(l, run: run, company: company, surface: surface, principals: .testAgent(companyId: company.id),
               baseline: SandboxBaseline.owner()).validated
    }

    /// The pre-S7 `forKind` shape: the build's policy and the app's.
    static func forKind(_ kind: PreviewKind, layout: EngineLayout, run: URL, company: Company, sandbox: SandboxLayout, port: Int,
                        surface: String) -> (policy: ValidatedPolicy?, appPolicy: ValidatedPolicy?) {
        switch forKind(kind, layout: layout, run: run, company: company, port: port, surface: surface,
                       principals: .testAgent(companyId: company.id), baseline: SandboxBaseline.owner()) {
        case .sandboxed(let policy, let app): return (policy, app)
        case .fullOptOut, .refused: return (nil, nil)
        }
    }
}

// Tests only (Plan S Task S7): a validated policy names its places as path strings (`ValidatedPolicy.writable`,
// `.readable`). These let the pre-S7 assertions, written against the `[URL]` a `SandboxPolicy` held, compare those strings
// with the URLs they name, by path, unchanged.
func == (lhs: [String], rhs: [URL]) -> Bool { lhs == rhs.map(\.path) }
func == (lhs: [String]?, rhs: [URL]) -> Bool { lhs == rhs.map(\.path) }

extension Array where Element == String {
    func contains(_ url: URL) -> Bool { contains(url.path) }
}

extension String {
    /// The path a policy entry names (itself).
    var path: String { self }
}

extension SeatbeltProfile {
    /// Tests only: the pre-S7 `render(policy:…)` over a literal policy, which resolved the policy's paths itself unless told
    /// they were checked (`resolvePolicyPaths`).
    static func render(policy: SandboxPolicy, baseline: SandboxBaseline, proxyPort: UInt16?, marker: String? = nil,
                       resolvePolicyPaths: Bool = true) -> String {
        func p(_ url: URL) -> String { resolvePolicyPaths ? SandboxPath.resolve(url.path) : url.path }
        return render(ValidatedPolicy(writable: policy.writable.map(p), readable: policy.readable.map(p), network: policy.network,
                                      toolchain: policy.toolchain, memoryLimit: policy.memoryLimit, confined: policy.confined),
                      baseline: baseline, proxyPort: proxyPort, marker: marker)
    }
}

extension SeatbeltRunner {
    // Tests only: a literal policy validated against this runner's baseline (`SandboxPolicyCheck`, as `decide` validates),
    // then run; a policy the check refuses is the outcome of a run that could not start, with the runner's own text, as
    // before Plan S.

    func run(command: String, cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
             policy: SandboxPolicy) async -> CheckOutcome {
        let validated: ValidatedPolicy
        do { validated = try SandboxPolicyCheck.validate(policy, baseline: baseline()) } catch {
            return GroupRun.fail(PolicyRefusal.tail("\(error)"), outputURL: outputURL)
        }
        return await run(command: command, cwd: cwd, environment: environment, timeout: timeout, outputURL: outputURL, policy: validated)
    }

    func spawn(command: String, cwd: URL, environment: [String: String], logURL: URL, policy: SandboxPolicy) throws -> any SandboxedProcess {
        try spawn(command: command, cwd: cwd, environment: environment, logURL: logURL,
                  policy: try SandboxPolicyCheck.validate(policy, baseline: baseline()))
    }

    func runProgramBlocking(arguments: [String], cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
                            stdoutURL: URL, stdoutCap: Int, policy: SandboxPolicy) -> CheckOutcome {
        let validated: ValidatedPolicy
        do { validated = try SandboxPolicyCheck.validate(policy, baseline: baseline()) } catch {
            return GroupRun.fail(PolicyRefusal.tail("\(error)"), outputURL: outputURL)
        }
        return runProgramBlocking(arguments: arguments, cwd: cwd, environment: environment, timeout: timeout, outputURL: outputURL,
                                  stdoutURL: stdoutURL, stdoutCap: stdoutCap, policy: validated)
    }

    static func removeTemp(_ policy: SandboxPolicy) {
        removeTemp(ValidatedPolicy.fixture(writable: policy.writable, readable: policy.readable, network: policy.network,
                                           toolchain: policy.toolchain))
    }
}

extension SandboxedPDFReader {
    /// Tests only: the factory's `.pdfReader` decision over literal places (taken as verified), for the profile tests that
    /// name a helper which does not exist here; nil when refused.
    static func policy(helper: URL, held: URL, out: URL, memoryLimit: Int) -> ValidatedPolicy? {
        SandboxPolicyFactory.decide(.pdfReader(memoryLimit: memoryLimit), principals: PrincipalSet(companyId: "", members: [.engine], ownerProfile: .sandboxed),
                                    places: .pdfReader(helper: Place(resolvedPath: helper.path, kind: .file),
                                                       held: Place(resolvedPath: held.path, kind: .directory),
                                                       out: Place(resolvedPath: out.path, kind: .directory)),
                                    network: .none, baseline: SandboxBaseline.owner()).validated
    }
}

extension SandboxedUnzipReader {
    /// Tests only: `legacyExtract` over literal places (taken as verified); nil when refused.
    static func policy(unzip: URL, held: URL, out: URL) -> ValidatedPolicy? {
        SandboxPolicyFactory.legacyExtract(unzipped: Place(resolvedPath: out.path, kind: .directory), held: Place(resolvedPath: held.path, kind: .directory),
                                           program: Place(resolvedPath: unzip.path, kind: .file), memoryLimit: memoryLimit,
                                           baseline: SandboxBaseline.owner()).validated
    }
}

extension String {
    /// The last component of the path a policy entry names.
    var lastPathComponent: String { URL(fileURLWithPath: self).lastPathComponent }
}
