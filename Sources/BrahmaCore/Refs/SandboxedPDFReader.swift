import Foundation

/// One part of a PDF as the sandboxed helper extracted it (`SandboxedPDFReader`): a stream decoded through its filters (or
/// left as the JPEG / JPEG 2000 data an image codec holds), every string's bytes, every string as text, every name, and the
/// page text.
public struct PDFPart: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case decodedStream = 0x44   // D
        case jpeg = 0x4A            // J
        case jpeg2000 = 0x50        // P
        case strings = 0x53         // S
        case texts = 0x55           // U
        case names = 0x4E           // N
        case pageText = 0x54        // T

        /// A stream's own bytes, which may hold another file (an archive, a PDF, an image) and are checked again.
        public var isStream: Bool { self == .decodedStream || self == .jpeg || self == .jpeg2000 }
    }

    public var kind: Kind
    public var data: Data

    public init(kind: Kind, data: Data) { self.kind = kind; self.data = data }
}

/// C2b fix round 5 (controller ruling 38): the helper found a structural anomaly (exit 5) but read the rest of the file;
/// `parts` is everything it read. The gate refuses it (`SandboxedPDFReader.unaccounted`, with the owner's vouch command)
/// at every level (C2b-carry (c), Ruling 42: a vouch no longer lifts it; a vouched PDF is served only as its flattened copy,
/// `flatten`, `Store.gatedBytes`).
public struct UnverifiedPDF: Error, Sendable {
    public let parts: [PDFPart]
    public init(parts: [PDFPart]) { self.parts = parts }
}

/// C2b fix rounds 2 and 3 (controller ruling 33): the engine never parses a PDF. `brahma-pdf` (PDFKit and CoreGraphics; see
/// its `main.swift`) runs under the engine's sandbox the way `SandboxedUnzipReader` runs unzip, on one private copy of the
/// file in a vault temp directory (`scratch`), with:
/// - a deny-default profile (`policy`): it may run nothing but itself (round 4, R4-4: no shell, no `head`, no fork), read
///   only the system's libraries, itself and that copy, write nothing (its output is the engine's pipe); no network, no
///   mach service;
/// - the leader of its own session (it can't leave its process group), run directly (`SandboxedRunner.runProgramBlocking`),
///   its exit status its own;
/// - a hard time limit, and a memory limit (`memoryLimit`, 1 GiB) the runner's watchdog enforces on the helper and its
///   group, besides the helper's own self-check (`helperMemoryLimit`);
/// - its standard output read by the engine up to the byte cap: one byte more and the run is killed and refused.
/// A helper that was killed, crashed, ran out of time or memory never reads as done; its output must hold together
/// exactly (`parse`); anything else refuses. The temp directory is removed whatever happens.
public struct SandboxedPDFReader: Sendable {
    public static let helperName = "brahma-pdf"
    public static let timeout: Duration = .seconds(60)
    static let partsName = "parts"
    static let header = Data("BRAHMA-PDF/1\n".utf8)

    static let unavailable = ArchiveReadError.refused("PDFs can't be scanned on this machine")
    static let unreadable = ArchiveReadError.refused("this PDF can't be read, so it can't be scanned for secrets")
    static let encrypted = ArchiveReadError.refused("this PDF is encrypted, so it can't be scanned for secrets")
    static let undecodable = ArchiveReadError.refused("this PDF has a stream that can't be decoded for scanning")
    /// Round 4 (R4-6, ruling 35): every structural anomaly the helper finds (exit 5) is this one refusal. Round 5 (ruling 38):
    /// the gate adds the exact command by which the owner can vouch for the file (`SecretGate.vouchHint`).
    static let unaccounted = ArchiveReadError.refused("this PDF's structure couldn't be verified")
    static let tooMany = ArchiveReadError.refused("this PDF has too many objects to scan for secrets")
    /// Breaker B-3: the refusals a vouch can't lift, since a vouch only lets the gate scan what the helper read, and here
    /// it read nothing usable. Not structure refusals (`SecretGate.isStructural`): they name no vouch command, record no
    /// refused version and raise no alert. An anomaly (exit 5) whose output does not hold together; a file with more
    /// revisions than the helper walks at all (exit 10, nothing read).
    static let unverifiedUnread = ArchiveReadError.refused("this PDF's structure couldn't be verified and nothing the PDF reader read of it holds together, so it can't be scanned for secrets, and it can't be vouched for: a vouch only lets Brahma scan what it read")
    static let tooManyRevisions = ArchiveReadError.refused("this PDF has more than 64 revisions, so it can't be scanned for secrets, and it can't be vouched for: nothing in it was read")
    static let tooMuchMemory = ArchiveReadError.refused("this PDF needs too much memory to scan for secrets")
    /// The two that may pass on another try (not cached by the gate).
    static let tooLong = ArchiveReadError.refused("this PDF took too long to scan for secrets")
    static let couldNotRun = ArchiveReadError.refused("the PDF reader could not run, so this PDF can't be scanned for secrets")
    /// The most memory one read may use: the run's process group, and the helper on its own.
    public static let memoryLimit = 1 << 30

