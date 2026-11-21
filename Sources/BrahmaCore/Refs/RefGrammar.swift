import Foundation

/// The text grammar of design §1.2, with the controller's rulings: `A-<n>` is an ask (`ask:<n>` an alias of it) and
/// `AR-<n>` an artifact. Plain code, no regex engine over agent text:
///
/// | Form | Kind |
/// |---|---|
/// | `ENG-142`, `item:ENG-142` | item (`item:` is canonical only for a key prefix `A`, `AR` or `F`, as ML's `MemoryRefs`) |
/// | `ENG-142:diff[/<path>][@worktree|@<rev>]` | diff |
/// | `ENG-142:<path>[:<range>][@worktree|@<rev>]`, `<path>[:<range>][@<rev>]` | file |
/// | `ENG-142:run`, `run:<id>` | run |
/// | `commit:<rev>`, `A-<n>`/`ask:<n>`, `AR-<n>`, `F-<n>`, `kb:<page>[#<section>]`, `mem:<n>`, `rel:<n>`, `sprint:<n>` | … |
/// | `preview:<surface>[/<path>][@<viewport>]`, `msg:<id>`, `thread:<id>`, `@<handle>`, `#<channel>`, `fact:<text>` | … |
///
/// A leading `:` (`:diff`, `:run`, `:<path>`) means the context's current item. `<KEY>:<path>` and `<path>:<range>` are told
/// apart by the first segment being a key of the company (`RefContext.keyPrefixes`).
enum RefGrammar {
    static let maxLength = 1024
    static let maxFactLength = 280

    static func parse(_ raw: String, context: RefContext) -> WorkRef? {
        guard let s = RefText.normalize(raw), !s.isEmpty, s.count <= maxLength else { return nil }
        if let rest = s.dropping("fact:") {
            let text = rest.trimmingCharacters(in: .whitespaces)
            guard context.allowInternal, !text.isEmpty, text.count <= maxFactLength, !text.contains("\n"), !text.contains("\t"),
                  text == rest else { return nil }
            return WorkRef(kind: .fact, id: text)
        }
        // Everything else is one token.
        guard !s.unicodeScalars.contains(where: { $0.properties.isWhitespace }) else {
            return kbRef(s)   // kb page names may hold spaces
        }
        if let n = s.dropping("ask:") { return number(n).map { WorkRef(kind: .ask, id: $0) } }
        if let k = s.dropping("item:") { return itemKey(k, context).map { WorkRef(kind: .item, id: $0) } }
        if let r = s.dropping("commit:") { return isRev(r) ? WorkRef(kind: .commit, id: r) : nil }
        if s.hasPrefix("kb:") { return kbRef(s) }
        if let n = s.dropping("mem:") { return number(n).map { WorkRef(kind: .memory, id: $0) } }
        if let rest = s.dropping("preview:") { return preview(rest) }
        if let id = s.dropping("run:") { return isRecordId(id) ? WorkRef(kind: .run, id: id) : nil }
        if let n = s.dropping("rel:") { return number(n).map { WorkRef(kind: .release, id: $0) } }
        if let n = s.dropping("sprint:") { return number(n).map { WorkRef(kind: .sprint, id: $0) } }
        if let id = s.dropping("msg:") { return isRecordId(id) ? WorkRef(kind: .message, id: id) : nil }
        if let id = s.dropping("thread:") { return isRecordId(id) ? WorkRef(kind: .thread, id: id) : nil }
        if let h = s.dropping("@") { return isHandle(h) ? WorkRef(kind: .agent, id: h) : nil }
        if let c = s.dropping("#") { return isChannelName(c) ? WorkRef(kind: .channel, id: c) : nil }
        if let n = s.dropping("AR-") { return number(n).map { WorkRef(kind: .artifact, id: $0) } }
        if let n = s.dropping("A-") { return number(n).map { WorkRef(kind: .ask, id: $0) } }
        if let n = s.dropping("F-") { return number(n).map { WorkRef(kind: .resource, id: $0) } }

        // `<KEY>[:…]` or `:…` (the current item).
        if let colon = s.firstIndex(of: ":") {
            let head = String(s[..<colon]), rest = String(s[s.index(after: colon)...])
            let key: String?
            if head.isEmpty {
                key = context.currentItemKey.flatMap { itemKey($0, context) }
                guard key != nil else { return nil }
            } else {
                key = itemKey(head, context)
            }
            if let key { return afterKey(key, rest) }
        } else if let key = itemKey(s, context) {
            return WorkRef(kind: .item, id: key)
        }
        return fileRef(s, key: nil)
    }

