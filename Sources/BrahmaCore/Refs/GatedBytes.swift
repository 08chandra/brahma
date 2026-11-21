import Foundation
import GRDB

/// C2b-carry (c), controller Ruling 42: what a caller may pin, share, copy, render or serve for some bytes after the secret
/// gate (`Store.gatedBytes`). For anything but a PDF the owner vouched for, the bytes themselves; for such a PDF, its
/// flattened copy, never the original.
public struct GatedBytes: Equatable, Sendable {
    /// The bytes to serve.
    public let data: Data
    /// `data`'s SHA-256 (the copy's own for a flattened copy).
    public let sha256: String
    /// `data`'s extension (`pdf` for a flattened copy).
    public let ext: String
    /// The gate's verdict for `data`: `.clean`, or `.pattern` (a secret pattern in the raw bytes) only for text the caller
    /// can redact (`SecretGate.isRedactable`; it redacts through `SecretGate.redactedCopy`). Fix round 1 (F2): a pattern in
    /// bytes that can't be redacted (a flattened copy, any PDF, a binary, an archive) throws, and so does a stored value.
    public let verdict: ScanVerdict
    /// The SHA-256 of the bytes the caller passed in (the original's, for a flattened copy).
    public let originalSha256: String
    /// For a flattened copy: where the vault keeps it (`flattened/<vouch row id>.pdf`, under
    /// `BrahmaPaths.vaultDir(companyId:)`); nil otherwise.
    public let flattenedPath: String?

    /// Whether `data` is a vouched PDF's flattened copy rather than the bytes passed in.
    public var isFlattenedCopy: Bool { flattenedPath != nil }
}

extension Store {
    /// The most a flattened copy may weigh (the helper's output cap).
    public static let maxFlattenedBytes = ArchiveLimits.maxBytes

    /// C2b-carry (c), Ruling 42: THE bytes to serve for `data` (the ref `canonical`'s bytes, of extension `ext`, in
    /// `companyId`) after the secret gate. Every caller that pins, shares, snapshots, copies, renders or serves bytes that
    /// may be a PDF calls this and serves `GatedBytes.data`, never `data`:
    /// - Not a PDF the owner vouched for: `SecretGate.check` as usual (it throws every refusal; fix round 1, F2: a pattern
    ///   too, unless `data` is text that can be redacted); the bytes are `data`.
    /// - A purge of the ref (`Store.purge`) deletes its flattened copies and withdraws the vouch (fix round 1, F1).
    /// - A PDF the owner vouched for (`Store.vouchFile`; `SecretGate.isFlattenTarget`): the flattened copy the sandboxed
    ///   helper re-renders from CoreGraphics' view of the visible pages (`ArchiveReader.flattenPDF`), kept in the company's
    ///   vault keyed to the vouch row (`flattened/<row id>.pdf`, its SHA-256 in `fileVouch.copySha256`; made once, read back
    ///   checked against that hash, made again if it is missing or differs). The copy then passes the whole gate as an
    ///   ordinary file that can't be vouched (stored values in every encoded form, secret patterns, the helper's structure
    ///   check, archives and PDFs inside it): a stored value or a pattern seen only decoded refuses, and so does a copy whose
    ///   structure couldn't be verified (it stays refused: no vouch applies to it), or whose raw bytes hold a pattern (a PDF
    ///   can't be redacted; fix round 1, F2). A file CoreGraphics can't open or
    ///   draw can't be flattened: refused, telling the owner to convert it (print it to PDF) and add it again. The original
    ///   bytes are never returned.
    /// Taint is the caller's, as for any read of the ref (the copy is served under the same ref). `archives` must carry the
    /// PDF helper (`SandboxedUnzipReader(…, pdfHelper:)`): without it every PDF refuses. Throws `WorkError`.
    public func gatedBytes(_ data: Data, ext: String, canonical: String, companyId: String, archives: any ArchiveReader,
                           knownValues: [(name: String, value: String)], paths: BrahmaPaths) throws -> GatedBytes {
        let sha = SHA256.hex(data)
        guard SecretGate.isFlattenTarget(data, ext: ext), let row = vouchedRow(companyId: companyId, canonical: canonical, sha256: sha) else {
            let verdict = try SecretGate.check(data, ext: ext, canonical: canonical, archives: archives, knownValues: knownValues, store: self,
                                               companyId: companyId)
            if case .pattern(let label, _) = verdict, !SecretGate.isRedactable(data, ext: ext) {
                throw Self.unredactable(canonical, label: label, knownValues: knownValues)
            }
            return GatedBytes(data: data, sha256: sha, ext: ext, verdict: verdict, originalSha256: sha, flattenedPath: nil)
        }
        let name = SecretGate.shown(canonical, knownValues: knownValues)
        let copy = try flattenedCopy(of: data, row: row, name: name, archives: archives, paths: paths)
        let verdict = try SecretGate.verdict(copy.data, ext: "pdf", canonical: canonical, archives: archives, knownValues: knownValues,
                                             store: self, companyId: companyId, vouchable: false)
        if case .knownValue(let finding) = verdict { throw SecretGate.refusal(canonical, finding, knownValues: knownValues) }
        // Fix round 1 (F2): a PDF is never redacted, so a pattern in the copy's own bytes refuses it.
        if case .pattern(let label, _) = verdict { throw Self.unredactable(canonical, label: label, knownValues: knownValues) }
        return GatedBytes(data: copy.data, sha256: copy.sha256, ext: "pdf", verdict: verdict, originalSha256: sha, flattenedPath: copy.path)
    }

