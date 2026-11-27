import Foundation
import GRDB

/// What a preview surface shows. Plan L has `web`; 4a adds `backend`, `cli`, `ios`, `macos` and `artifact` (artifacts are
/// published, never set as a surface: `PreviewSurface.validate` refuses that kind).
public enum PreviewKind: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case web, backend, cli, ios, macos, artifact

    public var title: String {
        switch self {
        case .web: "Web"
        case .backend: "Backend"
        case .cli: "CLI"
        case .ios: "iOS"
        case .macos: "macOS"
        case .artifact: "Artifacts"
        }
    }
}

public enum PreviewStatus: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    /// `ran`: a one-shot preview (a CLI demo) finished; terminal until `main` moves, it changes or a restart is flagged.
    case idle, building, starting, running, failed, stopped, unavailable, ran

    public var title: String {
        switch self {
        case .idle: "Idle"
        case .building: "Building"
        case .starting: "Starting"
        case .running: "Running"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .unavailable: "Unavailable"
        case .ran: "Ran"
        }
    }
}

/// One smoke request against a preview or a deployed site: `"GET /health 200"`, `"POST /items {json} 201"`, `"GET /"`.
/// Agent-written: its path and body are agent-controlled text.
public struct SmokeRequest: Codable, Equatable, Sendable {
    public var method: String
    public var path: String
    public var body: String?
    public var expectStatus: Int?

    /// At most this many per surface or hosting config.
    public static let max = 10
    /// How much of a response body a `SmokeResult` keeps (characters).
    public static let bodyKept = 4096
    /// The methods a smoke request may use.
    public static let methods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]

    public init(method: String, path: String, body: String? = nil, expectStatus: Int? = nil) {
        self.method = method; self.path = path; self.body = body; self.expectStatus = expectStatus
    }

    static let parseError = WorkError.invalid("smoke requests look like \"GET /health 200\" or \"POST /items {json} 201\"")

    /// `<METHOD> <path> [<body>] [<status>]`: the method (any case), a path starting with exactly one `/`, then optionally
    /// a body (everything up to the status, spaces kept) and an expected status 100–599 as the last word. The result
    /// passes `isValid` (the one rule set for a request, shared with `PreviewSurface.validate`).
    public static func parse(_ s: String) throws -> SmokeRequest {
        let text = s.trimmingCharacters(in: .whitespaces)
        let words = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard words.count == 2 else { throw parseError }
        var rest = words[1].trimmingCharacters(in: .whitespaces)
        let pathEnd = rest.firstIndex(of: " ") ?? rest.endIndex
        let path = String(rest[..<pathEnd])
        rest = String(rest[pathEnd...]).trimmingCharacters(in: .whitespaces)
        var status: Int?
        if let last = rest.split(separator: " ").last, last.allSatisfy(\.isASCII), last.allSatisfy(\.isNumber), last.count <= 3 {
            guard let code = Int(last), (100...599).contains(code) else { throw parseError }
            status = code
            rest = String(rest.dropLast(last.count)).trimmingCharacters(in: .whitespaces)
        }
        let request = SmokeRequest(method: words[0].uppercased(), path: path, body: rest.isEmpty ? nil : rest, expectStatus: status)
        guard request.isValid else { throw parseError }
        return request
    }

    /// The one per-request rule set, whether the request was parsed from text or decoded from a tool call or the database:
    /// an allowed method, a path that starts with exactly one `/`, a body of at most `bodyKept` characters, an expected
    /// status 100–599, and no control character anywhere.
    public var isValid: Bool {
        guard Self.methods.contains(method), Self.isSmokePath(path), (body ?? "").count <= Self.bodyKept else { return false }
        if let expectStatus, !(100...599).contains(expectStatus) { return false }
        return ![method, path, body ?? ""].contains { $0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
    }

    /// Starts with exactly one `/`.
    static func isSmokePath(_ path: String) -> Bool { path.hasPrefix("/") && !path.hasPrefix("//") }
}

/// What one smoke request saw. `bodyPrefix` and `error` are agent-controlled text (HTTP bodies).
public struct SmokeResult: Codable, Equatable, Sendable {
    public var url: String
    public var method: String
    public var status: Int?
    public var millis: Int
    public var bodyPrefix: String
    public var ok: Bool
    public var error: String?

    public init(url: String, method: String, status: Int?, millis: Int, bodyPrefix: String, ok: Bool, error: String?) {
        self.url = url; self.method = method; self.status = status; self.millis = millis; self.bodyPrefix = bodyPrefix
        self.ok = ok; self.error = error
    }
}