    // MARK: Forms after a key

    private static func afterKey(_ key: String, _ rest: String) -> WorkRef? {
        if rest == "run" { return WorkRef(kind: .run, id: "", params: ["item": key]) }
        let (body, suffix) = splitSuffix(rest)
        if body == "diff" || body.hasPrefix("diff/") {
            var ref = WorkRef(kind: .diff, id: key)
            if body.hasPrefix("diff/") {
                let path = String(body.dropFirst(5))
                guard isPath(path) else { return nil }
                ref.params["file"] = path
            }
            switch suffix {
            case nil: break
            case "worktree"?: ref.branch = "worktree:\(key)"
            case let r? where isRev(r): ref.rev = r
            default: return nil
            }
            return ref
        }
        return fileRef(rest, key: key)
    }

    /// `<path>[:<range>][@worktree|@<rev>]`; `@worktree` only on an item.
    private static func fileRef(_ s: String, key: String?) -> WorkRef? {
        let (body, suffix) = splitSuffix(s)
        var path = body
        var range: LineRange?
        if let colon = body.lastIndex(of: ":") {
            guard let r = lineRange(String(body[body.index(after: colon)...])) else { return nil }
            range = r
            path = String(body[..<colon])
        }
        guard isPath(path), key != nil || looksLikePath(path) else { return nil }
        var ref = WorkRef(kind: .file, id: path, branch: key.map { "item/\($0)" }, range: range)
        switch suffix {
        case nil: break
        case "worktree"?:
            guard let key else { return nil }
            ref.branch = "worktree:\(key)"
        case let r? where isRev(r): ref.rev = r
        default: return nil
        }
        return ref
    }

    /// The text before the last `@`, and after it (nil without one).
    private static func splitSuffix(_ s: String) -> (String, String?) {
        guard let at = s.lastIndex(of: "@") else { return (s, nil) }
        return (String(s[..<at]), String(s[s.index(after: at)...]))
    }

    // MARK: Other kinds

    private static func kbRef(_ s: String) -> WorkRef? {
        guard let rest = s.dropping("kb:"), !rest.contains("\n"), !rest.contains("\t") else { return nil }
        var page = rest
        var section: String?
        if let hash = rest.firstIndex(of: "#") {
            page = String(rest[..<hash])
            section = String(rest[rest.index(after: hash)...])
            guard let section, !section.isEmpty, section.count <= 200, section == section.trimmingCharacters(in: .whitespaces)
            else { return nil }
        }
        // Kept as written (so it round-trips) when it is already a normalized page name.
        guard let normalized = try? HandbookPath.normalizeRef(page), normalized.section == nil, normalized.path == page else { return nil }
        var ref = WorkRef(kind: .kb, id: page)
        if let section { ref.params["section"] = section }
        return ref
    }

    private static func preview(_ rest: String) -> WorkRef? {
        let (body, viewport) = splitSuffix(rest)
        let surface: String, path: String?
        if let slash = body.firstIndex(of: "/") {
            surface = String(body[..<slash])
            path = String(body[slash...])
        } else {
            surface = body
            path = nil
        }
        guard surface.range(of: "^[a-z][a-z0-9-]{0,23}$", options: .regularExpression) != nil,
              let params = PreviewRefParams.validate(path: path, viewport: viewport) else { return nil }
        return WorkRef(kind: .preview, id: surface, params: params)
    }

    // MARK: Canonical text

