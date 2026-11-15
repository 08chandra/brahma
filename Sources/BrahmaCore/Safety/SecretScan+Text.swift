import Foundation

/// One secret-like match in plain text (`SecretScan.textFindings`): the rule's label (or `stored secret <NAME>`) and the 1-based
/// line it starts on. A finding never carries the matched text.
public struct ScanFinding: Equatable, Sendable {
    public var label: String
    public var line: Int
    public var isKnownValue: Bool

    public init(label: String, line: Int, isKnownValue: Bool) {
        self.label = label; self.line = line; self.isKnownValue = isKnownValue
    }
}

extension SecretScan {
    static let textCompiled: [(label: String, regex: NSRegularExpression)] = patterns.compactMap { p in
        (try? NSRegularExpression(pattern: p.ere)).map { (p.label, $0) }
    }

    /// What plain text (a fact to `remember`, a chunk of a dropped file in 6a's `ContentScan`) holds that looks like a secret:
    /// every match of `patterns` over the whole text, and every `Redactor.forms(of:)` form of each known value of at least
    /// `Redactor.minLength` characters (label `stored secret <NAME>`). Findings are 1-based lines of where the match starts,
    /// reported once per (label, line), in line order; none carries the value.
    public static func textFindings(_ text: String, knownValues: [(name: String, value: String)]) -> [ScanFinding] {
        let ns = text as NSString
        // UTF-16 offsets of each line start, for the line of a match.
        var lineStarts: [Int] = [0]
        let newline = UInt16(UInt8(ascii: "\n"))
        for i in 0..<ns.length where ns.character(at: i) == newline { lineStarts.append(i + 1) }
        func line(of offset: Int) -> Int {
            var lo = 0, hi = lineStarts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
            }
            return lo + 1
        }

        var found: [(order: Int, finding: ScanFinding)] = []
        var seen = Set<String>()
        func add(_ label: String, _ offset: Int, known: Bool) {
            let f = ScanFinding(label: label, line: line(of: offset), isKnownValue: known)
            if seen.insert("\(f.label)\n\(f.line)").inserted { found.append((found.count, f)) }
        }

        let whole = NSRange(location: 0, length: ns.length)
        for p in textCompiled {
            for m in p.regex.matches(in: text, range: whole) { add(p.label, m.range.location, known: false) }
        }
        for (name, value) in knownValues where value.count >= Redactor.minLength {
            for form in Redactor.forms(of: value) where !form.isEmpty {
                var search = whole
                while search.length > 0 {
                    let r = ns.range(of: form, options: .literal, range: search)
                    guard r.location != NSNotFound else { break }
                    add("stored secret \(name)", r.location, known: true)
                    let next = r.location + max(r.length, 1)
                    search = NSRange(location: next, length: ns.length - next)
                }
            }
        }
        return found.sorted { $0.finding.line != $1.finding.line ? $0.finding.line < $1.finding.line : $0.order < $1.order }
            .map(\.finding)
    }
}
