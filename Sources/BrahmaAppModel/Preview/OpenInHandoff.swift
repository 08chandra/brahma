import Foundation
import BrahmaCore

/// "Open in…" for a file the app does not render (Plan 4a Task 9c, hardening Task 9a's file card). LaunchServices follows
/// links and launches whatever it is handed, so an agent could swap the artifact's file for a link to an `.app`, a
/// `.command` or any executable and the owner's click would run it, unsandboxed. So the artifact's own path never reaches
/// `NSWorkspace`. At click time the entry is opened with the preview readers' opener (`RendererCaps.openRegularFile`:
/// `O_NOFOLLOW`, `S_IFREG` on the descriptor) and refused when it is a link, a bundle or directory, carries an execute bit,
/// has another hard link or another owner (`EngineFiles.copyProblem`, S7), is larger than the largest artifact, or carries a
/// launch-capable extension (`refusedExtensions`, case-insensitively). What passes is copied from that same descriptor, so
/// nothing is re-resolved by path, into the engine-only folder (`folder(paths:)`: `<home>/run/open-in`, 0700, like L's dev
/// host folder) under an engine-made name with the original's extension, mode 0600 (no execute bit), and the copy is what the
/// opener gets. Every refusal has an engine-written message.
public enum OpenInHandoff {
    /// Extensions LaunchServices (or the usual default handler) would run rather than show: the brief's eight, then installers
    /// and disk images (`pkg`, `mpkg`, `dmg`), Java (`jar`, `jnlp`), shells (Terminal and iTerm register for them), scripts
    /// (`scpt`, `scptd`, `applescript`, `shortcut`), Windows executables and shortcuts (`exe`, `msi`, `bat`, `cmd`, `lnk`, `url`),
    /// and the bundle kinds a directory check would catch anyway (`action`, `plugin`, `bundle`, `framework`, `kext`,
    /// `prefpane`, `saver`, `service`, `wdgt`, `appex`, `osax`, `qlgenerator`, `xpc`). All lower case.
    public static let refusedExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "workflow", "webloc", "inetloc", "fileloc",
        "pkg", "mpkg", "dmg", "jar", "jnlp",
        "sh", "bash", "zsh", "csh", "tcsh", "ksh", "fish",
        "scpt", "scptd", "applescript", "shortcut",
        "exe", "msi", "bat", "cmd", "lnk", "url",
        "action", "plugin", "bundle", "framework", "kext", "prefpane", "saver", "service", "wdgt", "appex", "osax", "qlgenerator", "xpc",
    ]

    /// The largest file handed over: the largest artifact (a video).
    public static let maxBytes = ArtifactPolicy.maxVideoBytes

    /// Copies older than this are removed from the folder at the next hand-off.
    public static let copyLifetime: TimeInterval = 24 * 3600

    /// Why the file was not handed over.
    public enum Refusal: Error, Equatable, Sendable {
        /// A link, a FIFO, a socket: not a regular file (nothing was followed).
        case notRegular
        case bundleOrDirectory
        /// Any execute bit.
        case executable
        /// A launch-capable extension (lower case).
        case launchable(String)
        /// `EngineFiles.copyProblem`: another hard link, another owner.
        case unsafeFile(String)
        case tooLarge
        /// Missing, or could not be opened or read.
        case unreadable
        /// The copy could not be written (the reason, engine-written).
        case copyFailed(String)
        /// The opener found no app for the copy.
        case noApp
    }

    /// The owner-facing line for a refusal (engine-written: nothing of the file's name or content is in it).
    public static func message(_ refusal: Refusal) -> String {
        switch refusal {
        case .notRegular: "Not opened: this isn't a regular file (a link or a special file was swapped in)"
        case .bundleOrDirectory: "Not opened: this is a folder or a bundle"
        case .executable: "Not opened: this file is marked executable"
        case .launchable(let ext): "Not opened: .\(ext) files can run programs"
        case .unsafeFile(let problem): "Not opened: the file \(problem)"
        case .tooLarge: "Not opened: the file is larger than \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file))"
        case .unreadable: "Not opened: the file couldn't be read"
        case .copyFailed(let reason): "Not opened: a copy couldn't be made (\(reason))"
        case .noApp: "No app opens this kind of file"
        }
    }

    /// `<home>/run/open-in`: the engine-only folder the copies live in.
    public static func folder(paths: BrahmaPaths) -> URL { paths.runDir.appending(path: "open-in", directoryHint: .isDirectory) }

    /// Vets `url` and copies it into `folder` (created 0700): the copy's URL, or why not. Blocking (a copy of up to `maxBytes`):
    /// `open` runs it off the main actor.
    public static func prepare(_ url: URL, into folder: URL) -> Result<URL, Refusal> {
        let ext = ArtifactKind.ext(of: url.lastPathComponent)
        if refusedExtensions.contains(ext) { return .failure(.launchable(ext)) }
        let fd: Int32, st: stat
        do {
            (fd, st) = try RendererCaps.openRegularFile(url)
        } catch RendererCaps.FileReadFailure.notRegular {
            // A directory opens read-only; say which it was.
            var lst = stat()
            if lstat(url.path, &lst) == 0, lst.st_mode & S_IFMT == S_IFDIR { return .failure(.bundleOrDirectory) }
            return .failure(.notRegular)
        } catch {
            return .failure(.unreadable)
        }
        defer { close(fd) }
        if st.st_mode & 0o111 != 0 { return .failure(.executable) }
        if let problem = EngineFiles.copyProblem(st) { return .failure(.unsafeFile(problem)) }
        if st.st_size > maxBytes { return .failure(.tooLarge) }
        do {
            try BrahmaPaths.ensurePrivateDirectory(folder)
        } catch {
            return .failure(.copyFailed("the folder couldn't be made"))
        }
        sweep(folder)
        let copy = folder.appending(path: copyName(for: url.lastPathComponent, ext: ext))
        let out = open(copy.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else { return .failure(.copyFailed(String(cString: strerror(errno)))) }
        defer { close(out) }
        // The source descriptor is still non-blocking from the opener; a regular file never blocks anyway.
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var copied = 0
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n == 0 { break }
            guard n > 0 else {
                if errno == EINTR { continue }
                unlink(copy.path)
                return .failure(.copyFailed("read: " + String(cString: strerror(errno))))
            }
            copied += n
            guard copied <= maxBytes else { unlink(copy.path); return .failure(.tooLarge) }
            var offset = 0
            while offset < n {
                let w = buffer.withUnsafeBytes { write(out, $0.baseAddress! + offset, n - offset) }
                guard w >= 0 else {
                    if errno == EINTR { continue }
                    unlink(copy.path)
                    return .failure(.copyFailed("write: " + String(cString: strerror(errno))))
                }
                offset += w
            }
        }
        // The copy's mode is set on its descriptor: no execute bit, whatever the umask did.
        _ = fchmod(out, 0o600)
        return .success(copy)
    }

    /// `prepare` off the main actor, then `opener` on the main actor with the copy (never the original). The copy's URL on
    /// success; `.noApp` when the opener declined.
    public static func openCopy(_ url: URL, into folder: URL, opener: @escaping @MainActor @Sendable (URL) -> Bool) async -> Result<URL, Refusal> {
        let prepared = await Task.detached(priority: .userInitiated) { prepare(url, into: folder) }.value
        guard case .success(let copy) = prepared else { return prepared }
        return await opener(copy) ? .success(copy) : .failure(.noApp)
    }

    /// An engine-made name: the original's base reduced to ASCII letters, digits, `-` and `_` (at most 48 of them; `file` when
    /// nothing is left), a short unique token, and the original's extension when it is a plain one (ASCII letters and digits,
    /// at most 16) so the right app opens it.
    static func copyName(for original: String, ext: String) -> String {
        let stem = ext.isEmpty ? original : String(original.dropLast(ext.count + 1))
        var base = String(stem.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            return c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_") ? c : "-"
        }.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if base.isEmpty { base = "file" }
        let token = UUID().uuidString.lowercased().prefix(8)
        let plain = ext.range(of: "^[a-z0-9]{1,16}$", options: .regularExpression) != nil
        return plain ? "\(base)-\(token).\(ext)" : "\(base)-\(token)"
    }

    /// Removes copies older than `copyLifetime` (regular files only, by `unlink`, which follows nothing).
    static func sweep(_ folder: URL, now: Date = Date()) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let path = folder.appending(path: name).path
            var st = stat()
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            if now.timeIntervalSince(modified) > copyLifetime { unlink(path) }
        }
    }
}
