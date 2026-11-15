import Foundation

/// The trust a dropped file gets before the owner says otherwise (§4.3): document types and large text files are EXTERNAL
/// (they commonly carry text from outside), and so is anything macOS marked as downloaded. Everything else is the owner's.
public enum DropTrust {
    /// Text kinds that count as outside text once they pass `ResourcePolicy.largeTextBytes`.
    static let largeTextExt: Set<String> = ["md", "txt", "csv"]

    public static func defaultProvenance(ext: String, bytes: Int64, quarantined: Bool)
        -> (provenance: Provenance, tainted: Bool, reason: String?) {
        let e = ext.lowercased()
        if ResourcePolicy.docTypeTainted.contains(e) {
            return (.external("doc-type"), true, "\(e.uppercased()) from outside (document type)")
        }
        if largeTextExt.contains(e), bytes > Int64(ResourcePolicy.largeTextBytes) {
            return (.external("doc-type"), true, "large text file")
        }
        if quarantined {
            return (.external("quarantine"), true, "downloaded file (macOS quarantine)")
        }
        return (.owner, false, nil)
    }
}
