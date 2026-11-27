import Foundation

// MARK: Names and errors

public enum SecretError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidName
    /// The name is one the engine itself sets in a child's environment (PATH, BRAHMA_*, DYLD_*, ...).
    case reservedName
    /// A test key's name must be one `SecretName.isInjectable` accepts: it is put in agents' environments.
    case notInjectable
    /// The name is in `SecretName.engineOnly` (Ruling X8-19): only engine ops read it; it can never be a test key.
    case engineOnly
    case emptyValue
    /// The value's bytes are not UTF-8 (refused at input; a stored one fails to load).
    case notUTF8
    case unknownCompany
    case notFound
    case vaultUnavailable
    case vaultFailed(String)
    /// The redactor has not loaded the secrets yet in this process: nothing redactable may be stored (fail closed).
    case secretsNotLoaded
    /// A non-interactive (background) read would have needed the owner's permission (a Keychain prompt).
    case needsPermission

    /// Plain text for the CLI and the app.
    public var message: String {
        switch self {
        case .invalidName: "invalid secret name: use A-Z, 0-9 and _, starting with a letter (2 to 64 characters)"
        case .reservedName: "that name is reserved: the engine sets it in every child's environment"
        case .notInjectable: "a test key's name must contain KEY, TOKEN or SECRET and must not be a variable that changes how programs run (GIT_*, SSH_*, DYLD_*, LD_*, NODE_*, PYTHON*, ...*PATH, ...*_OPTIONS, ...)"
        case .engineOnly: "that secret is engine-only: only the engine's own GitHub and Linear operations read it, and it is never "
            + "put in an agent's environment; set it without --test"
        case .emptyValue: "the secret value is empty"
        case .notUTF8: "the secret value is not valid UTF-8 text"
        case .unknownCompany: "no such company"
        case .notFound: "no such secret"
        case .vaultUnavailable: "no secrets vault is available on this platform"
        case .vaultFailed(let detail): "the secrets vault failed: \(detail)"
        case .secretsNotLoaded: "secrets are not loaded yet; try again shortly"
        case .needsPermission: "reading it needs your permission; run `brahma secret load` or press Load secrets in the app"
        }
    }

    public var description: String { message }
}

public enum SecretName {
    /// `^[A-Z][A-Z0-9_]{1,63}$`, ASCII only.
    public static func isValid(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (2...64).contains(bytes.count), (0x41...0x5A).contains(bytes[0]) else { return false }
        return bytes.allSatisfy { (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x5F }
    }

    /// Whether a TEST key of this name may be put in an agent's (or a check's) environment. Two layers, both required:
    /// - allowlist: the name contains `KEY`, `TOKEN` or `SECRET` (names are upper-case already);
    /// - denylist, checked after it: variable families that change how a program runs or where it loads code from
    ///   (`GIT_SSH_COMMAND`, `LD_PRELOAD`, `DYLD_*`, `BASH_FUNC_*`, `NODE_OPTIONS`, `PYTHONPATH`, `PATH`, ...), the engine's and
    ///   Claude's own variables, and every name `ChildEnvironment` itself sets or passes through.
    /// The one check for test keys: `Store.setSecret(isTest: true)` refuses, and `ChildEnvironment.make` drops, any other name.
    public static func isInjectable(_ name: String) -> Bool {
        guard isValid(name), !engineOnly.contains(name) else { return false }
        guard name.contains("KEY") || name.contains("TOKEN") || name.contains("SECRET") else { return false }
        if deniedPrefixes.contains(where: name.hasPrefix) { return false }
        if deniedSuffixes.contains(where: name.hasSuffix) { return false }
        if deniedNames.contains(name) || ChildEnvironment.isReserved(name) { return false }
        return true
    }

    /// Ruling X8-19: secrets only the engine's own operations read (the PR push and the issue import), each into a
    /// `TokenHandle` at the moment of use. An explicit set, not a prefix rule: they are stored with `brahma secret set` (never
    /// `--test`), `isInjectable` refuses them, so no turn profile, `use_secret` grant or check environment ever carries one.
    public static let engineOnly: Set<String> = ["GITHUB_PUSH_TOKEN", "LINEAR_API_KEY"]

    /// From the security review, plus `SSL`/`OPENSSL` (TLS key logging and engine loading) and `LC_` (locale, passed through).
    static let deniedPrefixes = ["GIT_", "SSH_", "DYLD_", "LD_", "BASH_FUNC_", "CLAUDE_", "BRAHMA_", "ANTHROPIC_", "NODE_", "NPM_",
                                 "PYTHON", "PERL", "RUBY", "JAVA_", "XDG_", "SSL", "OPENSSL", "LC_"]
    /// From the security review, plus `FILE` (`SSLKEYLOGFILE`, `SSL_KEYLOG_FILE`: a path a program writes TLS keys to).
    static let deniedSuffixes = ["_OPTIONS", "LIB", "PATH", "FILE"]
    static let deniedNames: Set<String> = ["PATH", "HOME", "SHELL", "ENV", "BASH_ENV", "ZDOTDIR", "PROMPT_COMMAND", "IFS", "TMPDIR",
                                           "LANG", "TERM", "USER", "LOGNAME"]
}

/// Secret values are text: the redactor matches them in stored text, so bytes that are not UTF-8 are refused rather than
/// repaired (a repaired value would never match the real one).
public enum SecretValue {
    public static func decode(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8), Data(text.utf8) == data else { throw SecretError.notUTF8 }
        return text
    }
}