    /// The owner's vouch for exactly these bytes under this name in this company, or nil (fail closed: a database that can't
    /// be read says nil, and the gate then refuses the PDF as unverifiable).
    func vouchedRow(companyId: String, canonical: String, sha256: String) -> FileVouch? {
        try? writer.read { db in
            try FileVouch.fetchOne(db, sql: """
                SELECT * FROM fileVouch WHERE companyId = ? AND canonicalHash = ? AND sha256 = ? AND vouchedAt IS NOT NULL
                """, arguments: [companyId, Self.canonicalHash(canonical), sha256])
        }
    }

    /// The flattened copy for the vouch `row` (whose bytes are `data`): the vault's, when it is there and hashes to the
    /// recorded `copySha256`; else made now by the helper, written to the vault and recorded.
    func flattenedCopy(of data: Data, row: FileVouch, name: String, archives: any ArchiveReader,
                       paths: BrahmaPaths) throws -> (data: Data, sha256: String, path: String) {
        let vault = Vault(paths: paths, companyId: row.companyId, content: ContentVault(paths: paths))
        let file = "\(row.id).pdf"
        let path = "\(VaultArea.flattened.rawValue)/\(file)"
        if let known = row.copySha256, let held = try? vault.read(path, sha256: known, maxBytes: Self.maxFlattenedBytes) {
            return (held, known, path)
        }
        let copy: Data
        do {
            copy = try archives.flattenPDF(of: data, maxBytes: Self.maxFlattenedBytes, timeout: SandboxedPDFReader.timeout)
        } catch let e as ArchiveReadError {
            if e == SandboxedPDFReader.unavailable { throw WorkError.invalid(e.message) }
            if e == SandboxedPDFReader.tooLong || e == SandboxedPDFReader.couldNotRun {
                throw WorkError.invalid("\(name) is a PDF the owner vouched for, and its flattened copy couldn't be made just now "
                                        + "(\(e.message)); try again")
            }
            throw Self.cantFlatten(name)
        } catch {
            // (A scratch directory that couldn't be made, …: nothing was flattened. The error itself is not echoed.)
            throw WorkError.invalid("\(name) is a PDF the owner vouched for, and its flattened copy couldn't be made just now; try again")
        }
        // (A copy left by an earlier try, or one that no longer matches its record, is replaced.)
        try? vault.remove(path)
        let written: (path: String, sha256: String)
        do {
            written = try vault.write(copy, area: .flattened, name: file)
        } catch {
            try? vault.remove(path)
            written = try vault.write(copy, area: .flattened, name: file)
        }
        try writer.write { db in
            try db.execute(sql: "UPDATE fileVouch SET copySha256 = ? WHERE id = ? AND companyId = ?",
                           arguments: [written.sha256, row.id, row.companyId])
        }
        return (copy, written.sha256, path)
    }

    /// Fix round 1 (F2): a secret pattern in bytes that can't be redacted: nothing is served.
    static func unredactable(_ canonical: String, label: String, knownValues: [(name: String, value: String)]) -> WorkError {
        SecretGate.binaryRefusal(canonical, label: label, what: "shared, copied or shown", knownValues: knownValues)
    }

    /// A vouched PDF CoreGraphics can't open or draw: the vouch can't lift its refusal.
    static func cantFlatten(_ name: String) -> WorkError {
        WorkError.invalid("\(name) is a PDF the owner vouched for, but it can't be flattened into a re-render of its visible pages, so "
                          + "the vouch can't lift its refusal: convert it (print it to PDF) and add it again")
    }
}