    static func canonical(_ r: WorkRef) -> String {
        switch r.kind {
        case .file:
            var s = r.itemKey.map { "\($0):" } ?? ""
            s += r.id
            if let range = r.range { s += range.start == range.end ? ":\(range.start)" : ":\(range.start)-\(range.end)" }
            if r.isWorktree { s += "@worktree" } else if let rev = r.rev { s += "@\(rev)" }
            return s
        case .diff:
            var s = "\(r.id):diff"
            if let file = r.params["file"] { s += "/\(file)" }
            if r.isWorktree { s += "@worktree" } else if let rev = r.rev { s += "@\(rev)" }
            return s
        case .commit: return "commit:\(r.id)"
        case .item: return MemoryRefs.canonicalItemRef(r.id)
        case .ask: return "A-\(r.id)"
        case .artifact: return "AR-\(r.id)"
        case .resource: return "F-\(r.id)"
        case .kb: return "kb:\(r.id)" + (r.params["section"].map { "#\($0)" } ?? "")
        case .memory: return "mem:\(r.id)"
        case .preview: return "preview:\(r.id)" + (r.params["path"] ?? "") + (r.params["viewport"].map { "@\($0)" } ?? "")
        case .run: return r.params["item"].map { "\($0):run" } ?? "run:\(r.id)"
        case .release: return "rel:\(r.id)"
        case .sprint: return "sprint:\(r.id)"
        case .message: return "msg:\(r.id)"
        case .thread: return "thread:\(r.id)"
        case .agent: return "@\(r.id)"
        case .channel: return "#\(r.id)"
        case .fact: return "fact:\(r.id)"
        }
    }

    // MARK: Pieces

    /// `^[A-Z][A-Z0-9]{0,9}-[0-9]{1,9}$` whose prefix is one of the company's.
    static func itemKey(_ s: String, _ context: RefContext) -> String? {
        guard let dash = s.firstIndex(of: "-") else { return nil }
        let prefix = s[..<dash], digits = s[s.index(after: dash)...]
        guard let first = prefix.unicodeScalars.first, (0x41...0x5A).contains(first.value), prefix.count <= 10,
              prefix.unicodeScalars.allSatisfy({ (0x41...0x5A).contains($0.value) || (0x30...0x39).contains($0.value) }),
              (1...9).contains(digits.count), digits.unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value) }),
              context.keyPrefixes.contains(String(prefix)) else { return nil }
        return s
    }

    /// A positive decimal without leading zeros (so it round-trips), up to 9 digits.
    static func number(_ s: String) -> String? {
        guard (1...9).contains(s.count), s.unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value) }), !s.hasPrefix("0")
        else { return nil }
        return s
    }

    /// `[0-9a-f]{7,40}`.
    static func isRev(_ s: String) -> Bool {
        (7...40).contains(s.utf8.count) && s.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// A record id (UUIDs, numbers): `[A-Za-z0-9][A-Za-z0-9_-]{0,127}`.
    static func isRecordId(_ s: String) -> Bool {
        guard (1...128).contains(s.utf8.count), let first = s.utf8.first, isAlnum(first) else { return false }
        return s.utf8.allSatisfy { isAlnum($0) || $0 == 0x2D || $0 == 0x5F }
    }

    /// An agent handle as `hire` accepts it.
    static func isHandle(_ s: String) -> Bool { s.range(of: "^[a-z0-9][a-z0-9_-]{0,31}$", options: .regularExpression) != nil }

    /// A channel name as `createChannel` accepts it (never a DM's `dm:a:b`).
    static func isChannelName(_ s: String) -> Bool { s.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil }

    private static func isAlnum(_ b: UInt8) -> Bool { (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) }

    /// `<start>[-<end>]`, checked by `LineRange.checked`.
    static func lineRange(_ s: String) -> LineRange? {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ (1...7).contains($0.count) && $0.unicodeScalars.allSatisfy { (0x30...0x39).contains($0.value) } }),
              let start = Int(parts[0]), let end = Int(parts.last!) else { return nil }
        return LineRange.checked(start: start, end: end)
    }

    /// A relative path whose components `SafeFS` accepts, made of letters, digits, marks and `. _ - + ~ / [ ]`.
    static func isPath(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 512, (try? SafeFS.components(s)) != nil else { return false }
        return s.unicodeScalars.allSatisfy { u in
            if u.isASCII {
                let b = UInt8(u.value)
                return isAlnum(b) || [0x2E, 0x5F, 0x2D, 0x2B, 0x7E, 0x2F, 0x5B, 0x5D].contains(b)
            }
            switch u.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber: return true
            default: return false
            }
        }
    }

    /// A bare path (no item) must look like one: a `/` in it, or a last part with an extension holding a letter.
    static func looksLikePath(_ s: String) -> Bool {
        if s.contains("/") { return true }
        guard let dot = s.lastIndex(of: "."), dot != s.startIndex else { return false }
        let ext = s[s.index(after: dot)...]
        return (1...10).contains(ext.count) && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } && ext.contains { $0.isLetter }
    }
}

