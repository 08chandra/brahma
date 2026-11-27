import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// An engine-only credential (Ruling X8-17), held for one operation. Opaque: not `Codable`; `description`, `debugDescription`
/// and its mirror never show the value; the only way out is `withPipe`, which writes it once into a pipe whose read end the
/// caller hands to one child (the push's credential helper reads it there). It is built from the secret store at the moment of
/// use (`load`), never from this process's environment.
public final class TokenHandle: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Immutable after init.
    private let bytes: [UInt8]

    /// Nil for a value the credential protocol cannot carry: empty, longer than 4096 bytes, or holding a newline, a NUL or any
    /// other control character.
    init?(value: String) {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 4096, bytes.allSatisfy({ $0 >= 0x20 && $0 != 0x7F }) else { return nil }
        self.bytes = bytes
    }

    public var description: String { "TokenHandle(…)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .class) }

    /// Reads an engine-only secret of the company (`SecretName.engineOnly`) from the vault without prompting. Refused when the
    /// name is not engine-only, when its metadata row is missing or marks it a test key (a test key may have been put in an
    /// agent's environment), and when the vault has no usable value.
    public static func load(companyId: String, name: String, store: Store, vault: any SecretVault) throws -> TokenHandle {
        guard SecretName.engineOnly.contains(name) else { throw SecretError.notInjectable }
        guard let meta = try store.secrets(companyId: companyId).first(where: { $0.name == name }) else { throw SecretError.notFound }
        guard !meta.isTest else { throw SecretError.engineOnly }
        guard let value = try vault.nonInteractive().value(companyId: companyId, name: name) else { throw SecretError.notFound }
        guard let handle = TokenHandle(value: value) else { throw SecretError.vaultFailed("\(name) is not a value the push can use") }
        return handle
    }

    /// A pipe holding the value and a newline, its write end already closed, so a reader sees the value once and then end of
    /// file. Both ends are close-on-exec: only a child the caller explicitly hands `fd` to gets it. The read end is closed when
    /// `body` returns.
    public func withPipe<T>(_ body: (_ fd: Int32) throws -> T) throws -> T {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw SecretError.vaultFailed("cannot make the credential pipe (\(String(cString: strerror(errno))))") }
        let (readEnd, writeEnd) = (fds[0], fds[1])
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
        defer { close(readEnd) }
        let line = bytes + [0x0A]
        var written = 0
        let failure: String? = line.withUnsafeBytes { buffer in
            while written < buffer.count {
                let n = write(writeEnd, buffer.baseAddress! + written, buffer.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    return String(cString: strerror(errno))
                }
                written += n
            }
            return nil
        }
        close(writeEnd)
        if let failure { throw SecretError.vaultFailed("cannot write the credential pipe (\(failure))") }
        return try body(readEnd)
    }

    /// `text` with every occurrence of the value replaced: for output a child wrote (git's stderr), shown or stored after this.
    func redact(_ text: String) -> String {
        let value = String(decoding: bytes, as: UTF8.self)
        return text.replacingOccurrences(of: value, with: "[redacted token]")
    }
}
