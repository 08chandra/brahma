import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The secret scan of a dropped file, streamed from its descriptor so a large file never sits in memory whole.
///
/// The file is read in `chunk`-byte pieces with `pread` (the descriptor's offset is untouched), each scanned together with
/// the tail of the bytes before it (the overlap: at least `minOverlap` bytes, and never less than the longest form of a known
/// value, so a value split across a chunk edge is still found whole).
/// - Text files get `SecretScan.textFindings` (the secret patterns and the known values' Redactor forms) per window, with
///   line numbers carried across windows.
/// - Binaries get only the raw bytes of the known values' forms; their findings have line 0 (a binary has no lines).
///
/// Findings are deduped by (label, line), ordered by line, and never carry the matched text.
public enum ContentScan {
    public static let chunkBytes = 1 << 20
    public static let minOverlap = 4096

    public static func scan(fd: Int32, isText: Bool, knownValues: [(name: String, value: String)],
                            chunk: Int = chunkBytes) throws -> [ScanFinding] {
        let known = knownValues.filter { $0.value.count >= Redactor.minLength }
        let needles: [(name: String, forms: [[UInt8]])] = known.map { kv in
            (kv.name, Redactor.forms(of: kv.value).map { Array($0.utf8) }.filter { !$0.isEmpty })
        }
        if !isText && needles.isEmpty { return [] }
        let longest = needles.flatMap(\.forms).map(\.count).max() ?? 0
        let overlap = max(minOverlap, longest)
        let step = max(chunk, 1)

        var found: [(order: Int, finding: ScanFinding)] = []
        var seen = Set<String>()
        func add(_ f: ScanFinding) {
            if seen.insert("\(f.label)\n\(f.line)").inserted { found.append((found.count, f)) }
        }

        var offset: off_t = 0
        var window: [UInt8] = []
        var linesBefore = 0                  // newlines before the window's first byte
        let newline = UInt8(ascii: "\n")
        while true {
            let fresh = try read(fd, at: offset, count: step)
            if fresh.isEmpty { break }       // the carried tail was scanned with the window before
            offset += off_t(fresh.count)
            window.append(contentsOf: fresh)

            if isText {
                let text = String(decoding: window, as: UTF8.self)
                for f in SecretScan.textFindings(text, knownValues: known) {
                    add(ScanFinding(label: f.label, line: linesBefore + f.line, isKnownValue: f.isKnownValue))
                }
            } else {
                for (name, forms) in needles where forms.contains(where: { contains(window, $0) }) {
                    add(ScanFinding(label: "stored secret \(name)", line: 0, isKnownValue: true))
                }
            }

            if fresh.count < step { break }  // end of file
            let keep = min(overlap, window.count)
            let consumed = window.count - keep
            if isText { linesBefore += window[0..<consumed].reduce(0) { $1 == newline ? $0 + 1 : $0 } }
            window.removeFirst(consumed)
        }
        return found.sorted { $0.finding.line != $1.finding.line ? $0.finding.line < $1.finding.line : $0.order < $1.order }
            .map(\.finding)
    }

    /// `scan(fd:…)` over a file opened without following a link (for tests and tools).
    public static func scan(url: URL, isText: Bool, knownValues: [(name: String, value: String)],
                            chunk: Int = chunkBytes) throws -> [ScanFinding] {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ResourceError.invalid("\(url.lastPathComponent) can't be read") }
        defer { close(fd) }
        return try scan(fd: fd, isText: isText, knownValues: knownValues, chunk: chunk)
    }

    /// `text` with every secret span replaced by `[redacted <label>]`: every match of the secret patterns and every Redactor
    /// form of every known value (at least `Redactor.minLength` long), overlapping spans merged into one (labelled by the
    /// first). `findings` is the scan the owner chose to redact; redaction is never narrowed to it, so a span the streamed
    /// scan could not see whole is still replaced.
    public static func redact(text: String, findings: [ScanFinding], knownValues: [(name: String, value: String)]) -> String {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var spans: [(range: NSRange, label: String)] = []
        for p in SecretScan.textCompiled {
            for m in p.regex.matches(in: text, range: whole) where m.range.length > 0 { spans.append((m.range, p.label)) }
        }
        for (name, value) in knownValues where value.count >= Redactor.minLength {
            for form in Redactor.forms(of: value) where !form.isEmpty {
                var search = whole
                while search.length > 0 {
                    let r = ns.range(of: form, options: .literal, range: search)
                    guard r.location != NSNotFound else { break }
                    spans.append((r, "stored secret \(name)"))
                    let next = r.location + max(r.length, 1)
                    search = NSRange(location: next, length: ns.length - next)
                }
            }
        }
        guard !spans.isEmpty else { return text }
        spans.sort { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length }
        var merged: [(range: NSRange, label: String)] = []
        for s in spans {
            if let last = merged.last, s.range.location < NSMaxRange(last.range) {
                let end = max(NSMaxRange(last.range), NSMaxRange(s.range))
                merged[merged.count - 1].range.length = end - last.range.location
            } else {
                merged.append(s)
            }
        }
        let out = NSMutableString(string: text)
        for s in merged.reversed() { out.replaceCharacters(in: s.range, with: "[redacted \(s.label)]") }
        return out as String
    }

    // MARK: Bytes

    /// Up to `count` bytes at `offset`; fewer only at the end of the file.
    static func read(_ fd: Int32, at offset: off_t, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + got, count - got, offset + off_t(got)) }
            if n < 0 {
                if errno == EINTR { continue }
                throw ResourceError.invalid("the file can't be read (\(String(cString: strerror(errno))))")
            }
            if n == 0 { break }
            got += n
        }
        if got < count { buffer.removeLast(count - got) }
        return buffer
    }

    /// Whether `needle` occurs in `haystack` (memchr for the first byte, then a compare).
    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return needle.isEmpty }
        return haystack.withUnsafeBytes { h in
            needle.withUnsafeBytes { n in
                let base = h.baseAddress!, first = Int32(needle[0])
                let last = haystack.count - needle.count
                var i = 0
                while i <= last {
                    guard let hit = memchr(base + i, first, last - i + 1) else { return false }
                    let at = base.distance(to: UnsafeRawPointer(hit))
                    if memcmp(base + at, n.baseAddress!, needle.count) == 0 { return true }
                    i = at + 1
                }
                return false
            }
        }
    }
}