    /// The sandbox of one read: `held` (the copy) the only tree it reads besides the system; the helper the only program
    /// (round 4: nothing else runs, nothing forks); the helper's directory listable (Foundation looks at its own bundle);
    /// no file it may write (`out` is the runner's own; the engine writes the helper's output there); the memory limit.
    /// Plan S Task S7: the factory's `.pdfReader` rule (spec §14.1's added site), over the three as verified places (each
    /// already resolved by the caller), engine principals, validated against `baseline` (the runner's).
    static func policy(helper: URL, held: URL, out: URL, memoryLimit: Int, baseline: SandboxBaseline) -> PolicyDecision {
        let places: PurposePlaces
        do {
            places = .pdfReader(helper: try Place.resolved(helper, kind: .file), held: try Place.resolved(held, kind: .directory),
                                out: try Place.resolved(out, kind: .directory))
        } catch {
            return .refused("the PDF reader's places are not safe to use (\(error))")
        }
        return SandboxPolicyFactory.decide(.pdfReader(memoryLimit: memoryLimit),
                                           principals: PrincipalSet(companyId: "", members: [.engine], ownerProfile: .sandboxed),
                                           places: places, network: .none, baseline: baseline)
    }

    let runner: any SandboxedRunner
    let helper: URL
    let scratch: @Sendable () throws -> URL
    let memoryLimit: Int
    let helperMemoryLimit: Int

    /// `helper` is the `brahma-pdf` binary (`locate`); `scratch` makes a fresh private directory for one read
    /// (`Vault.makeTempDir`).
    public init(runner: any SandboxedRunner, helper: URL, scratch: @escaping @Sendable () throws -> URL) {
        self.init(runner: runner, helper: helper, scratch: scratch, memoryLimit: Self.memoryLimit, helperMemoryLimit: Self.memoryLimit)
    }

    /// Tests set the two memory limits apart, to see each one stop a read on its own.
    init(runner: any SandboxedRunner, helper: URL, scratch: @escaping @Sendable () throws -> URL, memoryLimit: Int, helperMemoryLimit: Int) {
        self.runner = runner; self.helper = helper; self.scratch = scratch
        self.memoryLimit = memoryLimit; self.helperMemoryLimit = helperMemoryLimit
    }

    /// `brahma-pdf` beside `executable` (the engine's own binary: the CLI, or the app's, whose bundle carries it in
    /// `Contents/Helpers`), or nil.
    public static func locate(executable: URL, isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        let dir = executable.deletingLastPathComponent()
        let candidates = [dir.appending(path: helperName), dir.deletingLastPathComponent().appending(path: "Helpers/\(helperName)")]
        return candidates.first { isExecutable($0.path) }
    }