// MARK: Vaults

/// Where secret values live. The database holds only names and flags, never a value.
public protocol SecretVault: Sendable {
    func set(companyId: String, name: String, value: String) throws
    func value(companyId: String, name: String) throws -> String?
    /// Deleting a secret that is not there is not an error.
    func delete(companyId: String, name: String) throws
    /// The same store with reads that can never ask the owner (no Keychain prompt): what every background reader holds
    /// (the push dispatcher, the engine's redactor reloads). Stores that never prompt return themselves.
    func nonInteractive() -> any SecretVault
}

extension SecretVault {
    public func nonInteractive() -> any SecretVault { self }
}

/// In-process storage for tests.
public final class MemoryVault: SecretVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    private func key(_ companyId: String, _ name: String) -> String { "\(companyId):\(name)" }

    public func set(companyId: String, name: String, value: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[key(companyId, name)] = value
    }

    public func value(companyId: String, name: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key(companyId, name)]
    }

    public func delete(companyId: String, name: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[key(companyId, name)] = nil
    }
}

/// Fails closed where no vault exists.
public struct UnavailableVault: SecretVault {
    public init() {}
    public func set(companyId: String, name: String, value: String) throws { throw SecretError.vaultUnavailable }
    public func value(companyId: String, name: String) throws -> String? { throw SecretError.vaultUnavailable }
    public func delete(companyId: String, name: String) throws { throw SecretError.vaultUnavailable }
}

/// The environment variable that picks a non-Keychain secret store for a dev/demo data home (`PlatformSecretVault`, in
/// BrahmaKeychain, is the one place that reads it; `MCPConfig` passes a `file` choice on to the turn's `brahma mcp`).
public enum SecretStore {
    public static let environmentVariable = "BRAHMA_SECRET_STORE"
}

/// Dev/demo/test store: one JSON file `<dataHome>/secrets/vault.json` (0600) in a 0700 directory, values base64-encoded
/// bytes. Selected only by `BRAHMA_SECRET_STORE=file`, which is refused for the default data home, so production always
/// uses the Keychain. Weaker than the Keychain: any process of the same user can read it.
///
/// Neither the directory nor the file may be a symbolic link (`O_NOFOLLOW`, `lstat`). Writes take an exclusive `flock` on
/// `vault.lock`, write a fresh 0600 temporary file (`O_EXCL`) and rename it over the old one, so a reader always sees a
/// whole file and two writers never lose each other's change.
public struct FileVault: SecretVault {
    public let home: URL

    public init(home: URL) { self.home = home }

    var directory: URL { home.appending(path: "secrets", directoryHint: .isDirectory) }
    var file: URL { directory.appending(path: "vault.json") }

    private struct Contents: Codable { var version = 1; var items: [String: String] = [:] }

    private static func key(_ companyId: String, _ name: String) -> String { "\(companyId):\(name)" }

    public func value(companyId: String, name: String) throws -> String? {
        guard let encoded = try read().items[Self.key(companyId, name)] else { return nil }
        guard let bytes = Data(base64Encoded: encoded) else { throw SecretError.vaultFailed("the stored value is corrupt") }
        return try SecretValue.decode(bytes)
    }

    public func set(companyId: String, name: String, value: String) throws {
        try setRaw(companyId: companyId, name: name, bytes: Data(value.utf8))
    }

    /// Stores raw bytes (tests use it to plant a value that is not UTF-8).
    func setRaw(companyId: String, name: String, bytes: Data) throws {
        try modify { $0.items[Self.key(companyId, name)] = bytes.base64EncodedString() }
    }

    public func delete(companyId: String, name: String) throws {
        try modify { $0.items[Self.key(companyId, name)] = nil }
    }