/// One preview a company runs from `main` (table `previewSurface`, Task 2's migration). Every command, URL and smoke path is
/// agent-written. `kind` is stored as text so a row a later plan writes still loads. Plan 4a's fields (`demo`, `openapiPath`,
/// `appPath`, `bundleId`, `device`) are agent-written too; `outsideSandboxAskId`/`outsideSandboxApprovedAt` are the engine's
/// record of the owner's Simulator approval (`Store.requestSimulatorApproval`, `applySimulatorApprovalEffects`): no tool or
/// CLI command writes them.
public struct PreviewSurface: Codable, Equatable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "previewSurface"
    /// Preview surfaces per company.
    public static let maxPerCompany = 8

    public var id: String
    public var companyId: String
    public var name: String
    public var kind: String
    public var position: Int
    public var build: String?
    public var run: String?
    public var url: String?
    public var smoke: [SmokeRequest]
    public var setById: String
    public var createdAt: Date
    public var updatedAt: Date
    /// A CLI preview's demo command (Plan 4a).
    public var demo: String? = nil
    /// A backend's OpenAPI file, relative to the repo root.
    public var openapiPath: String? = nil
    /// An iOS or macOS preview's built `.app`, relative to the repo root.
    public var appPath: String? = nil
    public var bundleId: String? = nil
    /// The Simulator device type an iOS preview asks for.
    public var device: String? = nil
    /// The engine's owner ask for an iOS preview (it runs outside the sandbox), and when the owner approved it. Cleared when
    /// the kind, `build`, `appPath` or `bundleId` changes.
    public var outsideSandboxAskId: String? = nil
    public var outsideSandboxApprovedAt: Date? = nil

    public init(id: String, companyId: String, name: String, kind: String = PreviewKind.web.rawValue, position: Int, build: String?,
                run: String?, url: String?, smoke: [SmokeRequest] = [], setById: String, createdAt: Date, updatedAt: Date,
                demo: String? = nil, openapiPath: String? = nil, appPath: String? = nil, bundleId: String? = nil, device: String? = nil,
                outsideSandboxAskId: String? = nil, outsideSandboxApprovedAt: Date? = nil) {
        self.id = id; self.companyId = companyId; self.name = name; self.kind = kind; self.position = position
        self.build = build; self.run = run; self.url = url; self.smoke = smoke; self.setById = setById
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.demo = demo; self.openapiPath = openapiPath; self.appPath = appPath; self.bundleId = bundleId; self.device = device
        self.outsideSandboxAskId = outsideSandboxAskId; self.outsideSandboxApprovedAt = outsideSandboxApprovedAt
    }

    /// The kind, when this engine knows it.
    public var previewKind: PreviewKind? { PreviewKind(rawValue: kind) }

    public static let maxCommand = 2000

    /// Throws `WorkError.invalid` with the message for the first rule broken: the name, the kind and the fields it needs
    /// (`validateKind`, Plan 4a), each command 1–2000 characters, the URL when there is one (`LoopbackURL.validate`), the
    /// paths, bundle id and device (`validateAppleFields`), then the smoke requests.
    public func validate() throws {
        guard name.range(of: "^[a-z][a-z0-9-]{0,23}$", options: .regularExpression) != nil else {
            throw WorkError.invalid("preview names are lowercase letters, digits and dashes (max 24)")
        }
        try validateKind()
        for command in [build, run, demo].compactMap({ $0 }) {
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, command.count <= Self.maxCommand else {
                throw WorkError.invalid("preview commands must be 1–2000 characters")
            }
        }
        if let url { try LoopbackURL.validate(url) }
        try validateAppleFields()
        guard smoke.count <= SmokeRequest.max, smoke.allSatisfy(\.isValid) else {
            throw WorkError.invalid("up to 10 smoke requests, each path starting with /")
        }
    }
}

