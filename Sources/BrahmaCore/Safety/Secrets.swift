import Foundation
#if canImport(Security)
import Security
#endif

// MARK: Names and errors

public enum SecretError: Error, Equatable, Sendable {
    case invalidName
    /// The name is one the engine itself sets in a child's environment (PATH, BRAHMA_*, DYLD_*, ...).
    case reservedName
    case emptyValue
    case unknownCompany
    case notFound
    case vaultUnavailable
    case vaultFailed(String)

    /// Plain text for the CLI and the app.
    public var message: String {
        switch self {
        case .invalidName: "invalid secret name: use A-Z, 0-9 and _, starting with a letter (2 to 64 characters)"
        case .reservedName: "that name is reserved: the engine sets it in every child's environment"
        case .emptyValue: "the secret value is empty"
        case .unknownCompany: "no such company"
        case .notFound: "no such secret"
        case .vaultUnavailable: "no secrets vault is available on this platform"
        case .vaultFailed(let detail): "the secrets vault failed: \(detail)"
        }
    }
}

public enum SecretName {
    /// `^[A-Z][A-Z0-9_]{1,63}$`, ASCII only.
    public static func isValid(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (2...64).contains(bytes.count), (0x41...0x5A).contains(bytes[0]) else { return false }
        return bytes.allSatisfy { (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x5F }
    }
}

// MARK: Vaults

/// Where secret values live. The database holds only names and flags, never a value.
public protocol SecretVault: Sendable {
    func set(companyId: String, name: String, value: String) throws
    func value(companyId: String, name: String) throws -> String?
    /// Deleting a secret that is not there is not an error.
    func delete(companyId: String, name: String) throws
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

public enum SecretVaults {
    public static func platformDefault() -> any SecretVault {
        #if canImport(Security)
        return KeychainVault()
        #else
        return UnavailableVault()
        #endif
    }
}

#if canImport(Security)
/// A generic-password Keychain item per secret: service `dev.brahma.secrets`, account `<companyId>:<name>`.
///
/// Same lessons as the owner-key store (`KeychainOwnerKeyStore`): the item is created with an access list that trusts
/// any application, so the app, the `brahma` CLI and the per-turn `brahma mcp` processes all read it without a
/// prompt, and the modern `SecItemUpdate` and `SecItemDelete` refuse an item another binary created
/// (errSecInvalidOwnerEdit), so replacing and deleting use the legacy per-item calls, which do not check the owner.
/// Every write is in place: a failed update leaves the old value. New items also carry
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (the login keychain accepts it next to the access list).
public struct KeychainVault: SecretVault {
    public static let service = "dev.brahma.secrets"

    public init() {}

    private func query(_ companyId: String, _ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: "\(companyId):\(name)"]
    }

    public func value(companyId: String, name: String) throws -> String? {
        var q = query(companyId, name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw SecretError.vaultFailed("read failed (OSStatus \(status))") }
        return String(data: data, encoding: .utf8)
    }

    public func set(companyId: String, name: String, value: String) throws {
        let data = Data(value.utf8)
        let q = query(companyId, name)
        let found = SecItemCopyMatching(q as CFDictionary, nil)
        if found == errSecSuccess {
            if SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return }
            var r = q
            r[kSecReturnRef as String] = true
            r[kSecMatchLimit as String] = kSecMatchLimitOne
            var ref: CFTypeRef?
            guard SecItemCopyMatching(r as CFDictionary, &ref) == errSecSuccess, let ref else {
                throw SecretError.vaultFailed("the existing item could not be read for update")
            }
            let status = data.withUnsafeBytes { raw in
                SecKeychainItemModifyAttributesAndData(ref as! SecKeychainItem, nil, UInt32(data.count), raw.baseAddress)
            }
            guard status == errSecSuccess else { throw SecretError.vaultFailed("update failed (OSStatus \(status))") }
            return
        }
        guard found == errSecItemNotFound else { throw SecretError.vaultFailed("lookup failed (OSStatus \(found))") }
        var access: SecAccess?
        guard SecAccessCreate("Brahma secret \(name)" as CFString, nil, &access) == errSecSuccess, let access else {
            throw SecretError.vaultFailed("the access list could not be created")
        }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccess as String] = access
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretError.vaultFailed("add failed (OSStatus \(status))") }
    }

    public func delete(companyId: String, name: String) throws {
        var q = query(companyId, name)
        q[kSecReturnRef as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let items = out as? [AnyObject] else { throw SecretError.vaultFailed("lookup failed (OSStatus \(status))") }
        for item in items {
            let s = SecKeychainItemDelete(item as! SecKeychainItem)
            guard s == errSecSuccess else { throw SecretError.vaultFailed("delete failed (OSStatus \(s))") }
        }
    }
}
#endif

