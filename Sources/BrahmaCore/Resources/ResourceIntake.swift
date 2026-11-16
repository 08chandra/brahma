import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The fail-closed inspection of an owner drop (§3.5, ML-4): nothing is copied here, every file is opened without following a
/// link, checked against the drop rules, given its default trust and secret-scanned through the descriptor its identity is
/// read from.
public enum ResourceIntake {
    public static let maxName = 120
    /// Directory entries a folder walk visits before the folder is refused whole (a bound on the walk itself).
    static let maxWalkEntries = 10_000

    static let symlinkRefusal = "symlinks can't be added"
    static let folderRefusal = "folders are limited to 500 files and 200 MB"
    static let executableRefusal = "executables can't be added as resources"
    static let playlistRefusal = "streaming playlists can't be added; add the video file"
    static let otherArchiveRefusal = "only .zip archives can be added"
    static let linkRefusal = "only http and https links can be added"
    static let notFileRefusal = "only files, folders and links can be added"
    /// iWork documents saved as packages (folders): never walked, so no part of one is added.
    static let iWorkPackageExt: Set<String> = ["numbers", "pages", "key"]

    static func iWorkPackage(_ display: String) -> String { "\(display) is an iWork package; export it to PDF first" }

    static func unsupported(ext: String) -> String {
        let tail = "aren't supported as resources (allowed: documents, images, video, tables, 3D, text and code, .zip)"
        return ext.isEmpty ? "files without an extension \(tail)" : ".\(ext) files \(tail)"
    }

    // MARK: Inspect

    /// `agentAreas` are where agents write (`Store.agentAreas(paths:)`): a file from inside one defaults to EXTERNAL
    /// (`DropTrust`), whatever its type.
    public static func inspect(urls: [URL], knownValues: [(name: String, value: String)], agentAreas: AgentAreas) throws -> DropPlan {
        var plan = DropPlan()
        for url in urls { inspectTop(url, single: urls.count == 1, knownValues: knownValues, areas: agentAreas, into: &plan) }
        plan.totalBytes = plan.items.reduce(0) { $0 + $1.bytes }
        plan.hasKnownValueFinding = plan.items.contains { $0.findings.contains(where: \.isKnownValue) }
        plan.hasPatternFinding = plan.items.contains { $0.findings.contains { !$0.isKnownValue } }
        return plan
    }

    private struct Root {
        let fd: Int32
        let url: URL
        let identity: FileIdentity
        /// The directory it was opened from, or one above it, is where agents write.
        let inAgentArea: Bool
    }

    private static func inspectTop(_ url: URL, single: Bool, knownValues: [(name: String, value: String)], areas: AgentAreas,
                                   into plan: inout DropPlan) {
        let std = url.standardizedFileURL
        let name = std.lastPathComponent
        let shown = sanitizeName(name)
        guard !name.isEmpty, name != "/", name != ".", name != "..", !name.contains("/") else {
            plan.refusals.append((shown, notFileRefusal)); return
        }
        let parent = std.deletingLastPathComponent()
        let rootFd = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFd >= 0 else { plan.refusals.append((shown, "\(shown) can't be read")); return }
        defer { close(rootFd) }
        var rst = stat(), st = stat()
        guard fstat(rootFd, &rst) == 0, fstatat(rootFd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            plan.refusals.append((shown, "\(shown) can't be read")); return
        }
        // Where agents write, by the identity of the directory the drop is opened from and every one above it.
        let root = Root(fd: rootFd, url: parent, identity: FileIdentity(rst), inAgentArea: areas.encloses(dirFd: rootFd))
        switch st.st_mode & S_IFMT {
        case S_IFLNK:
            plan.refusals.append((shown, symlinkRefusal))
        case S_IFREG:
            inspectFile(root, [name], walked: st, shown: shown, inAgentArea: root.inAgentArea, knownValues: knownValues,
                        into: &plan)
        case S_IFDIR:
            if name == ".git" { plan.skipped.append(shown); return }
            if ResourcePolicy.refusedExt.contains(ArtifactKind.ext(of: name)) { plan.refusals.append((shown, executableRefusal)); return }
            if iWorkPackageExt.contains(ArtifactKind.ext(of: name)) { plan.refusals.append((shown, iWorkPackage(shown))); return }
            let walked = inspectFolder(root, name, walked: st, shown: shown, areas: areas, knownValues: knownValues, into: &plan)
            if single && walked { plan.folderName = shown }
        default:
            plan.refusals.append((shown, notFileRefusal))
        }
    }

