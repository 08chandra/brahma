import Foundation
import BrahmaCore

/// "Open in…" for a file the app does not render (Plan 4a Task 9c, hardening Task 9a's file card). LaunchServices follows
/// links and launches whatever it is handed, so an agent could swap the artifact's file for a link to an `.app`, a
/// `.command` or any executable and the owner's click would run it, unsandboxed. So the artifact's own path never reaches
/// `NSWorkspace`. Safe by construction first (fix round 1, M3): only the kinds that reach the file card are handed over at
/// all (`allowedKinds`: CAD, 3D models, images, by `ArtifactKind.from(ext:)`); anything else is refused by kind. Then, as a
/// second layer, a launch-capable extension (`refusedExtensions`, case-insensitively) is refused by name. At click time the
/// entry is opened with the preview readers' opener (`RendererCaps.openRegularFile`: `O_NOFOLLOW`, `S_IFREG` on the
/// descriptor) and refused when it is a link, a bundle or directory, carries an execute bit, has another hard link or another
/// owner (`EngineFiles.copyProblem`, S7), or is larger than the largest artifact. What passes is copied from that same
/// descriptor, so nothing is re-resolved by path, into the engine-only folder (`folder(paths:)`: `<home>/run/open-in`, 0700,
/// like L's dev host folder) under an engine-made name with the original's extension, mode 0600 (no execute bit), marked
/// `com.apple.quarantine` so Gatekeeper would still ask before launching anything (M4), and the copy is what the opener gets.
/// Every refusal has an engine-written message. "Reveal in Finder" (the artifact header) goes through the same `openCopy` with
/// Finder as the opener and `kinds: nil` (any artifact kind, since every artifact has that button): Finder is pointed at the
/// vetted copy, never at the agent's path, and `vet` disables the button up front with the reason.
public enum OpenInHandoff {
    /// The kinds the file card shows (`FileBody.make`: `.cad`, glTF too large to parse in process, image fallbacks): the only
    /// kinds "Open in…" hands to another app.
    public static let allowedKinds: Set<ArtifactKind> = [.cad, .model3d, .image]

    /// Extensions LaunchServices (or the usual default handler) would run rather than show: the brief's eight, then installers
    /// and disk images (`pkg`, `mpkg`, `dmg`), Java (`jar`, `jnlp`), shells (Terminal and iTerm register for them), scripts
    /// (`scpt`, `scptd`, `applescript`, `shortcut`), Windows executables and shortcuts (`exe`, `msi`, `bat`, `cmd`, `lnk`, `url`),
    /// and the bundle kinds a directory check would catch anyway (`action`, `plugin`, `bundle`, `framework`, `kext`,
    /// `prefpane`, `saver`, `service`, `wdgt`, `appex`, `osax`, `qlgenerator`, `xpc`). All lower case.
    public static let refusedExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "workflow", "webloc", "inetloc", "fileloc",
        "afploc", "ftploc", "mailloc", "newsloc", "atloc", "vncloc", "rdp",
        "mobileconfig", "configprofile",
        "pkg", "mpkg", "dmg", "iso", "img", "sparseimage", "sparsebundle", "cdr", "jar", "jnlp",
        "sh", "bash", "zsh", "csh", "tcsh", "ksh", "fish", "py", "pyw",
        "scpt", "scptd", "applescript", "shortcut", "webarchive",
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
        /// Not a kind the file card hands over (the lower-case extension).
        case kindNotHandedOver(String)
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
        case .kindNotHandedOver(let ext):
            ext.isEmpty ? "Not opened: the file has no artifact kind" : "Not opened: only CAD, 3D model and image files are handed to other apps (this is .\(ext))"
        case .unsafeFile(let problem): "Not opened: the file \(problem)"
        case .tooLarge: "Not opened: the file is larger than \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file))"
        case .unreadable: "Not opened: the file couldn't be read"
        case .copyFailed(let reason): "Not opened: a copy couldn't be made (\(reason))"
        case .noApp: "No app opens this kind of file"
        }
    }

    /// `<home>/run/open-in`: the engine-only folder the copies live in.
    public static func folder(paths: BrahmaPaths) -> URL { paths.runDir.appending(path: "open-in", directoryHint: .isDirectory) }

    /// Opens and vets `url` without copying: the open descriptor (the caller closes it), its stat and its lower-case extension,
    /// or why not. `kinds`: the artifact kinds handed over (`allowedKinds` for the file card's "Open in…"; nil for "Reveal in
    /// Finder": any kind in the table, since every artifact has that button). The launch-capable list applies either way.
    static func vetted(_ url: URL, kinds: Set<ArtifactKind>?) -> Result<(fd: Int32, stat: stat, ext: String), Refusal> {
        let ext = ArtifactKind.ext(of: url.lastPathComponent)
        if refusedExtensions.contains(ext) { return .failure(.launchable(ext)) }
        guard let kind = ArtifactKind.from(ext: ext), kinds?.contains(kind) ?? true else { return .failure(.kindNotHandedOver(ext)) }
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
        if st.st_mode & 0o111 != 0 { close(fd); return .failure(.executable) }
        if let problem = EngineFiles.copyProblem(st) { close(fd); return .failure(.unsafeFile(problem)) }
        if st.st_size > maxBytes { close(fd); return .failure(.tooLarge) }
        return .success((fd, st, ext))
    }

    /// Why `url` would be refused right now, or nil when it would be handed over (nothing is copied): what disables a button
    /// and shows the reason before the click. Cheap (an open, an fstat, a close).
    public static func vet(_ url: URL, kinds: Set<ArtifactKind>? = allowedKinds) -> Refusal? {
        switch vetted(url, kinds: kinds) {
        case .success(let opened): close(opened.fd); return nil
        case .failure(let refusal): return refusal
        }
    }

    /// Vets `url` and copies it into `folder` (created 0700): the copy's URL, or why not. Blocking (a copy of up to `maxBytes`):
    /// `openCopy` runs it off the main actor.
    public static func prepare(_ url: URL, into folder: URL, kinds: Set<ArtifactKind>? = allowedKinds) -> Result<URL, Refusal> {
        let fd: Int32, ext: String
        switch vetted(url, kinds: kinds) {
        case .success(let opened): (fd, ext) = (opened.fd, opened.ext)
        case .failure(let refusal): return .failure(refusal)
        }
        defer { close(fd) }
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
        // The copy's mode is set on its descriptor: no execute bit, whatever the umask did; and it is quarantined, so Gatekeeper
        // treats it as a download should anything launch-capable ever get this far (best effort: a refused xattr is no failure).
        _ = fchmod(out, 0o600)
        let quarantine = String(format: "0083;%08x;Brahma;", UInt32(Date().timeIntervalSince1970))
        _ = quarantine.withCString { fsetxattr(out, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        return .success(copy)
    }

    /// `prepare` off the main actor, then `opener` on the main actor with the copy (never the original). The copy's URL on
    /// success; `.noApp` when the opener declined. The one seam "Open in…" (the default app) and "Reveal in Finder" share.
    public static func openCopy(_ url: URL, into folder: URL, kinds: Set<ArtifactKind>? = allowedKinds,
                                opener: @escaping @MainActor @Sendable (URL) -> Bool) async -> Result<URL, Refusal> {
        let prepared = await Task.detached(priority: .userInitiated) { prepare(url, into: folder, kinds: kinds) }.value
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