    private func modify(_ change: (inout Contents) -> Void) throws {
        try ensureDirectory()
        let lockFD = open(directory.appending(path: "vault.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw SecretError.vaultFailed("cannot open the vault lock (errno \(errno))") }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX) == 0 else { throw SecretError.vaultFailed("cannot lock the vault (errno \(errno))") }
        var contents = try read()
        change(&contents)
        let data = try JSONEncoder().encode(contents)
        let temp = directory.appending(path: ".vault.\(UUID().uuidString).json")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SecretError.vaultFailed("cannot write the vault (errno \(errno))") }
        let bytes = [UInt8](data)
        let written = bytes.withUnsafeBufferPointer { Foundation.write(fd, $0.baseAddress, $0.count) }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == bytes.count, synced, rename(temp.path, file.path) == 0 else {
            unlink(temp.path)
            throw SecretError.vaultFailed("cannot write the vault")
        }
    }

    private func read() throws -> Contents {
        try checkDirectory()
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return Contents() }
            throw SecretError.vaultFailed("cannot open the vault (errno \(errno))")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else {
            throw SecretError.vaultFailed("the vault is not a regular file owned by this user")
        }
        let data = try handle.readToEnd() ?? Data()
        guard let contents = try? JSONDecoder().decode(Contents.self, from: data) else {
            throw SecretError.vaultFailed("the vault file is corrupt")
        }
        return contents
    }

    /// The secrets directory, if it exists, must be a real directory (not a link).
    private func checkDirectory() throws {
        var st = stat()
        if lstat(directory.path, &st) != 0 {
            if errno == ENOENT { return }
            throw SecretError.vaultFailed("cannot inspect the vault directory (errno \(errno))")
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw SecretError.vaultFailed("the vault directory is not a directory") }
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST {
            throw SecretError.vaultFailed("cannot create the vault directory (errno \(errno))")
        }
        try checkDirectory()
        guard chmod(directory.path, 0o700) == 0 else { throw SecretError.vaultFailed("cannot protect the vault directory") }
    }
}

/// Reads a secret value for `brahma secret set`.
public enum SecretInput {
    /// Everything on `handle`, minus one trailing newline (`\n` or `\r\n`). Other whitespace is part of the value. Bytes
    /// that are not UTF-8 are refused (`SecretError.notUTF8`).
    public static func read(from handle: FileHandle) throws -> String {
        var bytes = Array(try handle.readToEnd() ?? Data())
        // "\r\n" is a single Character in Swift, so trim bytes.
        if bytes.suffix(2) == [0x0D, 0x0A] { bytes.removeLast(2) } else if bytes.last == 0x0A { bytes.removeLast() }
        guard !bytes.isEmpty else { throw SecretError.emptyValue }
        return try SecretValue.decode(Data(bytes))
    }
}

// MARK: Redactor

/// Replaces secret values with `[redacted NAME]` in any text that is about to be stored. Values shorter than
/// `minLength` are not redacted (they would mangle ordinary text). Three forms of each value are matched: raw,
/// percent-encoded and as `JSONEncoder` writes it inside a string (with and without escaped slashes). Longest first.
public final class Redactor: @unchecked Sendable {
    public static let minLength = 8

    private let lock = NSLock()
    private var entries: [(needle: String, replacement: String)] = []
    private var currentVersion = ""
    private var loadedOnce = false
    private var failed: [String] = []
    private var cache: [String: Loaded] = [:]
    private var logged: Set<String> = []
    private var noticeOpen = false
    private var failures: [Failure] = []
    private var tickets = 0
    private var installedTicket = 0
    /// Serializes whole reloads (metadata read, vault reads, install) of one store. `ownerLoadSecrets` bumps the secrets'
    /// `updatedAt` outside it and then takes it through `reloadRedactorIfNeeded`; recursive only so a reentrant caller can
    /// never deadlock on it.
    private let reloadLock = NSRecursiveLock()
    private var loader: (@Sendable () -> Void)?
    private var loaderTried = false
    // Background-read backoff (awake time): after a load with failures, the next background read waits `firstRetry`,
    // doubling to `maxRetry`; a different secrets version retries at once and restarts it.
    private var retryClock: @Sendable () -> TimeInterval = { AwakeTime.uptime() }
    private var attemptedVersion: String?
    private var retryDelay: TimeInterval = 0
    private var nextRetryAt: TimeInterval?
    public static let firstRetry: TimeInterval = 5
    public static let maxRetry: TimeInterval = 300

    /// One loaded value: the secret's name and the `updatedAt` it was loaded for (a retry reads only what failed or changed).
    public struct Loaded: Equatable, Sendable {
        public var name: String
        public var updatedAt: Date
        public var value: String
        public init(name: String, updatedAt: Date, value: String) { self.name = name; self.updatedAt = updatedAt; self.value = value }
    }

    public init() {}

    /// The secrets version of the last COMPLETE load (every secret's value loaded); "" before one.
    public var version: String {
        lock.lock(); defer { lock.unlock() }
        return currentVersion
    }

