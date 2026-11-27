import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Where the Claude CLI keeps its session transcripts: `<configDir>/projects/<encoded cwd>/<sessionId>.jsonl`.
///
/// The engine's subscription turns inherit `HOME` and `CLAUDE_CONFIG_DIR` from the engine's own environment (`ChildEnvironment`
/// admits both), so the CLI writes under `$CLAUDE_CONFIG_DIR` when that is set and `$HOME/.claude` otherwise. A gateway turn
/// runs with the agent's own config dir instead (Plan X1 Ruling 62): `TranscriptCapture.reading(configDir:)`. Tests pass a temp
/// directory: the owner's real `~/.claude` is never read by a test.
public struct TranscriptSource: Sendable, Equatable {
    public let configDir: URL
    public init(configDir: URL) { self.configDir = configDir }

    public var projectsDir: URL { configDir.appending(path: "projects", directoryHint: .isDirectory) }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> TranscriptSource {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return TranscriptSource(configDir: URL(fileURLWithPath: dir, isDirectory: true))
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return TranscriptSource(configDir: URL(fileURLWithPath: home, isDirectory: true).appending(path: ".claude", directoryHint: .isDirectory))
    }
}

/// Per-turn capture of the Claude session transcript into the data home: redacted, compressed, one file per turn.
///
/// A session's file grows across turns (`--resume`), so each turn stores only the bytes appended since the previous capture of
/// that session (`turnTranscript.byteEnd`), and only whole lines. Capture never fails a turn: every problem is an `Outcome`
/// and an activity line.
public struct TranscriptCapture: Sendable {
    public enum Outcome: Equatable, Sendable {
        case captured(TurnTranscript)
        /// Nothing complete was appended since the last capture.
        case nothingNew
        /// No transcript file for the session (or the session id is not one).
        case missing
        /// The redactor has not loaded every secret yet: nothing is written; the next capture continues from the stored position.
        case held
        case alreadyCaptured
        case failed(String)
    }

    public let paths: BrahmaPaths
    public private(set) var source: TranscriptSource
    /// Set by `reading(configDir:)` (a gateway turn's config dir, Ruling 63): no component of the path to the session file —
    /// from `/` through the config dir, `projects/` and the project folder to the file — may be a link.
    public private(set) var refusesLinkedComponents = false
    public let compressor: Compressor
    /// Upper bound on the bytes of one capture; the rest is taken by the next one.
    static let maxChunk = 256 * 1024 * 1024

    private let heldLogged = LoggedOnce()

    public init(paths: BrahmaPaths, source: TranscriptSource, compressor: Compressor = .platformDefault) {
        self.paths = paths; self.source = source; self.compressor = compressor
    }

    /// This capture reading `configDir` instead of the engine's own source: a gateway turn's isolated per-agent
    /// `CLAUDE_CONFIG_DIR` (`TurnRequest.gateway`, Plan X1 Ruling 62), where its `claude` writes the session. Itself when nil.
    public func reading(configDir: String?) -> TranscriptCapture {
        guard let configDir, !configDir.isEmpty else { return self }
        var copy = self
        copy.source = TranscriptSource(configDir: URL(fileURLWithPath: configDir, isDirectory: true))
        copy.refusesLinkedComponents = true
        return copy
    }