/// The `preview:` parameters (design §4.6): a path through `LoopbackURL.withPath` and a viewport as Plan L's
/// `PreviewViewport.parse` takes it (that type lives in BrahmaAppModel, so the rule is restated here).
public enum PreviewRefParams {
    /// `["path": …, "viewport": …]` (each only when given), or nil when either is refused. The viewport is lowercased and
    /// `WxH` written without leading zeros.
    public static func validate(path: String?, viewport: String?) -> [String: String]? {
        var params: [String: String] = [:]
        if let path {
            guard (try? LoopbackURL.withPath(URL(string: "http://127.0.0.1:47100/")!, path: path, port: 47100)) != nil else { return nil }
            params["path"] = path
        }
        if let viewport {
            guard let v = self.viewport(viewport) else { return nil }
            params["viewport"] = v
        }
        return params
    }

    static let minSide = 200
    static let maxSide = 4096

    /// `desktop|ipad|iphone|<W>x<H>`, sides 200…4096 (case-insensitive), in its canonical spelling.
    static func viewport(_ s: String) -> String? {
        let text = s.lowercased()
        if ["desktop", "ipad", "iphone"].contains(text) { return text }
        let parts = text.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ (1...4).contains($0.count) && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let w = Int(parts[0]), let h = Int(parts[1]),
              (minSide...maxSide).contains(w), (minSide...maxSide).contains(h) else { return nil }
        return "\(w)x\(h)"
    }
}

private extension String {
    /// The rest after `prefix`, or nil when the string does not start with it.
    func dropping(_ prefix: String) -> String? { hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil }
}

/// Finds ref candidates in message text: each whitespace-separated token, with surrounding punctuation trimmed, that
/// parses (never an internal `fact:`). Candidates only: a caller keeps one only when it resolves to anything but `.missing`.
public enum RefScanner {
    public static let maxPerMessage = 20

    static let leading: Set<Character> = ["(", "[", "{", "\"", "'", "`", "<", "*", "_"]
    static let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "\"", "'", "`", ">", "*", "_"]

    public static func scan(_ text: String, context: RefContext) -> [(range: Range<String.Index>, ref: WorkRef)] {
        var context = context
        context.allowInternal = false
        var found: [(range: Range<String.Index>, ref: WorkRef)] = []
        var i = text.startIndex
        while i < text.endIndex, found.count < maxPerMessage {
            guard !text[i].isWhitespace else { i = text.index(after: i); continue }
            var end = i
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            var lo = i, hi = end
            while lo < hi, leading.contains(text[lo]) { lo = text.index(after: lo) }
            while hi > lo, trailing.contains(text[text.index(before: hi)]) { hi = text.index(before: hi) }
            if lo < hi, text.distance(from: lo, to: hi) <= RefGrammar.maxLength,
               let ref = RefGrammar.parse(String(text[lo..<hi]), context: context) {
                found.append((lo..<hi, ref))
            }
            i = end
        }
        return found
    }
}