    /// Walks the folder without following anything, then inspects its files. Over the folder caps → refused whole. False
    /// when the folder as a whole was refused.
    private static func inspectFolder(_ root: Root, _ name: String, walked: stat, shown: String, areas: AgentAreas,
                                      knownValues: [(name: String, value: String)], into plan: inout DropPlan) -> Bool {
        let fd = openat(root.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { plan.refusals.append((shown, "\(shown) can't be read")); return false }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, FileIdentity(walked).sameFile(st) else {
            plan.refusals.append((shown, "\(shown) changed while it was being checked; add it again")); return false
        }

        var files: [(components: [String], st: stat, inAgentArea: Bool)] = []
        var skipped: [String] = []
        var refusals: [(name: String, reason: String)] = []
        var bytes: Int64 = 0, visited = 0
        var over = false, unreadable = false

        func walk(_ dfd: Int32, _ components: [String], depth: Int, inArea: Bool) {
            guard let names = DirectoryListing.names(fd: dfd, limit: maxWalkEntries - visited + 1) else {
                // The dropped folder itself: refused. A folder inside it: skipped and listed.
                if depth == 0 { unreadable = true } else { skipped.append(shownPath(components)) }
                return
            }
            for n in names.sorted() {
                if over { return }
                visited += 1
                if visited > maxWalkEntries { over = true; return }
                if n == ".DS_Store" { continue }
                let path = components + [n]
                var est = stat()
                guard fstatat(dfd, n, &est, AT_SYMLINK_NOFOLLOW) == 0 else { skipped.append(shownPath(path)); continue }
                switch est.st_mode & S_IFMT {
                case S_IFREG:
                    if n == ".git" { skipped.append(shownPath(path)); continue }
                    files.append((path, est, inArea))
                    bytes += Int64(est.st_size)
                    if files.count > ArtifactPolicy.maxFiles || bytes > Int64(ArtifactPolicy.maxFolderBytes) { over = true; return }
                case S_IFDIR:
                    if n == ".git" || depth + 1 > ResourcePolicy.maxDepth { skipped.append(shownPath(path)); continue }
                    if ResourcePolicy.refusedExt.contains(ArtifactKind.ext(of: n)) {
                        refusals.append((shownPath(path), executableRefusal)); continue
                    }
                    if iWorkPackageExt.contains(ArtifactKind.ext(of: n)) {
                        refusals.append((shownPath(path), iWorkPackage(sanitizeName(n)))); continue
                    }
                    let child = openat(dfd, n, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { skipped.append(shownPath(path)); continue }
                    var cst = stat()
                    if fstat(child, &cst) == 0, FileIdentity(est).sameFile(cst) {
                        walk(child, path, depth: depth + 1, inArea: inArea || areas.contains(cst))
                    } else {
                        skipped.append(shownPath(path))
                    }
                    close(child)
                default:
                    skipped.append(shownPath(path))   // a link (never followed), a FIFO, a socket, a device
                }
            }
        }
        walk(fd, [name], depth: 0, inArea: root.inAgentArea || areas.contains(st))
        if unreadable { plan.refusals.append((shown, "\(shown) can't be read")); return false }
        if over { plan.refusals.append((shown, folderRefusal)); return false }

        plan.skipped += skipped
        plan.refusals += refusals
        for f in files {
            inspectFile(root, f.components, walked: f.st, shown: shownPath(f.components), inAgentArea: f.inAgentArea,
                        knownValues: knownValues, into: &plan)
        }
        return true
    }

    /// Every check on one regular file, in order: refused extensions, other archives, playlists, unknown kinds, the size
    /// cap; then, on the descriptor opened without following anything (and required to be the file the walk saw):
    /// executable magic, the sniffer, the archive checks (zip and zip containers), quarantine, default trust and the secret
    /// scan. The identity is
    /// read before the reads and must be unchanged after them.
    private static func inspectFile(_ root: Root, _ components: [String], walked: stat, shown: String, inAgentArea: Bool,
                                    knownValues: [(name: String, value: String)], into plan: inout DropPlan) {
        func refuse(_ reason: String) { plan.refusals.append((shown, reason)) }
        let raw = components[components.count - 1]
        let display = sanitizeName(raw)
        let ext = ArtifactKind.ext(of: raw)
        if ResourcePolicy.refusedExt.contains(ext) { return refuse(executableRefusal) }
        if ResourcePolicy.otherArchives.contains(ext) { return refuse(otherArchiveRefusal) }
        if ArtifactKind.playlistExtensions.contains(ext) { return refuse(playlistRefusal) }
        let kind = ArtifactKind.from(ext: ext)
        let isZip = ext == "zip"
        guard kind != nil || isZip else { return refuse(unsupported(ext: ext)) }
        let isVideo = kind == .video
        let limit = Int64(isVideo ? ArtifactPolicy.maxVideoBytes : ArtifactPolicy.maxFileBytes)
        let overLimit = "\(display) is over the \(isVideo ? "500 MB" : "50 MB") limit"
        if Int64(walked.st_size) > limit { return refuse(overLimit) }

        let fd = openBeneath(root.fd, components)
        guard fd >= 0 else { return refuse("\(display) can't be read") }
        defer { close(fd) }
        let changed = "\(display) changed while it was being checked; add it again"
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return refuse("\(display) can't be read") }
        let identity = FileIdentity(st)
        guard identity.sameFile(walked) else { return refuse(changed) }
        if identity.size > limit { return refuse(overLimit) }

        guard let head = try? ContentScan.read(fd, at: 0, count: ArtifactSniffer.headBytes) else {
            return refuse("\(display) can't be read")
        }
        let headData = Data(head)
        if ResourcePolicy.isExecutable(head: headData) { return refuse(executableRefusal) }
        if isZip {
            guard ArtifactSniffer.isZip(headData) else { return refuse(ArtifactSniffer.mismatch(ext: ext)) }
        } else if let kind, !ArtifactSniffer.matches(kind: kind, ext: ext, head: headData) {
            return refuse(ArtifactSniffer.mismatch(ext: ext))
        }
        // A .zip and every zip container (docx, xlsx, key, usdz …) get the same archive checks: a renamed bomb is refused.
        if isZip || ArtifactKind.isZipContainer(ext: ext) {
            do {
                if let refusal = ArchiveRatio.refusal(try ArchiveRatio.stats(fd: fd)) { return refuse(refusal.message) }
            } catch {
                return refuse((error as? ArchiveError)?.message ?? ArchiveError.unreadable.message)
            }
        }

        let quarantined = Quarantine.isQuarantined(fd: fd)
        let trust = DropTrust.defaultProvenance(ext: ext, bytes: identity.size, quarantined: quarantined, inAgentArea: inAgentArea)
        let isText = !isZip && ArtifactKind.isText(ext: ext)
        guard let findings = try? ContentScan.scan(fd: fd, isText: isText, knownValues: knownValues) else {
            return refuse("\(display) can't be read")
        }
        var after = stat()
        guard fstat(fd, &after) == 0, FileIdentity(after) == identity else { return refuse(changed) }

        plan.items.append(DropItem(
            root: root.url, rootIdentity: root.identity, relativePath: components.joined(separator: "/"), identity: identity,
            displayName: display, ext: ext, fileKind: isZip ? "archive" : kind!.rawValue, bytes: identity.size, isText: isText,
            provenance: trust.provenance, tainted: trust.tainted, taintReason: trust.reason, quarantined: quarantined,
            findings: findings))
    }

    // MARK: Descriptors

    /// Opens `components` below the directory open at `dirFd`, one part at a time with `O_NOFOLLOW` (directories with
    /// `O_DIRECTORY`), so no link anywhere on the way is followed. The last part is opened read-only. -1 on any failure (a
    /// link, a missing part, a bad name). The caller closes the result.
    static func openBeneath(_ dirFd: Int32, _ components: [String]) -> Int32 {
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0") })
        else { return -1 }
        var current = dirFd
        for (i, part) in components.enumerated() {
            let last = i == components.count - 1
            let flags = last ? (O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) : (O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let next = openat(current, part, flags)
            if current != dirFd { close(current) }
            guard next >= 0 else { return -1 }
            current = next
        }
        return current
    }

    private static func shownPath(_ components: [String]) -> String { components.map(sanitizeName).joined(separator: "/") }

    // MARK: Names and links

    /// A name safe to show: NFC; control, format (bidi and zero-width) characters removed; whitespace runs collapsed to one
    /// space and trimmed; at most `maxName` characters, keeping the extension; `"file"` when nothing is left.
    public static func sanitizeName(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for u in s.precomposedStringWithCanonicalMapping.unicodeScalars {
            if u.properties.isWhitespace || u.properties.generalCategory == .lineSeparator
                || u.properties.generalCategory == .paragraphSeparator {
                pendingSpace = !out.isEmpty
                continue
            }
            switch u.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned: continue
            default: break
            }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(u)
        }
        var name = String(out).precomposedStringWithCanonicalMapping
        if name == "." || name == ".." || name.isEmpty { return "file" }
        if name.count > maxName {
            let ext = ArtifactKind.ext(of: name)
            if !ext.isEmpty, let dot = name.lastIndex(of: "."), dot != name.startIndex, ext.count + 1 < maxName {
                let suffix = String(name[dot...])
                let stem = String(name[..<dot].prefix(maxName - suffix.count)).trimmingCharacters(in: .whitespaces)
                name = (stem.isEmpty ? "file" : stem) + suffix
            } else {
                name = String(name.prefix(maxName)).trimmingCharacters(in: .whitespaces)
            }
        }
        return name.isEmpty ? "file" : name
    }

    /// A link the owner can add: `http`/`https` only, with a non-empty host, no control, format (bidi, zero-width) or other
    /// invisible characters, at most `ResourcePolicy.maxURL` characters; the user and password are removed and the scheme
    /// lowercased. Never fetched.
    public static func link(_ raw: String) throws -> String {
        let invalid = ResourceError.invalid(linkRefusal)
        // Only ASCII blanks are trimmed: Foundation's whitespace set also holds invisible characters (U+200B), which must
        // refuse the link rather than vanish from its ends.
        let s = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
        guard !s.isEmpty, s.count <= ResourcePolicy.maxURL else { throw invalid }
        for u in s.unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: throw invalid
            default: if u.properties.isWhitespace { throw invalid }
            }
        }
        guard var c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty else { throw invalid }
        c.scheme = scheme
        c.user = nil
        c.password = nil
        guard let out = c.string, out.count <= ResourcePolicy.maxURL else { throw invalid }
        return out
    }
}