    /// Blocking (file reads and a compression process): the caller runs it inside a `Blocking` body.
    @discardableResult
    public func capture(turn: Turn, sessionId: String, store: Store, now: Date = Date()) -> Outcome {
        func note(_ text: String) {
            try? store.appendEvent(ActivityEvent(companyId: turn.companyId, agentId: turn.agentId, turnId: turn.id, kind: .error,
                                                 text: String(text.prefix(300)), createdAt: now))
        }
        // Fail closed: until every secret is loaded into the redactor nothing is written. The next capture of this session
        // continues from the stored `byteEnd`, so no bytes are lost.
        guard !store.secretsHeld else {
            if heldLogged.first() {
                note("transcript capture paused: secrets are not loaded yet; it continues from where it stopped once they are")
            }
            return .held
        }
        heldLogged.reset()
        // A gateway turn's config dir is the engine's (Ruling 63): a link on the way to its sessions means something tampered
        // with the run area. Nothing is read, and the owner is alerted (Ruling 64 minor).
        if refusesLinkedComponents, let linked = linkedComponent() {
            let text = "The transcript of a turn of agent \(turn.agentId) was not captured: \(linked) in its gateway config dir is a "
                + "link, which the engine never makes. Something changed the engine's run area; check it."
            do {
                try EngineAlerts.raise(store: store, text: text, now: now, reason: EngineAlerts.gatewayConfigReason,
                                       companyId: turn.companyId)
            } catch {
                note("the alert about a linked gateway config dir could not be raised: \(error)")
            }
            note("transcript not captured: \(linked) is a link")
            return .failed("\(linked) is a link")
        }
        do {
            guard Self.isSessionId(sessionId), let file = newestFile(sessionId: sessionId) else {
                note("no transcript found for session \(sessionId.prefix(80)); nothing captured for this turn")
                return .missing
            }
            if try store.transcript(turnId: turn.id) != nil { return .alreadyCaptured }
            var start = try store.lastTranscriptEnd(sessionId: sessionId) ?? 0
            let size = Int64(file.size)
            if size < start {
                note("transcript for session \(sessionId) was truncated or rotated; captured from the start")
                start = 0
            }
            guard size > start else { return .nothingNew }
            var slice = try Self.read(file.url, from: start, upTo: min(size, start + Int64(Self.maxChunk)))
            // Only whole lines: the writer may be mid-line.
            guard let lastNewline = slice.lastIndex(of: 0x0A) else { return .nothingNew }
            slice = slice.prefix(through: lastNewline)
            let redacted = redact(slice, with: store.redactor)
            let packed = try compressor.compress(redacted, workDir: paths.tmpDir)
            let relative = "transcripts/\(turn.companyId)/\(turn.agentId)/\(sessionId)/\(turn.id).jsonl.\(compressor.fileExtension)"
            try Self.writePrivate(packed, to: paths.home.appending(path: relative))
            let row = TurnTranscript(turnId: turn.id, companyId: turn.companyId, agentId: turn.agentId, sessionId: sessionId,
                                     path: relative, byteStart: start, byteEnd: start + Int64(slice.count), codec: compressor.codec,
                                     sha: StableHash.fnv1a64(redacted), capturedAt: now)
            try store.recordTranscript(row)
            return .captured(row)
        } catch {
            note("transcript capture failed: \(error)")
            return .failed("\(error)")
        }
    }

    /// A dev run (`ext try`, Task 10b): the session's transcript, redacted and compressed like a turn's, at
    /// `transcripts/<companyId>/dev-runs/<label>.jsonl.<ext>` (0600). No row: a dev run is never a team member's turn. Returns
    /// the path relative to the data home, or nil (secrets not loaded yet, no transcript, a write that failed). Blocking.
    public func captureDevRun(sessionId: String, companyId: String, label: String, store: Store) -> String? {
        guard !store.secretsHeld, Self.isSessionId(sessionId), Self.isSessionId(companyId), Self.isSessionId(label),
              let file = newestFile(sessionId: sessionId), file.size > 0,
              var slice = try? Self.read(file.url, from: 0, upTo: min(Int64(file.size), Int64(Self.maxChunk))),
              let lastNewline = slice.lastIndex(of: 0x0A) else { return nil }
        slice = slice.prefix(through: lastNewline)
        let redacted = redact(slice, with: store.redactor)
        guard let packed = try? compressor.compress(redacted, workDir: paths.tmpDir) else { return nil }
        let relative = "transcripts/\(companyId)/dev-runs/\(label).jsonl.\(compressor.fileExtension)"
        guard (try? Self.writePrivate(packed, to: paths.home.appending(path: relative))) != nil else { return nil }
        return relative
    }

    /// The decompressed, verified content of a captured turn.
    public func read(_ row: TurnTranscript) throws -> Data { try Self.read(row, paths: paths) }

    static func read(_ row: TurnTranscript, paths: BrahmaPaths) throws -> Data {
        let url = paths.home.appending(path: row.path)
        guard Self.isInside(url, root: paths.transcriptsDir) else { throw CompressorError.failed("\(row.path) is outside the transcripts directory") }
        let packed = try Data(contentsOf: url)
        let data = try Compressor.forCodec(row.codec).decompress(packed, workDir: paths.tmpDir)
        guard StableHash.fnv1a64(data) == row.sha else { throw CompressorError.failed("\(row.path) does not match its recorded hash") }
        return data
    }