/// Reads a secret value for `brahma secret set`.
public enum SecretInput {
    /// Everything on `handle`, minus one trailing newline (`\n` or `\r\n`). Other whitespace is part of the value.
    public static func read(from handle: FileHandle) throws -> String {
        var bytes = Array(try handle.readToEnd() ?? Data())
        // "\r\n" is a single Character in Swift, so trim bytes.
        if bytes.suffix(2) == [0x0D, 0x0A] { bytes.removeLast(2) } else if bytes.last == 0x0A { bytes.removeLast() }
        let text = String(decoding: bytes, as: UTF8.self)
        guard !text.isEmpty else { throw SecretError.emptyValue }
        return text
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

    public init() {}

    public var version: String {
        lock.lock(); defer { lock.unlock() }
        return currentVersion
    }

    /// Replaces the whole set of values.
    public func update(_ values: [(name: String, value: String)], version: String) {
        var built: [(needle: String, replacement: String)] = []
        var seen = Set<String>()
        for (name, value) in values where value.count >= Self.minLength {
            for form in Self.forms(of: value) where seen.insert(form).inserted {
                built.append((form, "[redacted \(name)]"))
            }
        }
        built.sort { $0.needle.utf8.count > $1.needle.utf8.count }
        lock.lock(); defer { lock.unlock() }
        entries = built
        currentVersion = version
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

    /// Redacts every string leaf. Keys, numbers, booleans and nulls are left alone.
    public func applyJSON(_ v: JSONValue) -> JSONValue {
        switch v {
        case .string(let s): .string(apply(s))
        case .array(let a): .array(a.map(applyJSON))
        case .object(let o): .object(o.mapValues(applyJSON))
        case .number, .bool, .null: v
        }
    }

    /// Rewrites the file in place (same inode and permissions) when it contains a secret. Works on bytes, so a file
    /// with invalid UTF-8 keeps its other bytes exactly. Throws when the file cannot be read or written.
    public func scrubFile(_ url: URL) throws {
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

    /// What the added lines of a unified diff leak, as short text naming the rule (or the secret's name) and where. A
    /// finding never contains the matched text. Context and removed lines are not scanned, and neither are the
    /// `+++ b/path` file headers; a line is told apart from a header by counting the lines each hunk declares, so an
    /// added line that happens to start with `++` is still scanned.
    ///
    /// Known values shorter than `Redactor.minLength` are skipped, and each is matched raw, percent-encoded and
    /// JSON-escaped.
    public static func findings(diff: String, knownValues: [(String, String)]) -> [String] {
        let known: [(name: String, forms: [String])] = knownValues.filter { $0.1.count >= Redactor.minLength }
            .map { ($0.0, Redactor.forms(of: $0.1)) }
        var out: [String] = []
        var seen = Set<String>()
        var path = "?"
        var lineNumber = 0
        var oldLeft = 0, newLeft = 0
        var previous = ""

        func report(_ what: String) {
            let where_ = safePath(path, known: known)
            let line = "\(what) in \(where_) (added line \(lineNumber))"
            if seen.insert("\(what)|\(where_)").inserted { out.append(line) }
        }
        func scan(_ added: String) {
            for p in compiled where p.regex.firstMatch(in: added, range: NSRange(added.startIndex..., in: added)) != nil {
                report(p.label)
            }
            for k in known where k.forms.contains(where: { added.contains($0) }) { report("known secret \(k.name)") }
        }

        for rawLine in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            defer { previous = line }
            if oldLeft > 0 || newLeft > 0 {
                switch line.first {
                case "+": newLeft -= 1; lineNumber += 1; scan(String(line.dropFirst()))
                case "-": oldLeft -= 1
                case " ": oldLeft -= 1; newLeft -= 1; lineNumber += 1
                case "\\": break   // "\ No newline at end of file"
                default: oldLeft = 0; newLeft = 0   // a truncated hunk: fall back to the bare-fragment rule below
                }
                if oldLeft > 0 || newLeft > 0 { continue }
                if line.first == "+" || line.first == "-" || line.first == " " || line.first == "\\" { continue }
            }
            if line.hasPrefix("@@"), let m = hunkHeader.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                func number(_ i: Int, default d: Int) -> Int {
                    Range(m.range(at: i), in: line).flatMap { Int(line[$0]) } ?? d
                }
                oldLeft = number(2, default: 1); newLeft = number(4, default: 1)
                lineNumber = number(3, default: 1) - 1
                continue
            }
            if line.hasPrefix("+++ ") && previous.hasPrefix("--- ") {
                path = String(line.dropFirst(4))
                if path.hasPrefix("b/") { path.removeFirst(2) }
                continue
            }
            // Outside a counted hunk (a bare fragment): every `+` line is an added line.
            if line.hasPrefix("+") { lineNumber += 1; scan(String(line.dropFirst())) }
        }
        return out
    }

    /// The file path for a finding, unless the path itself holds a secret.
    private static func safePath(_ path: String, known: [(name: String, forms: [String])]) -> String {
        let range = NSRange(path.startIndex..., in: path)
        if compiled.contains(where: { $0.regex.firstMatch(in: path, range: range) != nil }) { return "(path withheld)" }
        if known.contains(where: { $0.forms.contains(where: { path.contains($0) }) }) { return "(path withheld)" }
        return path
    }
}