/// The engine's record of one surface's process (table `previewState`, Task 2's migration). `message` may quote agent text
/// only as the engine composed it (never log output).
public struct PreviewState: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "previewState"

    public var surfaceId: String
    public var companyId: String
    public var status: PreviewStatus
    public var commit: String?
    public var port: Int?
    public var resolvedURL: String?
    /// The server's (or app's) process, the leader of its own group. A different pid drops `pidStart`, so a start time is
    /// never paired with a process it was not read from.
    public var pid: Int32? {
        didSet { if pid != oldValue { pidStart = nil } }
    }
    /// `pid`'s exact start time (`ProcessTable`), read at the spawn while the child was still unreaped and so provably the
    /// engine's (final review I2). Every stop path signals the group only when the live process has exactly this start; a
    /// record without one (an older engine's) is never signalled.
    public var pidStart: Double? = nil
    public var message: String?
    public var logPath: String?
    /// When the process exited on its own, recently (the crash-loop window).
    public var exits: [Date]
    public var restartRequestedAt: Date?
    public var startedAt: Date?
    public var updatedAt: Date
    /// The Simulator device an iOS preview runs on (Plan 4a).
    public var simulatorId: String? = nil
    /// A one-shot preview's captured output (engine-written, redacted).
    public var outputPath: String? = nil
    /// A backend's smoke results (agent-controlled bodies).
    public var smokeResults: [SmokeResult] = []

    public init(surfaceId: String, companyId: String, status: PreviewStatus = .idle, commit: String? = nil, port: Int? = nil,
                resolvedURL: String? = nil, pid: Int32? = nil, message: String? = nil, logPath: String? = nil, exits: [Date] = [],
                restartRequestedAt: Date? = nil, startedAt: Date? = nil, updatedAt: Date, simulatorId: String? = nil,
                outputPath: String? = nil, smokeResults: [SmokeResult] = [], pidStart: Double? = nil) {
        self.surfaceId = surfaceId; self.companyId = companyId; self.status = status; self.commit = commit; self.port = port
        self.resolvedURL = resolvedURL; self.pid = pid; self.message = message; self.logPath = logPath; self.exits = exits
        self.restartRequestedAt = restartRequestedAt; self.startedAt = startedAt; self.updatedAt = updatedAt
        self.simulatorId = simulatorId; self.outputPath = outputPath; self.smokeResults = smokeResults; self.pidStart = pidStart
    }
}

/// The URLs a preview may have: `http` on the loopback, with a port (1024–65535, or `{port}` for the engine's).
public enum LoopbackURL {
    static let urlRefusal = WorkError.invalid("preview URLs must be http://127.0.0.1, localhost or [::1] with a port")
    static let pathRefusal = WorkError.invalid("preview paths start with one / and stay on the preview")
    static let placeholder = "{port}"
    static let hosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    /// Valid: scheme `http`, host `127.0.0.1`, `localhost` or `[::1]`, no user or password, and a port 1024–65535 or `{port}`
    /// (once, in the port's place only).
    public static func validate(_ s: String) throws {
        let occurrences = s.components(separatedBy: placeholder).count - 1
        guard occurrences <= 1 else { throw urlRefusal }
        // `{port}` may only stand where the port is: `:{port}` followed by the end, a path, a query or a fragment.
        var text = s
        var placeholderPort = false
        if occurrences == 1 {
            guard let range = s.range(of: ":" + placeholder) else { throw urlRefusal }
            let after = s[range.upperBound...]
            guard after.isEmpty || after.hasPrefix("/") || after.hasPrefix("?") || after.hasPrefix("#") else { throw urlRefusal }
            text = s.replacingCharacters(in: range, with: ":47100")
            placeholderPort = true
        }
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == " " }),
              let c = URLComponents(string: text), c.scheme == "http", c.user == nil, c.password == nil,
              let host = c.host.map(unbracketed), hosts.contains(host.lowercased()),
              let port = c.port else { throw urlRefusal }
        // A literal port is 1024–65535; `{port}` (refused anywhere but the port's place above) is the engine's.
        if !placeholderPort, !(1024...65535).contains(port) { throw urlRefusal }
    }

    /// The URL with `{port}` substituted (nil when it has `{port}` and no port is given, or does not parse).
    public static func resolve(_ s: String, port: Int?) -> URL? {
        if s.contains(placeholder) {
            guard let port else { return nil }
            return URL(string: s.replacingOccurrences(of: placeholder, with: String(port)))
        }
        return URL(string: s)
    }

    /// `127.0.0.1`, `localhost` or `::1` (bracketed or not), as a URL or `lsof` names it.
    public static func isLoopback(host: String) -> Bool { hosts.contains(unbracketed(host).lowercased()) }

    static func unbracketed(_ host: String) -> String {
        host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    }

    /// `http://127.0.0.1:<port><path>` for a path the owner typed into a preview (collab design §4.6). Refused
    /// (`"preview paths start with one / and stay on the preview"`) when the path does not start with exactly one `/`; holds
    /// `//`, `\`, `@`, a `:` before the first `/`, a control character, or `%0d`/`%0a` (any case); or is over 2048
    /// characters; or when `base` is not a loopback preview on `port`. Each segment is percent-encoded (a `%XX` escape is
    /// kept); the result is checked to be scheme `http`, host `127.0.0.1` and `port`.
    public static func withPath(_ base: URL, path: String, port: Int) throws -> URL {
        guard (1...65535).contains(port), base.scheme == "http", let baseHost = base.host, isLoopback(host: baseHost),
              base.port == nil || base.port == port else { throw pathRefusal }
        guard path.count <= 2048, path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("//"), !path.contains("\\"),
              !path.contains("@"), !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f || (0x80...0x9f).contains($0.value) }) else {
            throw pathRefusal
        }
        let lowered = path.lowercased()
        guard !lowered.contains("%0d"), !lowered.contains("%0a") else { throw pathRefusal }
        if let colon = path.firstIndex(of: ":"), let slash = path.firstIndex(of: "/"), colon < slash { throw pathRefusal }
        let (rawPath, rawQuery): (Substring, Substring?) = {
            guard let q = path.firstIndex(of: "?") else { return (path[...], nil) }
            return (path[..<q], path[path.index(after: q)...])
        }()
        let encodedPath = rawPath.split(separator: "/", omittingEmptySubsequences: false).map { encode($0, extra: ":") }
            .joined(separator: "/")
        var text = "http://127.0.0.1:\(port)" + encodedPath
        if let rawQuery { text += "?" + encode(rawQuery, extra: ":/?=&") }
        guard let url = URL(string: text), url.scheme == "http", url.host == "127.0.0.1", url.port == port else { throw pathRefusal }
        return url
    }

    /// Percent-encodes every byte outside the unreserved set, the sub-delimiters and `extra`; a well-formed `%XX` is kept.
    static func encode(_ part: Substring, extra: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=".utf8).union(extra.utf8)
        let bytes = Array(part.utf8)
        var out = ""
        var i = 0
        func isHex(_ b: UInt8) -> Bool { (48...57).contains(b) || (65...70).contains(b) || (97...102).contains(b) }
        while i < bytes.count {
            let b = bytes[i]
            if b == 37, i + 2 < bytes.count, isHex(bytes[i + 1]), isHex(bytes[i + 2]) {
                out += String(decoding: bytes[i...(i + 2)], as: UTF8.self)
                i += 3
                continue
            }
            if allowed.contains(b) { out.append(Character(Unicode.Scalar(b))) } else { out += String(format: "%%%02X", b) }
            i += 1
        }
        return out
    }
}