    /// Whether a complete load has happened in this process (a database with no secrets at open counts as one). Until
    /// then `Store.redact` throws: nothing redactable is stored unredacted (fail closed).
    public var hasLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return loadedOnce
    }

    /// The secrets whose values did not load at the last load (sorted names); they are retried on the next reload.
    public var failedNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return failed
    }

    /// Replaces the whole set of values: a complete load of `version`.
    public func update(_ values: [(name: String, value: String)], version: String) {
        let built = Self.build(values)
        lock.lock(); defer { lock.unlock() }
        tickets += 1
        installedTicket = tickets
        entries = built
        currentVersion = version
        loadedOnce = true
        failed = []
        failures = []
        cache = [:]
    }

    /// Installs a load: `loaded` are the values to redact (keyed `<companyId>:<name>`), `failed` the names that did not
    /// load. `version` is set (and the load counts as complete) only when nothing failed.
    /// Why one secret did not load: a read that needed the owner's permission (`brahma secret load` fixes it) or anything
    /// else (a missing item, a value that is not UTF-8, a vault error).
    public struct Failure: Equatable, Sendable {
        public var name: String
        public var reason: String
        public var needsPermission: Bool
    }

    /// Runs a whole reload under the store's reload lock.
    func withReloadLock<T>(_ body: () throws -> T) rethrows -> T {
        reloadLock.lock(); defer { reloadLock.unlock() }
        return try body()
    }

    /// A ticket for a load about to read the metadata: `install` rejects a load whose ticket is older than the installed one.
    public func beginLoad() -> Int {
        lock.lock(); defer { lock.unlock() }
        tickets += 1
        return tickets
    }

    /// Installs a load: `loaded` are the values to redact (keyed `<companyId>:<name>`), `failed` the names that did not
    /// load. `version` is set (and the load counts as complete) only when nothing failed. Returns false, changing nothing,
    /// when `ticket` is older than the installed load's: a slow, stale result never replaces a newer one.
    @discardableResult
    public func install(loaded: [String: Loaded], failed failedNames: [String], version: String?, ticket: Int? = nil,
                        failures details: [Failure] = []) -> Bool {
        let built = Self.build(loaded.values.sorted { $0.name < $1.name }.map { ($0.name, $0.value) })
        lock.lock(); defer { lock.unlock() }
        if let ticket {
            guard ticket >= installedTicket else { return false }
            installedTicket = ticket
        }
        failures = details
        entries = built
        cache = loaded
        failed = failedNames
        if let version {
            currentVersion = version
            loadedOnce = true
        }
        return true
    }

    /// A one-shot loader (`Store.redactorLoader`): the CLI's lazy load of the secrets.
    var lazyLoader: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return loader }
        set { lock.lock(); defer { lock.unlock() }; loader = newValue; loaderTried = false }
    }

    /// The loader, the first time it is asked for; nil afterwards (it runs at most once).
    func takeLoader() -> (@Sendable () -> Void)? {
        lock.lock(); defer { lock.unlock() }
        guard !loaderTried, let loader else { return nil }
        loaderTried = true
        return loader
    }

    /// Replaces the awake-time clock the retry backoff runs on (tests).
    public func setRetryClock(_ clock: @escaping @Sendable () -> TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        retryClock = clock
    }

    /// Whether a background read for `version` may run now: always for a version not attempted yet, else once the backoff
    /// has passed.
    func retryDue(version: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard version == attemptedVersion, let next = nextRetryAt else { return true }
        return retryClock() >= next
    }

    /// Records a load attempt of `version`: a failed one schedules the next background read (5 s, doubling to 5 min; a new
    /// version starts over), a complete one clears the backoff.
    func recordAttempt(version: String, failed: Bool) {
        lock.lock(); defer { lock.unlock() }
        if version != attemptedVersion { retryDelay = 0 }
        attemptedVersion = version
        if failed {
            retryDelay = retryDelay == 0 ? Self.firstRetry : min(retryDelay * 2, Self.maxRetry)
            nextRetryAt = retryClock() + retryDelay
        } else {
            retryDelay = 0
            nextRetryAt = nil
        }
    }

    /// Opens a hold episode (returns true the first time, so its owner notice is written once) or closes it when `held` is false.
    func holdEpisode(held: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard held else { noticeOpen = false; return false }
        if noticeOpen { return false }
        noticeOpen = true
        return true
    }

    /// Why each secret in `failedNames` did not load (by name).
    /// The failures of the last installed load (names and reasons, never values).
    public var lastFailures: [Failure] {
        lock.lock(); defer { lock.unlock() }
        return failures
    }

    func cachedValues() -> [String: Loaded] {
        lock.lock(); defer { lock.unlock() }
        return cache
    }

    /// Which of `failures` (keys) have not been logged yet; remembers them, and forgets keys that are no longer failing.
    func unlogged(_ failures: Set<String>) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let fresh = failures.subtracting(logged)
        logged = failures
        return fresh
    }

    private static func build(_ values: [(name: String, value: String)]) -> [(needle: String, replacement: String)] {
        var built: [(needle: String, replacement: String)] = []
        var seen = Set<String>()
        for (name, value) in values where value.count >= Self.minLength {
            for form in Self.forms(of: value) where seen.insert(form).inserted {
                built.append((form, "[redacted \(name)]"))
            }
        }
        built.sort { $0.needle.utf8.count > $1.needle.utf8.count }
        return built
    }

    private func snapshot() -> [(needle: String, replacement: String)] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    public func apply(_ s: String) -> String {
        var out = s
        for e in snapshot() where out.contains(e.needle) { out = out.replacingOccurrences(of: e.needle, with: e.replacement, options: .literal) }
        return out
    }

    /// Redacts every string leaf and every object key. Numbers, booleans and nulls are left alone. When a redacted key
    /// collides with another key of the same object, it gets a ` #2`, ` #3`, … suffix, so no member is dropped.
    public func applyJSON(_ v: JSONValue) -> JSONValue {
        switch v {
        case .string(let s): return .string(apply(s))
        case .array(let a): return .array(a.map(applyJSON))
        case .object(let o):
            var out: [String: JSONValue] = [:]
            // Unchanged keys first, so a key that needed no redaction always keeps its exact name.
            let keyed = o.map { (original: $0.key, redacted: apply($0.key), value: $0.value) }
            for member in keyed where member.redacted == member.original { out[member.original] = applyJSON(member.value) }
            for member in keyed.filter({ $0.redacted != $0.original }).sorted(by: { $0.original < $1.original }) {
                var key = member.redacted, n = 2
                while out[key] != nil { key = "\(member.redacted) #\(n)"; n += 1 }
                out[key] = applyJSON(member.value)
            }
            return .object(out)
        case .number, .bool, .null: return v
        }
    }

    /// Rewrites the file in place (same inode and permissions) when it contains a secret. Works on bytes, so a file
    /// with invalid UTF-8 keeps its other bytes exactly. Throws when the file cannot be read or written, and refuses a
    /// path that is not a regular file (a link planted where a check log should be is never written through).
    public func scrubFile(_ url: URL) throws {
        // A redactor that has not loaded cannot tell what to scrub: refusing is the only safe answer (the caller withholds the file).
        guard hasLoaded else { throw SecretError.secretsNotLoaded }
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path]) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSFilePathErrorKey: url.path]) }
        let original = try Data(contentsOf: url)
        var data = original
        for e in snapshot() {
            let needle = Data(e.needle.utf8)
            guard data.range(of: needle) != nil else { continue }
            data = data.replacing(needle, with: Data(e.replacement.utf8))
        }
        guard data != original else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
    }

    /// The raw value, its percent-encoded form (RFC 3986 unreserved characters stay), and its JSON-string forms.
    static func forms(of value: String) -> [String] {
        var out = [value]
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if let p = value.addingPercentEncoding(withAllowedCharacters: unreserved) { out.append(p) }
        for options in [JSONEncoder.OutputFormatting(), .withoutEscapingSlashes] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = options
            if let data = try? encoder.encode(value) {
                let text = String(decoding: data, as: UTF8.self)
                if text.count >= 2 { out.append(String(text.dropFirst().dropLast())) }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
}

// MARK: Leak patterns

public enum SecretScan {
    public static let patterns: [(label: String, ere: String)] = [
        ("aws-key", "AKIA[0-9A-Z]{16}"),
        ("private-key", "-----BEGIN [A-Z ]*PRIVATE KEY-----"),
        ("github-token", "gh[pousr]_[A-Za-z0-9]{36,}"),
        ("github-pat", "github_pat_[A-Za-z0-9_]{60,}"),
        ("slack-token", "xox[abprs]-[A-Za-z0-9-]{10,}"),
        ("openai-style", "sk-[A-Za-z0-9_-]{20,}"),
        ("stripe-live", "sk_live_[A-Za-z0-9]{20,}"),
        ("google-api", "AIza[0-9A-Za-z_-]{35}"),
    ]

    private static let compiled: [(label: String, regex: NSRegularExpression)] = patterns.compactMap { p in
        (try? NSRegularExpression(pattern: p.ere)).map { (p.label, $0) }
    }

    private static let hunkHeader = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)

    private static let commitMarker = try! NSRegularExpression(pattern: #"^commit ([0-9a-f]{40,64})$"#)

    /// One finding: what matched (`what`: the rule or `known secret NAME`), where (`place`: a path, `a file name`, `a commit
    /// message`), and the text shown (which may also name the commit and the line). Findings are the same finding when
    /// `what` and `place` agree (`key`), whichever commit or scan reported them first.
    struct Finding: Equatable {
        var what: String
        var place: String
        var text: String
        var key: String { "\(what)|\(place)" }
    }

    /// What the added lines of a unified diff (or of `git log -p` output, where `commit <hash>` lines name each commit)
    /// leak, as short text naming the rule (or the secret's name) and where. A finding never contains the matched text.
    /// Context and removed lines are not scanned; the `+++ b/path` header sets the path and the path itself is scanned (a
    /// file named after a secret is a finding); a line is told apart from a header by counting the lines each hunk
    /// declares, so an added line that happens to start with `++` is still scanned. Content git could not show as text
    /// (`Binary files … differ`, `GIT binary patch`) cannot be scanned and is a finding of its own (fail closed).
    ///
    /// The diff is parsed on BYTES (4-wire fix round 2, N2): lines split on `\n` only, one trailing `\r` is stripped (a CRLF
    /// line is its own line), and every prefix test is on the first byte(s), so a combining mark after the `+` (`+\u{200D}…`)
    /// cannot merge with the marker into one Character and hide the line. The rest of a line is decoded lossily for the
    /// patterns; known values are matched on the bytes. A (rule, place) pair is reported once.
    ///
    /// Known values shorter than `Redactor.minLength` are skipped, and each is matched raw, percent-encoded and
    /// JSON-escaped.
    public static func findings(diff: String, knownValues: [(String, String)]) -> [String] {
        scan(diff: diff, known: knownForms(knownValues)).map(\.text)
    }

    typealias KnownForms = [(name: String, forms: [[UInt8]])]

    static func knownForms(_ knownValues: [(String, String)]) -> KnownForms {
        knownValues.filter { $0.1.count >= Redactor.minLength }.map { ($0.0, Redactor.forms(of: $0.1).map { Array($0.utf8) }) }
    }

    static func scan(diff: String, known: KnownForms) -> [Finding] {
        var out: [Finding] = []
        var seen = Set<String>()
        var commit: String?
        var path: ArraySlice<UInt8> = ArraySlice("?".utf8)
        var lineNumber = 0
        var oldLeft = 0, newLeft = 0
        var previous: ArraySlice<UInt8> = []

        func report(_ what: String, where place: String? = nil, line: Bool = true) {
            let where_ = place ?? safePath(path, known: known)
            var detail: [String] = []
            if let commit { detail.append("commit \(commit.prefix(7))") }
            if line { detail.append("added line \(lineNumber)") }
            let f = Finding(what: what, place: where_, text: "\(what) in \(where_)" + (detail.isEmpty ? "" : " (\(detail.joined(separator: ", ")))"))
            if seen.insert(f.key).inserted { out.append(f) }
        }
        func scanAdded(_ added: ArraySlice<UInt8>) { for hit in matches(added, known: known) { report(hit) } }

        let bytes = Array(diff.utf8)
        for raw in bytes.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let line = raw.last == 0x0D ? raw.dropLast() : raw
            defer { previous = line }
            let first = line.first
            if oldLeft > 0 || newLeft > 0 {
                switch first {
                case 0x2B: newLeft -= 1; lineNumber += 1; scanAdded(line.dropFirst())   // "+"
                case 0x2D: oldLeft -= 1                                                   // "-"
                case 0x20: oldLeft -= 1; newLeft -= 1; lineNumber += 1                    // " "
                case 0x5C: break                                                          // "\ No newline at end of file"
                default: oldLeft = 0; newLeft = 0   // a truncated hunk: fall back to the bare-fragment rule below
                }
                if oldLeft > 0 || newLeft > 0 { continue }
                if first == 0x2B || first == 0x2D || first == 0x20 || first == 0x5C { continue }
            }
            if line.starts(with: "commit ".utf8) {
                let text = String(decoding: line, as: UTF8.self)
                if let m = commitMarker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range(at: 1), in: text) {
                    commit = String(text[r]); path = ArraySlice("?".utf8); lineNumber = 0
                    continue
                }
            }
            if line.starts(with: "@@".utf8) {
                let text = String(decoding: line, as: UTF8.self)
                if let m = hunkHeader.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                    func number(_ i: Int, default d: Int) -> Int {
                        Range(m.range(at: i), in: text).flatMap { Int(text[$0]) } ?? d
                    }
                    oldLeft = number(2, default: 1); newLeft = number(4, default: 1)
                    lineNumber = number(3, default: 1) - 1
                    continue
                }
            }
            if line.starts(with: "diff --git ".utf8) {
                // The file's names, from the header (`diff --git a/x b/x`): scanned even when the file has no text hunk
                // (an empty file, a mode change, a deletion). The whole header is matched as it stands, then the new name
                // (C-unquoted when git quoted it) is matched and becomes the path (4-wire fix round 3, R3).
                let halves = line.dropFirst("diff --git ".utf8.count)
                for hit in matches(halves, known: known) { report(hit, where: "a file name", line: false) }
                path = headerNewName(halves) ?? halves
                for hit in matches(path, known: known) { report(hit, where: "a file name", line: false) }
                continue
            }
            if line.starts(with: "+++ ".utf8) && previous.starts(with: "--- ".utf8) {
                var p = line.dropFirst(4)
                for hit in matches(p, known: known) { report(hit, where: "a file name", line: false) }
                if p.first == 0x22, let (unquoted, end) = cUnquote(p, from: p.startIndex), end == p.endIndex { p = unquoted[...] }
                if p.starts(with: "b/".utf8) { p = p.dropFirst(2) }
                path = p
                if !p.elementsEqual("/dev/null".utf8) { for hit in matches(p, known: known) { report(hit, where: "a file name", line: false) } }
                continue
            }
            if line.starts(with: "Binary files ".utf8) && line.reversed().starts(with: " differ".utf8.reversed())
                || line.elementsEqual("GIT binary patch".utf8) {
                report("unscannable binary content", line: false)
                continue
            }
            // Outside a counted hunk (a bare fragment): every `+` line is an added line.
            if first == 0x2B { lineNumber += 1; scanAdded(line.dropFirst()) }
        }
        return out
    }

    /// What commit objects leak beyond their patches (`GitWorkspace.scanMessages` output, `git log --pretty=raw`: a
    /// `commit <hash>` line, then every header of the object as stored — tree, parents, author, committer, and any extra
    /// header such as `gpgsig`, `mergetag` or a crafted one (4-wire fix round 3, R4) — then the message, indented by four
    /// spaces, which are taken off). Each commit's record is matched as a whole (a known value spanning lines is found
    /// too); findings name the commit, never the text.
    static func messageFindings(log: String, known: KnownForms) -> [Finding] {
        var out: [Finding] = []
        var seen = Set<String>()
        var commit: String?
        var record: [UInt8] = []
        func flush() {
            defer { record.removeAll(keepingCapacity: true) }
            guard !record.isEmpty else { return }
            for hit in matches(record[...], known: known) {
                let place = "a commit message or header"
                let f = Finding(what: hit, place: place, text: "\(hit) in \(place)" + (commit.map { " (commit \($0.prefix(7)))" } ?? ""))
                if seen.insert(f.key).inserted { out.append(f) }
            }
        }
        for raw in Array(log.utf8).split(separator: 0x0A, omittingEmptySubsequences: false) {
            let line = raw.last == 0x0D ? raw.dropLast() : raw
            if line.starts(with: "commit ".utf8) {
                let text = String(decoding: line, as: UTF8.self)
                if let m = commitMarker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range(at: 1), in: text) {
                    flush()
                    commit = String(text[r])
                    continue
                }
            }
            record.append(contentsOf: line.starts(with: "    ".utf8) ? line.dropFirst(4) : line); record.append(0x0A)
        }
        flush()
        return out
    }

    /// The rules and known secrets the bytes match: patterns on the lossy decoding, known values on the bytes themselves.
    private static func matches(_ bytes: ArraySlice<UInt8>, known: KnownForms) -> [String] {
        let text = String(decoding: bytes, as: UTF8.self)
        var hits: [String] = []
        for p in compiled where p.regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { hits.append(p.label) }
        for k in known where k.forms.contains(where: { lastIndex(of: $0, in: bytes) != nil }) { hits.append("known secret \(k.name)") }
        return hits
    }

    /// The new file's name (without `b/`) from a `diff --git` header remainder (`a/<old> b/<new>`): git C-quotes a name with
    /// a tab, a newline, `"`, `\` or a control character (`"b/…"`); with renames off both names are the same, which settles
    /// a path that itself contains ` b/`. Nil when the header cannot be read (the caller then uses the remainder as it is).
    static func headerNewName(_ halves: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
        func stripB(_ name: ArraySlice<UInt8>) -> ArraySlice<UInt8> { name.starts(with: "b/".utf8) ? name.dropFirst(2) : name }
        if halves.first == 0x22 {
            // `"a/…" "b/…"` or `"a/…" b/…`
            guard let (_, end) = cUnquote(halves, from: halves.startIndex), end < halves.endIndex, halves[end] == 0x20 else { return nil }
            let second = halves[(end + 1)...]
            if second.first == 0x22 {
                guard let (b, bEnd) = cUnquote(second, from: second.startIndex), bEnd == second.endIndex else { return nil }
                return stripB(b[...])
            }
            return stripB(second)
        }
        if halves.last == 0x22 {
            // `a/… "b/…"`: the quoted token that ends exactly at the end.
            var i = halves.startIndex
            while let at = halves[i...].firstIndex(of: 0x22) {
                if at > halves.startIndex, halves[at - 1] == 0x20, let (b, end) = cUnquote(halves, from: at), end == halves.endIndex {
                    return stripB(b[...])
                }
                i = at + 1
            }
            return nil
        }
        // Unquoted: `a/P b/P`, the same P twice (renames are off), whatever P contains.
        let n = halves.count
        if n >= 5, (n - 5) % 2 == 0, halves.starts(with: "a/".utf8) {
            let p = (n - 5) / 2, s = halves.startIndex
            let a = halves[(s + 2)..<(s + 2 + p)], sep = halves[(s + 2 + p)..<(s + 5 + p)], b = halves[(s + 5 + p)...]
            if sep.elementsEqual(" b/".utf8), a.elementsEqual(b) { return b }
        }
        if let at = lastIndex(of: Array(" b/".utf8), in: halves) { return halves[(at + 3)...] }
        return nil
    }

    /// Git's C-quoted string starting at `start` (a `"`): its bytes and the index just after the closing quote.
    static func cUnquote(_ bytes: ArraySlice<UInt8>, from start: Int) -> ([UInt8], Int)? {
        guard start < bytes.endIndex, bytes[start] == 0x22 else { return nil }
        var out: [UInt8] = []
        var i = start + 1
        while i < bytes.endIndex {
            let c = bytes[i]
            if c == 0x22 { return (out, i + 1) }
            if c == 0x5C {
                guard i + 1 < bytes.endIndex else { return nil }
                let e = bytes[i + 1]
                switch e {
                case UInt8(ascii: "a"): out.append(0x07); i += 2
                case UInt8(ascii: "b"): out.append(0x08); i += 2
                case UInt8(ascii: "t"): out.append(0x09); i += 2
                case UInt8(ascii: "n"): out.append(0x0A); i += 2
                case UInt8(ascii: "v"): out.append(0x0B); i += 2
                case UInt8(ascii: "f"): out.append(0x0C); i += 2
                case UInt8(ascii: "r"): out.append(0x0D); i += 2
                case UInt8(ascii: "0")...UInt8(ascii: "3"):
                    guard i + 3 < bytes.endIndex else { return nil }
                    let digits = bytes[(i + 1)...(i + 3)]
                    guard digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "7")).contains($0) }) else { return nil }
                    out.append(digits.reduce(0) { $0 &* 8 &+ ($1 - UInt8(ascii: "0")) }); i += 4
                default: out.append(e); i += 2   // \" and \\
                }
                continue
            }
            out.append(c); i += 1
        }
        return nil
    }

    /// Where `needle` last occurs in `hay` (an index of `hay`), or nil.
    private static func lastIndex(of needle: [UInt8], in hay: ArraySlice<UInt8>) -> Int? {
        guard let head = needle.first, needle.count <= hay.count else { return nil }
        var i = hay.endIndex - needle.count
        while i >= hay.startIndex {
            if hay[i] == head, hay[i..<(i + needle.count)].elementsEqual(needle) { return i }
            i -= 1
        }
        return nil
    }

    /// What the change `base..head` leaks, read through 3a's hardened git helper (`GitWorkspace.scanLog`/`scanDiff`/
    /// `scanMessages`: the engine's own git dir and config, never the worktree's `.git` file): every commit's added lines,
    /// the endpoint diff, and every commit's message and author/committer fields. A finding is reported once per (rule,
    /// place), whichever scan saw it first. Output git cut short at the capture limit cannot be scanned and is itself a
    /// finding (fail closed). Findings never carry a value.
    public static func check(git: GitWorkspace, base: String, head: String, knownValues: [(String, String)]) throws -> [String] {
        try checkFindings(git: git, base: base, head: head, knownValues: knownValues).map(\.text)
    }

    /// `check`'s findings with where each is (`Finding.place`: a path, `a commit message`, ...), for a refusal that lists the
    /// places (Plan X8's pre-push scan). A change too large to scan is one finding whose place is `the whole change`.
    static func checkFindings(git: GitWorkspace, base: String, head: String, knownValues: [(String, String)]) throws -> [Finding] {
        let known = knownForms(knownValues)
        // Every commit's added lines (a value committed and deleted later is in main's history all the same), then the
        // endpoint diff (content an evil merge introduces shows in no single commit's patch), then the messages (they land
        // in main's history with the commits).
        let log = try git.scanLog(base: base, head: head)
        let diff = try git.scanDiff(base: base, head: head)
        let messages = try git.scanMessages(base: base, head: head)
        var seen = Set<String>()
        var out: [Finding] = []
        for f in scan(diff: log.text, known: known) + scan(diff: diff.text, known: known) + messageFindings(log: messages.text, known: known)
        where seen.insert(f.key).inserted { out.append(f) }
        if log.cut || diff.cut || messages.cut {
            out.append(Finding(what: "too large", place: "the whole change",
                               text: "the change is too large to scan for secrets (more than \(diff.limitMB) MB of diff)"))
        }
        return out
    }

    /// The file path for a finding, unless the path itself holds a secret.
    private static func safePath(_ path: ArraySlice<UInt8>, known: KnownForms) -> String {
        if !matches(path, known: known).isEmpty { return "(path withheld)" }
        return String(decoding: path, as: UTF8.self)
    }
}
