import Foundation

/// Why a sandbox scope (or a change to a company's sandbox settings) was refused.
public enum SandboxError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// A path a turn would run in, write or read equals, contains or lies inside a protected path (or equals or contains a
    /// path every turn is denied reading: the owner's home, the data home, `/Volumes`, `<ws>/.brahma`).
    case overlapsProtected(path: String, protected: String)
    case writableOutsideCompany(path: String)
    case dataHomeInsideWorkspace(String)
    /// The platform sandbox is missing (Tasks 1b/2).
    case unavailable
    /// A path holds `'`, `"`, `\`, a control character (NUL, tab, line breaks, ESC …), DEL or `%00`, which no sandbox
    /// profile, settings file or shell prefix may carry (`SandboxPath.isUnsafe`).
    case unsafePathCharacter(String)
    /// A domain that would route to Anthropic's API (`anthropic.com`, `claude.ai`, `claude.com` or a subdomain).
    case forbiddenDomain(String)
    /// Not a domain pattern the sandbox routes (the `DomainMatcher.isValidPattern` rules, Task 2).
    case invalidDomain(String)
    /// An agent handle that is not a safe single path component (3a's handle alphabet). Agent notes live under
    /// `notes/agents/`, so a handle can no longer name a team's or the company's notes file.
    case invalidHandle(String)
    /// A path that is not absolute (or `~`, `~/…`), or an item key that is not a valid key.
    case invalidPath(String)
    /// A place the turn would run in, write or read (its own lab, home, notes, worktree, admin dir, ref, progress file, plan
    /// directory) has a symbolic link at or above it inside the workspace: an agent can plant one, and following it would
    /// grant the turn whatever it names.
    case linkedPath(String)
    /// A path spelled through an alias namespace (`/System/Volumes/…`, `/.nofollow`, `/.resolve`, `/.vol`) that names another
    /// place: never an allowed entry; the real path must be used.
    case aliasSpelling(path: String, alias: String)

    public var description: String {
        switch self {
        case .overlapsProtected(let path, let protected): "\(path) overlaps the protected path \(protected)"
        case .writableOutsideCompany(let path): "\(path) is outside the company workspace and cannot be writable"
        case .dataHomeInsideWorkspace(let path): "the Brahma data home \(path) is inside a company workspace"
        case .unavailable: "the sandbox is not available on this Mac"
        case .unsafePathCharacter(let path): "the path \(path.debugDescription) holds a quote, a backslash or a control character"
        case .forbiddenDomain(let domain): "\(domain) routes to Anthropic's API and is never allowed"
        case .invalidDomain(let domain): "\(domain.debugDescription) is not a valid domain pattern"
        case .invalidHandle(let handle): "\(handle.debugDescription) cannot be an agent's sandbox handle"
        case .invalidPath(let path): "\(path.debugDescription) is not an absolute path"
        case .linkedPath(let path): "\(path) is a symbolic link where the sandbox expects a real file or directory"
        case .aliasSpelling(let path, let alias): "\(path) is an alias spelling (under \(alias)) of another path; use the real path"
        }
    }
    public var errorDescription: String? { description }
}