    /// The parts of the PDF `data`, at most `maxBytes` of output in all (`ArchiveMemberScan.overBudget` past it), within
    /// `timeout` (at most `SandboxedPDFReader.timeout`). Throws `ArchiveReadError`.
    public func parts(of data: Data, maxBytes: Int, timeout: Duration = SandboxedPDFReader.timeout) throws -> [PDFPart] {
        guard maxBytes > Self.header.count else { throw ArchiveMemberScan.overBudget }
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let held = dir.appending(path: "held", directoryHint: .isDirectory)
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        for d in [held, out] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        guard FileManager.default.createFile(atPath: held.appending(path: "input.pdf").path, contents: data,
                                             attributes: [.posixPermissions: 0o400]) else { throw Self.unreadable }
        let (heldDir, outDir) = (held.resolvedForSandbox, out.resolvedForSandbox)
        let program = helper.resolvedForSandbox
        let input = heldDir.appending(path: "input.pdf").path
        let policy = Self.policy(helper: program, held: heldDir, out: outDir, memoryLimit: memoryLimit, baseline: runner.policyBaseline())
        let environment = ChildEnvironment.make(base: ProcessInfo.processInfo.environment, purpose: .general)
        let limit = min(timeout, Self.timeout)
        // Round 4 (R4-4): the helper itself, no shell; the engine reads its output up to the cap (one byte more kills it).
        let outcome = runner.runProgramBlocking(arguments: [program.path, input, String(maxBytes), String(helperMemoryLimit)], cwd: outDir,
                                                environment: environment, timeout: limit, outputURL: dir.appending(path: "helper.log"),
                                                stdoutURL: outDir.appending(path: Self.partsName), stdoutCap: maxBytes, decision: policy)
        if outcome.tail.hasSuffix(GroupRun.memoryExceeded) { throw Self.tooMuchMemory }
        if outcome.tail.hasSuffix(GroupRun.outputExceeded) { throw ArchiveMemberScan.overBudget }
        if outcome.timedOut { throw Self.tooLong }
        guard let code = outcome.exitCode else { throw Self.couldNotRun }
        switch code {
        case 0: break
        case 3: throw Self.encrypted
        case 4: throw Self.undecodable
        case 5:
            // Round 5 (ruling 38): a structural anomaly, with everything the helper could read written out in full. The
            // parts are handed up as `UnverifiedPDF`, which the gate refuses (C2b-carry (c)). Output that
            // does not hold together can't be vouched for (breaker B-3: it says so, and names no vouch).
            guard let output = EngineFiles.readNoFollow(outDir.appending(path: Self.partsName), under: outDir, limit: maxBytes + 1),
                  let parts = try? Self.parse(output, maxBytes: maxBytes) else { throw Self.unverifiedUnread }
            throw UnverifiedPDF(parts: parts)
        case 6: throw ArchiveMemberScan.overBudget
        case 8: throw Self.tooMany
        case 9: throw Self.tooMuchMemory
        case 10: throw Self.tooManyRevisions
        default: throw Self.unreadable
        }
        guard let output = EngineFiles.readNoFollow(outDir.appending(path: Self.partsName), under: outDir, limit: maxBytes + 1) else {
            throw Self.unreadable
        }
        return try Self.parse(output, maxBytes: maxBytes)
    }

    // MARK: C2b-carry (c), Ruling 42: the flattened copy

    static let flatHeader = Data("BRAHMA-PDF-FLAT/1\n".utf8)
    /// The helper could not make the copy (CoreGraphics can't open or draw the file, it has no page, it is encrypted, too
    /// many pages, a copy past the cap, a crash, a kill, output that does not hold together).
    public static let flattenFailed = ArchiveReadError.refused("this PDF can't be flattened")

