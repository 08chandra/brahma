import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Why a release step refused (Plan L Task 7). The text is what the release records as its failure.
public enum ReleaseError: Error, Equatable, CustomStringConvertible {
    /// The build's output cannot be staged for upload (`UploadStager`).
    case stage(String)

    public var message: String {
        switch self {
        case .stage(let m): m
        }
    }

    public var description: String { message }
}

/// Copies what a release uploads from the build's export into the release's engine-only `upload/` folder (builder-check 4):
/// only regular files and directories, so the provider CLI started there with the token sees exactly the built site and no
/// repository or provider config.
///
/// - Every dot entry is skipped except `.well-known` (a `.git`, `.vercel`, `.wrangler`, `.DS_Store` never reaches the upload).
/// - Before that rule (PR-10), any `.env` or `.env.*` entry anywhere refuses the whole stage: an env file is a mistake, never
///   silently dropped.
/// - `node_modules` is never staged, at any depth (the Task 7 stager ruling; checked after the env-file refusal).
/// - A symbolic link refuses it (the engine never follows one, here or later), and so does a file with a second hard link (a
///   sandboxed build could link a file it cannot read into its output and have the engine copy it, S7), one another user
///   owns, or anything that is not a file or a directory.
/// - The caps (500 MB, 20 000 files) are checked over the whole set before anything is written.
///
/// Every refusal is decided before the first byte is copied; nothing is followed (each source file is opened through the
/// engine's descriptor walk, `EngineFiles.openFileNoFollow`, which checks it again on the open descriptor).
public enum UploadStager {
    public static let maxBytes = 524_288_000
    public static let maxFiles = 20_000

    static let capMessage = "output is larger than 500 MB or 20 000 files"
    /// The one dot entry that is staged (RFC 8615 metadata such as `security.txt`).
    static let keptDotEntry = ".well-known"

    /// Stages `dirs` (export-relative; `"."` is the whole export) of `export` into `upload`, which must not exist yet.
    public static func stage(from export: URL, dirs: [String], into upload: URL) throws {
        try stage(from: export, dirs: dirs, into: upload, maxBytes: maxBytes, maxFiles: maxFiles)
    }

    struct Plan {
        var dirs: [String] = []
        var files: [String] = []
        var seen = Set<String>()
        var bytes = 0
    }

    /// `stage` with its caps given (tests).
    static func stage(from export: URL, dirs: [String], into upload: URL, maxBytes: Int, maxFiles: Int) throws {
        var plan = Plan()
        for dir in dirs {
            let rel = try root(of: dir, in: export)
            if !rel.isEmpty, plan.seen.insert(rel).inserted { plan.dirs.append(rel) }
            try walk(export, rel, into: &plan, maxBytes: maxBytes, maxFiles: maxFiles)
        }
        var st = stat()
        guard lstat(upload.path, &st) != 0 else { throw ReleaseError.stage("the upload folder \(upload.path) already exists") }
        try EngineFiles.directory(workspace: upload.deletingLastPathComponent(), upload.lastPathComponent, mode: 0o755)
        for dir in plan.dirs { try EngineFiles.directory(workspace: upload, dir, mode: 0o755) }
        for file in plan.files { try copy(file, from: export, to: upload) }
    }

    /// The export-relative folder `dir` names ("" for the export itself), checked part by part without following a link.
    static func root(of dir: String, in export: URL) throws -> String {
        let missing = ReleaseError.stage("output_dir \(dir) was not produced by the build")
        let parts = dir.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        guard !parts.contains(".."), !dir.hasPrefix("/") else { throw missing }
        var rel = ""
        for part in parts {
            rel = rel.isEmpty ? part : rel + "/" + part
            if isEnvFile(part) { throw envRefusal(rel) }
            var st = stat()
            guard lstat(export.appending(path: rel).path, &st) == 0 else { throw missing }
            if st.st_mode & S_IFMT == S_IFLNK { throw ReleaseError.stage("output contains a symlink: \(rel)") }
            guard st.st_mode & S_IFMT == S_IFDIR else { throw missing }
        }
        return rel
    }

    static func isEnvFile(_ name: String) -> Bool {
        let n = name.lowercased()       // APFS is case-insensitive: `.ENV` is `.env`
        return n == ".env" || n.hasPrefix(".env.")
    }

    /// `node_modules` (any case: APFS is case-insensitive).
    static func isDependencyTree(_ name: String) -> Bool { name.lowercased() == "node_modules" }

    static func envRefusal(_ rel: String) -> ReleaseError {
        .stage("output contains \(rel); env files are never deployed")
    }

    private static func walk(_ export: URL, _ rel: String, into plan: inout Plan, maxBytes: Int, maxFiles: Int) throws {
        let dir = rel.isEmpty ? export : export.appending(path: rel, directoryHint: .isDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        for name in names {
            let path = rel.isEmpty ? name : rel + "/" + name
            // PR-10: env files are refused before the dot-entry rule (or the node_modules rule) could skip them.
            if isEnvFile(name) { throw envRefusal(path) }
            if name.hasPrefix("."), name != keptDotEntry { continue }
            // The Task 7 stager ruling: a dependency tree is never staged, at any depth and whatever it is (npm's `.bin` links
            // would otherwise refuse every Vercel "." stage); the provider builds or serves from the output, and the engine's
            // own tools never come from the repo.
            if isDependencyTree(name) { continue }
            var st = stat()
            guard lstat(export.appending(path: path).path, &st) == 0 else {
                throw ReleaseError.stage("output changed while it was staged: \(path)")
            }
            switch st.st_mode & S_IFMT {
            case S_IFLNK:
                throw ReleaseError.stage("output contains a symlink: \(path)")
            case S_IFDIR:
                if plan.seen.insert(path).inserted { plan.dirs.append(path) }
                try walk(export, path, into: &plan, maxBytes: maxBytes, maxFiles: maxFiles)
            case S_IFREG:
                if st.st_nlink > 1 { throw ReleaseError.stage("output contains a hard link: \(path)") }
                if let problem = EngineFiles.copyProblem(st) { throw ReleaseError.stage("output contains \(path), which \(problem)") }
                guard plan.seen.insert(path).inserted else { continue }
                plan.files.append(path)
                plan.bytes += Int(st.st_size)
                if plan.files.count > maxFiles || plan.bytes > maxBytes { throw ReleaseError.stage(capMessage) }
            default:
                throw ReleaseError.stage("output contains something that is not a file or a folder: \(path)")
            }
        }
    }

    /// Copies one planned file: the source opened through the descriptor walk (no link followed; regular, a single link,
    /// this user's, checked on the open descriptor), the copy created new (`O_EXCL`, never through a link).
    private static func copy(_ rel: String, from export: URL, to upload: URL) throws {
        guard let source = try EngineFiles.openFileNoFollow(under: export, rel, flags: O_RDONLY) else {
            throw ReleaseError.stage("output changed while it was staged: \(rel)")
        }
        defer { close(source) }
        let target = open(upload.appending(path: rel).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard target >= 0 else { throw ReleaseError.stage("could not stage \(rel) (\(String(cString: strerror(errno))))") }
        defer { close(target) }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw ReleaseError.stage("could not read \(rel) (\(String(cString: strerror(errno))))")
            }
            if n == 0 { return }
            var offset = 0
            while offset < n {
                let w = buffer.withUnsafeBytes { Foundation.write(target, $0.baseAddress! + offset, n - offset) }
                if w < 0 {
                    if errno == EINTR { continue }
                    throw ReleaseError.stage("could not stage \(rel) (\(String(cString: strerror(errno))))")
                }
                offset += w
            }
        }
    }
}