    /// A company's captured turn as text (JSON lines, redacted when captured): the owner's replay pane (Plan ML Task 9). A
    /// turn of another company, or one with no capture, is not found. Blocking (decompression): call it off the main actor.
    public static func read(turnId: String, companyId: String, store: Store, paths: BrahmaPaths) throws -> String {
        guard let row = try store.transcript(turnId: turnId), row.companyId == companyId else {
            throw WorkError.notFound("no transcript was captured for that turn")
        }
        return String(decoding: try read(row, paths: paths), as: UTF8.self)
    }

    /// A readable form of one transcript record: who said what, tool calls by name and their input, tool results cut to 300
    /// characters. Records that carry no conversation are nil. The text is agent-controlled: callers sanitize it for display.
    public static func renderRecord(_ line: String) -> String? {
        guard let data = line.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String, type == "user" || type == "assistant",
              let message = object["message"] as? [String: Any] else { return nil }
        var parts: [String] = []
        if let text = message["content"] as? String {
            parts.append(text)
        } else if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks {
                switch block["type"] as? String {
                case "text": if let text = block["text"] as? String { parts.append(text) }
                case "tool_use":
                    let input = (block["input"]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
                        .map { String(decoding: $0, as: UTF8.self) } ?? ""
                    parts.append("[tool_use \(block["name"] as? String ?? "?") \(input.prefix(300))]")
                case "tool_result":
                    let body = (block["content"] as? String) ?? (block["content"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                        .map { String(decoding: $0, as: UTF8.self) } ?? ""
                    parts.append("[tool_result \(body.prefix(300))]")
                default: continue
                }
            }
        }
        guard !parts.isEmpty else { return nil }
        return "\(type): " + parts.joined(separator: "\n")
    }

    // MARK: Redaction

    /// Every line is parsed, its string leaves redacted (`applyJSON`: a secret that is JSON-escaped on disk or inside a
    /// `tool_result` string is found after decoding) and re-encoded. A line that changes nothing is kept byte for byte; one that
    /// does not parse is redacted as raw text.
    func redact(_ slice: Data, with redactor: Redactor) -> Data {
        var out = Data()
        out.reserveCapacity(slice.count)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let decoder = JSONDecoder()
        var lineStart = slice.startIndex
        while lineStart < slice.endIndex {
            let lineEnd = slice[lineStart...].firstIndex(of: 0x0A) ?? slice.endIndex
            let line = slice[lineStart..<lineEnd]
            if line.isEmpty || line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) {
                out.append(line)
            } else if let value = try? decoder.decode(JSONValue.self, from: line) {
                let cleaned = redactor.applyJSON(value)
                if cleaned == value { out.append(line) } else if let encoded = try? encoder.encode(cleaned) { out.append(encoded) }
                else { out.append(Data(redactor.apply(String(decoding: line, as: UTF8.self)).utf8)) }
            } else {
                out.append(Data(redactor.apply(String(decoding: line, as: UTF8.self)).utf8))
            }
            if lineEnd < slice.endIndex { out.append(0x0A) }
            lineStart = lineEnd < slice.endIndex ? slice.index(after: lineEnd) : lineEnd
        }
        return out
    }

    // MARK: Files

    /// A session id is what the CLI names a file: letters, digits, dashes and underscores.
    static func isSessionId(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 100 && text.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F
        }
    }

    /// `projects/*/<sessionId>.jsonl`, the newest by modification time. Links are not followed.
    func newestFile(sessionId: String) -> (url: URL, size: Int)? {
        let fm = FileManager.default
        if refusesLinkedComponents, !Self.isRealDirectoryPath(source.projectsDir) { return nil }
        guard let projects = try? fm.contentsOfDirectory(atPath: source.projectsDir.path) else { return nil }
        var best: (url: URL, size: Int, mtime: Double)?
        for name in projects.sorted() {
            if refusesLinkedComponents, !Self.isRealDirectory(source.projectsDir.appending(path: name)) { continue }
            let url = source.projectsDir.appending(path: name).appending(path: "\(sessionId).jsonl")
            var st = stat()
            guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            let mtime = Self.modificationTime(st)
            if best == nil || mtime > best!.mtime { best = (url, Int(st.st_size), mtime) }
        }
        return best.map { ($0.url, $0.size) }
    }

