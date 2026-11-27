import Foundation

/// What a sandboxed command may reach on the network.
public enum SandboxNetwork: Equatable, Sendable {
    /// Nothing at all.
    case none
    /// TLS to the allowed domains, only through the engine's egress proxy (`EgressProxy`).
    case outbound(allow: [String])
    /// As `.outbound`, plus listening on and connecting to its own loopback `ports` (a preview server).
    case loopbackListen(allow: [String], ports: [UInt16])

    /// The domains the egress proxy lets through, or nil for `.none`.
    var allowedDomains: [String]? {
        switch self {
        case .none: nil
        case .outbound(let allow): allow
        case .loopbackListen(let allow, _): allow
        }
    }

    var loopbackPorts: [UInt16] {
        if case .loopbackListen(_, let ports) = self { return ports }
        return []
    }
}

/// What one sandboxed command may touch, as a policy is assembled inside `BrahmaSafety` (Plan S Task S7: only
/// `SandboxPolicyFactory` builds one, from verified `Place`s, and only `SandboxPolicyCheck.validate` turns one into the
/// `ValidatedPolicy` a runner accepts; `init` is internal, so nothing outside the kernel can name a path to the sandbox).
/// Every path is resolved (`URL.resolvedForSandbox`); a policy holding a path that resolves elsewhere (a link on the way)
/// is refused. `writable[0]` holds the command's `TMPDIR`; with `toolchain`, the last writable entry is the cache that holds
/// its `HOME` and tool caches.
public struct SandboxPolicy: Equatable, Sendable {
    public internal(set) var writable: [URL]
    public internal(set) var readable: [URL]
    public internal(set) var network: SandboxNetwork
    public internal(set) var toolchain: Bool
    /// C2b fix round 3: the most physical memory (summed footprint, bytes) the run may use (round 4: its own process,
    /// whatever group it is in, and its process group); past it the runner kills the run (`GroupRun.memoryExceeded`). nil:
    /// no limit.
    public internal(set) var memoryLimit: Int? = nil
    /// C2b fix round 3 (m-C): a deny-default profile instead of the standard allow-default one (`SeatbeltProfile`
    /// `renderConfined`). `readable` entries are then the only trees it may read beyond the system; `writable` entries are
    /// the runner's own (its `TMPDIR`), never written by the command.
    public internal(set) var confined: SandboxConfinement? = nil

    init(writable: [URL], readable: [URL], network: SandboxNetwork, toolchain: Bool) {
        self.writable = writable; self.readable = readable; self.network = network; self.toolchain = toolchain
    }

    /// The domains the egress proxy lets through, or nil for `.none`.
    var allowedDomains: [String]? { network.allowedDomains }

    var loopbackPorts: [UInt16] { network.loopbackPorts }
}

/// What a confined run (`SandboxPolicy.confined`) may do besides read the system's own libraries and frameworks: run
/// exactly these programs (round 4: no shell, no fork; such a run is one program, `SandboxedRunner.runProgramBlocking`),
/// read these files and list these directories, and create and write exactly these files. No network, no mach service
/// but the run's own marker, nothing else.
public struct SandboxConfinement: Equatable, Sendable {
    public internal(set) var executables: [URL]
    public internal(set) var readableFiles: [URL]
    public internal(set) var listableDirectories: [URL]
    public internal(set) var writableFiles: [URL]

    init(executables: [URL], readableFiles: [URL], listableDirectories: [URL], writableFiles: [URL]) {
        self.executables = executables; self.readableFiles = readableFiles
        self.listableDirectories = listableDirectories; self.writableFiles = writableFiles
    }

    var all: [URL] { executables + readableFiles + listableDirectories + writableFiles }
}

/// A policy `SandboxPolicyCheck.validate` accepted (spec §6.3.3): it holds the exact path strings validation checked, and
/// `SeatbeltProfile.render` renders those strings and never resolves anything, so a link swapped in between the check and
/// the render cannot change the profile. The only way to obtain one is `SandboxPolicyFactory.decide` (its initializer is
/// internal to `SandboxPolicyCheck`); every sandboxed runner takes one, never a `SandboxPolicy`.
public struct ValidatedPolicy: Sendable, Equatable {
    public let writable: [String]
    public let readable: [String]
    public let network: SandboxNetwork
    public let toolchain: Bool
    /// `SandboxPolicy.memoryLimit`, as validated.
    let memoryLimit: Int?
    /// `SandboxPolicy.confined`, as validated (every path already resolved).
    let confined: SandboxConfinement?

    /// Only `SandboxPolicyCheck.validate` calls this.
    init(writable: [String], readable: [String], network: SandboxNetwork, toolchain: Bool, memoryLimit: Int?,
         confined: SandboxConfinement?) {
        self.writable = writable; self.readable = readable; self.network = network; self.toolchain = toolchain
        self.memoryLimit = memoryLimit; self.confined = confined
    }

    /// The domains the egress proxy lets through, or nil for `.none`.
    public var allowedDomains: [String]? { network.allowedDomains }