    /// The flattened copy of the PDF `data` (`brahma-pdf --flatten`): CoreGraphics' view of each page, drawn (vector) into a
    /// fresh PDF; only the page content survives. Run like `parts` (the same sandbox: deny-default, nothing else run, no
    /// fork, no file written, no network; the leader of its own session; the time and memory limits; standard output read
    /// up to the byte cap, `maxBytes`, one byte more and the run is killed). Throws `ArchiveReadError`: `flattenFailed`
    /// for anything but a copy that holds together; `tooLong` and `couldNotRun`, which may pass on another try.
    public func flatten(of data: Data, maxBytes: Int, timeout: Duration = SandboxedPDFReader.timeout) throws -> Data {
        guard maxBytes > Self.flatHeader.count + 8 else { throw ArchiveMemberScan.overBudget }
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let held = dir.appending(path: "held", directoryHint: .isDirectory)
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        for d in [held, out] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        guard FileManager.default.createFile(atPath: held.appending(path: "input.pdf").path, contents: data,
                                             attributes: [.posixPermissions: 0o400]) else { throw Self.flattenFailed }
        let (heldDir, outDir) = (held.resolvedForSandbox, out.resolvedForSandbox)
        let program = helper.resolvedForSandbox
        let input = heldDir.appending(path: "input.pdf").path
        let policy = Self.policy(helper: program, held: heldDir, out: outDir, memoryLimit: memoryLimit, baseline: runner.policyBaseline())
        let environment = ChildEnvironment.make(base: ProcessInfo.processInfo.environment, purpose: .general)
        let outcome = runner.runProgramBlocking(arguments: [program.path, "--flatten", input, String(maxBytes), String(helperMemoryLimit)],
                                                cwd: outDir, environment: environment, timeout: min(timeout, Self.timeout),
                                                outputURL: dir.appending(path: "helper.log"),
                                                stdoutURL: outDir.appending(path: Self.partsName), stdoutCap: maxBytes, decision: policy)
        if outcome.tail.hasSuffix(GroupRun.memoryExceeded) || outcome.tail.hasSuffix(GroupRun.outputExceeded) { throw Self.flattenFailed }
        if outcome.timedOut { throw Self.tooLong }
        guard let code = outcome.exitCode else { throw Self.couldNotRun }
        guard code == 0, let output = EngineFiles.readNoFollow(outDir.appending(path: Self.partsName), under: outDir, limit: maxBytes + 1)
        else { throw Self.flattenFailed }
        return try Self.parseFlat(output, maxBytes: maxBytes)
    }

    /// The flatten output: `BRAHMA-PDF-FLAT/1\n`, an 8-byte big-endian length, exactly that many bytes, which start with
    /// `%PDF-`. Anything else is `flattenFailed`.
    static func parseFlat(_ output: Data, maxBytes: Int) throws -> Data {
        let b = [UInt8](output)
        let h = flatHeader.count
        guard b.count <= maxBytes, b.count >= h + 8, Data(b[0..<h]) == flatHeader else { throw flattenFailed }
        var length: UInt64 = 0
        for k in 0..<8 { length = length << 8 | UInt64(b[h + k]) }
        guard length == UInt64(b.count - h - 8) else { throw flattenFailed }
        let pdf = Data(b[(h + 8)...])
        guard pdf.starts(with: EmbeddedContent.pdfMagic) else { throw flattenFailed }
        return pdf
    }

    /// The helper's output: `BRAHMA-PDF/1\n`, records (a kind byte, a 4-byte big-endian length, the payload), and an `E`
    /// record whose 8-byte payload counts the records before it, ending the output exactly. At most `maxBytes` in all.
    /// Anything else (a cut, an unknown kind, a wrong count, bytes after the end) is `unreadable`. Every length is checked
    /// against what is left before it is used: no input can make this trap.
    static func parse(_ output: Data, maxBytes: Int) throws -> [PDFPart] {
        guard output.count <= maxBytes else { throw ArchiveMemberScan.overBudget }
        let b = [UInt8](output)
        guard b.count >= header.count, Data(b[0..<header.count]) == header else { throw unreadable }
        var i = header.count
        var parts: [PDFPart] = []
        while true {
            guard b.count - i >= 5 else { throw unreadable }
            let kind = b[i]
            let length = Int(b[i + 1]) << 24 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 8 | Int(b[i + 4])
            i += 5
            guard length <= b.count - i else { throw unreadable }
            if kind == 0x45 {   // E
                guard length == 8 else { throw unreadable }
                var count: UInt64 = 0
                for k in 0..<8 { count = count << 8 | UInt64(b[i + k]) }
                guard i + 8 == b.count, count == UInt64(parts.count) else { throw unreadable }
                return parts
            }
            guard let k = PDFPart.Kind(rawValue: kind) else { throw unreadable }
            parts.append(PDFPart(kind: k, data: Data(b[i..<(i + length)])))
            i += length
        }
    }
}