    /// The first link on the way to a gateway turn's sessions: a component of the config dir's path (from `/`), `projects/`,
    /// or a project folder in it; nil when there is none (a missing `projects/` is not a link).
    func linkedComponent() -> String? {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for part in source.configDir.path.split(separator: "/") {
            current = current.appending(path: String(part), directoryHint: .isDirectory)
            if Self.isLink(current) { return current.path }
        }
        if Self.isLink(source.projectsDir) { return source.projectsDir.path }
        guard Self.isRealDirectory(source.projectsDir),
              let names = try? FileManager.default.contentsOfDirectory(atPath: source.projectsDir.path) else { return nil }
        return names.sorted().map { source.projectsDir.appending(path: $0) }.first(where: Self.isLink)?.path
    }

    static func isLink(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// Every component of `url`'s absolute path, from `/`, is a real directory (`lstat`: never a link). The path is taken as
    /// written (never standardized, which on macOS swaps `/private/var` for the link `/var`); a `.` or `..` component fails.
    static func isRealDirectoryPath(_ url: URL) -> Bool {
        let path = url.path
        guard path.hasPrefix("/") else { return false }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for part in path.split(separator: "/") {
            guard part != ".", part != ".." else { return false }
            current = current.appending(path: String(part), directoryHint: .isDirectory)
            guard isRealDirectory(current) else { return false }
        }
        return true
    }

    static func isRealDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func modificationTime(_ st: stat) -> Double {
        #if canImport(Darwin)
        Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        #else
        Double(st.st_mtim.tv_sec) + Double(st.st_mtim.tv_nsec) / 1e9
        #endif
    }

    static func read(_ url: URL, from start: Int64, upTo end: Int64) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CompressorError.failed("cannot open \(url.lastPathComponent) (errno \(errno))") }
        defer { close(fd) }
        // S7: the session file sits where the agent can write; one with another hard link (an owner file linked in) or of
        // another user is never copied into the data home.
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw CompressorError.failed("cannot examine \(url.lastPathComponent) (errno \(errno))") }
        if let problem = EngineFiles.copyProblem(st) { throw CompressorError.failed("\(url.lastPathComponent) \(problem); not captured") }
        var remaining = Int(end - start)
        var data = Data(count: remaining)
        var done = 0
        while remaining > 0 {
            let n = data.withUnsafeMutableBytes { raw in pread(fd, raw.baseAddress! + done, remaining, off_t(start) + off_t(done)) }
            if n < 0 { if errno == EINTR { continue }; throw CompressorError.failed("cannot read \(url.lastPathComponent) (errno \(errno))") }
            if n == 0 { break }
            done += n; remaining -= n
        }
        return data.prefix(done)
    }

    /// A fresh 0600 file in the target's own directory (0700 directories), fsynced, then renamed into place.
    static func writePrivate(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try BrahmaPaths.ensurePrivateDirectory(dir)
        let staging = dir.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CompressorError.failed("cannot create \(url.lastPathComponent) (errno \(errno))") }
        var ok = fchmod(fd, 0o600) == 0
        var done = 0
        while ok && done < data.count {
            let n = data.withUnsafeBytes { raw in write(fd, raw.baseAddress! + done, data.count - done) }
            if n < 0 { if errno == EINTR { continue }; ok = false } else { done += n }
        }
        ok = ok && fsync(fd) == 0
        let closed = close(fd) == 0
        guard ok, closed, rename(staging.path, url.path) == 0 else {
            let code = errno
            unlink(staging.path)
            throw CompressorError.failed("cannot write \(url.lastPathComponent) (errno \(code))")
        }
    }

    static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path, base = root.standardizedFileURL.path
        return path.hasPrefix(base + "/") && !path.contains("/../")
    }
}

/// Logs a condition once until it clears.
private final class LoggedOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var logged = false
    func first() -> Bool { lock.withLock { defer { logged = true }; return !logged } }
    func reset() { lock.withLock { logged = false } }
}