    var loopbackPorts: [UInt16] { network.loopbackPorts }

    /// `writable[0]`, the entry that holds the run's `TMPDIR`.
    var tempRoot: URL? { writable.first.map { URL(fileURLWithPath: $0, isDirectory: false) } }
}

/// What makes a policy safe to render, checked before anything runs.
enum SandboxPolicyCheck {
    /// The policy's paths as the strings it will be rendered from, after the checks below. Throws when:
    /// - the baseline could not be built (`problem`);
    /// - there is no writable entry (`.invalidPath`);
    /// - a policy or baseline path is not absolute, or holds a character no profile string may carry (`.invalidPath`,
    ///   `.unsafePathCharacter`);
    /// - a policy path is not already resolved (a link on the way, or `..`) (`.linkedPath`);
    /// - a policy path overlaps a protected path, or equals or contains the home, an engine home, `/Volumes` or `/`
    ///   (`.overlapsProtected`);
    /// - a writable path equals or contains a company workspace (the workspace deny covers reads only) (`.overlapsProtected`);
    /// - an allowed domain is Anthropic's or not a valid pattern; a loopback port is 0.
    static func validate(_ policy: SandboxPolicy, baseline: SandboxBaseline) throws -> ValidatedPolicy {
        // A confinement keeps its paths as strings too (each a plain file URL of its path), so two policies naming the same
        // places are equal however their URLs were spelled.
        func plain(_ urls: [URL]) -> [URL] { urls.map { URL(fileURLWithPath: $0.path, isDirectory: false) } }
        let confined = policy.confined.map {
            SandboxConfinement(executables: plain($0.executables), readableFiles: plain($0.readableFiles),
                               listableDirectories: plain($0.listableDirectories), writableFiles: plain($0.writableFiles))
        }
        let validated = ValidatedPolicy(writable: policy.writable.map(\.path), readable: policy.readable.map(\.path),
                                        network: policy.network, toolchain: policy.toolchain, memoryLimit: policy.memoryLimit,
                                        confined: confined)
        try recheck(validated, baseline: baseline)
        return validated
    }

    /// The same checks again, on the strings a `ValidatedPolicy` holds, against `baseline` (the runner's, taken when the run
    /// starts): a link planted since the policy was validated, or a protected path added since, refuses the run. It resolves
    /// to check and never to render: what is rendered is always the validated strings.
    static func recheck(_ policy: ValidatedPolicy, baseline: SandboxBaseline) throws {
        if let problem = baseline.problem { throw SandboxError.invalidPath("sandbox baseline unavailable: \(problem)") }
        guard !policy.writable.isEmpty else { throw SandboxError.invalidPath("a sandbox policy needs a writable directory") }
        let baselinePaths = ([baseline.userHome] + baseline.protected + baseline.engineHomes + baseline.companyWorkspaces
            + [baseline.darwinUserTemp, baseline.darwinUserCache, baseline.darwinUserDir].compactMap { $0 }).map(\.path)
        let confined = (policy.confined?.all ?? []).map(\.path)
        for path in policy.writable + policy.readable + baselinePaths + confined {
            if SandboxPath.isUnsafe(path) { throw SandboxError.unsafePathCharacter(path) }
            if !path.hasPrefix("/") { throw SandboxError.invalidPath(path) }
        }
        // A confined run's own paths are literals: each must already be resolved (no link on the way).
        for path in confined where SandboxPath.resolve(path) != path {
            throw SandboxError.linkedPath(path)
        }
        let roots = [baseline.userHome] + baseline.engineHomes + [URL(fileURLWithPath: "/Volumes"), URL(fileURLWithPath: "/")]
        // The same alias/identity helper as turn scopes (`SandboxPath.checkAllowed`): no alias spelling, and overlaps judged by
        // spelling and by device and inode (a firmlink spelling of a protected place is that place).
        let identities = (SandboxPath.IdentityRoots(baseline.protected), SandboxPath.IdentityRoots(roots))
        for path in policy.writable + policy.readable {
            if SandboxPath.resolve(path) != path || path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) {
                throw SandboxError.linkedPath(path)
            }
            try SandboxPath.checkAllowed(URL(fileURLWithPath: path), protected: baseline.protected, deniedRoots: roots, byIdentity: identities)
        }
        for path in policy.writable {
            if let hit = baseline.companyWorkspaces.first(where: { SandboxPath.isInside($0.path, path) }) {
                throw SandboxError.overlapsProtected(path: path, protected: hit.path)
            }
        }
        for domain in policy.allowedDomains ?? [] {
            if SandboxDomains.isForbidden(domain) { throw SandboxError.forbiddenDomain(SandboxDomains.normalize(domain)) }
            if !DomainMatcher.isValidPattern(domain) { throw SandboxError.invalidDomain(domain) }
        }
        if policy.loopbackPorts.contains(0) { throw SandboxError.invalidPath("loopback port 0") }
    }
}