/// The sandbox of a preview server (builder-check 8).
public enum PreviewPolicy {
    /// Writes only its own fresh export `run` (which holds its TMPDIR and, with the toolchain, its per-run HOME and caches);
    /// the log is written by the engine (it opens the log and pipes the server's output into it), so the logs directory is
    /// in no writable list and a server cannot swap it for a link (F1); reads only `run`; listens on and connects to only its own loopback `port`, and reaches the
    /// company's allowed domains (registries, owner-added, `grantDomains`) only through the egress proxy. No writable shared
    /// cache (PR-19): nothing one build plants can run in a later one. Every path is resolved (`SandboxPolicyCheck`).
    /// Plan S Task S7: the factory's `.previewServer` rule (`SandboxPolicyFactory.decide`), over the run as a verified
    /// `Place`; the grants are the principal set's common grants (B3; none with an unknown member), the Full opt-out the
    /// owner's (`principals`).
    public static func server(_ l: EngineLayout, run: URL, company: Company, port: Int, principals: PrincipalSet,
                              baseline: SandboxBaseline) -> PolicyDecision {
        decide(.previewServer(port: LoopbackPort(port)), run: run, company: company, principals: principals, baseline: baseline) {
            .previewServer(run: $0)
        }
    }

    /// `run` as a verified place (its resolved path, a real directory reached from its parent without a link), then the
    /// factory's decision for `purpose` over the places `places` builds from it.
    static func decide(_ purpose: Purpose, run: URL, company: Company, principals: PrincipalSet, baseline: SandboxBaseline,
                       _ places: (Place) throws -> PurposePlaces) -> PolicyDecision {
        let resolved = run.resolvedForSandbox
        let chosen: PurposePlaces
        do { chosen = try places(try Place.verify(resolved, kind: .directory, under: resolved.deletingLastPathComponent())) } catch {
            return .refused("the preview's place is not safe to use (\(error))")
        }
        return SandboxPolicyFactory.decide(purpose, principals: principals, places: chosen,
                                           network: CompanyNetwork.scope(company: company, grantDomains: [], grantWebDomains: []),
                                           baseline: baseline)
    }
}
