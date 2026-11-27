import Foundation

/// The languages `CodeHighlighter` knows (collab design §1.4); everything else is `.plain` mono.
public enum CodeLanguage: Equatable, Sendable {
    case swift, typescript, python, jsonYaml, plain

    /// By the path's extension (case-insensitive): `.swift`; `.ts .tsx .js .jsx .mjs .cjs`; `.py`; `.json .yaml .yml`.
    public static func detect(path: String) -> CodeLanguage {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return .plain }
        switch name[name.index(after: dot)...].lowercased() {
        case "swift": return .swift
        case "ts", "tsx", "js", "jsx", "mjs", "cjs": return .typescript
        case "py": return .python
        case "json", "yaml", "yml": return .jsonYaml
        default: return .plain
        }
    }
}

public enum TokenKind: Equatable, Sendable {
    case keyword, string, number, comment, type, plain
}

/// One run of a highlighted line. `hidden` marks an `InvisibleMarkers` marker standing for a character the reader can't see.
public struct CodeSpan: Equatable, Sendable {
    public var text: String
    public var kind: TokenKind
    public var hidden: Bool

    public init(text: String, kind: TokenKind, hidden: Bool = false) { self.text = text; self.kind = kind; self.hidden = hidden }
}

/// A small table-driven linear lexer: keywords, strings with escapes, line and block comments, numbers and type-like
/// identifiers, in one pass with a state carried across lines (normal, string, line comment, block comment, template literal).
/// Past `maxLines` every line is one plain span. Every span's text goes through `InvisibleMarkers`.
public enum CodeHighlighter {
    public static let maxLines = 20_000

    public static func highlight(_ text: String, language: CodeLanguage) -> [[CodeSpan]] {
        let lines = splitLines(text)
        if language == .plain || lines.count > maxLines {
            return lines.map { line in line.isEmpty ? [] : InvisibleMarkers.split(line, kind: .plain) }
        }
        var lexer = Lexer(language: language)
        return lines.map { lexer.lex($0) }
    }

    /// Whether any span of `lines` stands for a hidden character.
    public static func hasHidden(_ lines: [[CodeSpan]]) -> Bool {
        lines.contains { $0.contains(where: \.hidden) }
    }

    /// Lines split on U+000A (by scalar: a CRLF is one `Character`, so `split(separator:)` would miss it), a trailing U+000D dropped;
    /// a trailing newline yields a last empty line.
    public static func splitLines(_ text: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            if s == "\n" {
                if current.last == "\r" { current.removeLast() }
                out.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(s)
            }
        }
        if current.last == "\r" { current.removeLast() }
        out.append(String(current))
        return out
    }

    // MARK: Lexer

    struct Lexer {
        enum State: Equatable {
            case normal
            /// Inside a string: its closing delimiter, and whether it spans lines (triple quotes, template literals).
            case string(close: [Unicode.Scalar], multi: Bool)
            case blockComment(depth: Int)
        }

        let language: CodeLanguage
        var state: State = .normal

        init(language: CodeLanguage) { self.language = language }

        var lineCommentStarts: [[Unicode.Scalar]] {
            switch language {
            case .swift, .typescript, .jsonYaml: [["/", "/"]]
            case .python: [["#"]]
            case .plain: []
            }
        }
        var hasBlockComments: Bool { language == .swift || language == .typescript || language == .jsonYaml }
        var nestedBlockComments: Bool { language == .swift }
        var hashComments: Bool { language == .python || language == .jsonYaml }
        var singleQuoteStrings: Bool { language != .swift }
        var templateLiterals: Bool { language == .typescript }
        var tripleQuotes: Bool { language == .swift || language == .python }
        var typesByCase: Bool { language != .jsonYaml }

        var keywords: Set<String> {
            switch language {
            case .swift: Self.swiftKeywords
            case .typescript: Self.typescriptKeywords
            case .python: Self.pythonKeywords
            case .jsonYaml: Self.jsonKeywords
            case .plain: []
            }
        }

        mutating func lex(_ line: String) -> [CodeSpan] {
            let s = Array(line.unicodeScalars)
            var out: [CodeSpan] = []
            var current: (kind: TokenKind, text: String.UnicodeScalarView)? = nil
            func flush() {
                if let c = current, !c.text.isEmpty { out.append(contentsOf: InvisibleMarkers.split(String(c.text), kind: c.kind)) }
                current = nil
            }
            func emit(_ kind: TokenKind, _ scalars: ArraySlice<Unicode.Scalar>) {
                if current?.kind != kind { flush(); current = (kind, String.UnicodeScalarView()) }
                current?.text.append(contentsOf: scalars)
            }
            var i = 0
            let n = s.count
            while i < n {
                switch state {
                case .string(let close, let multi):
                    // The rest of the string on this line: escapes skip a character; the close ends it.
                    var j = i
                    var closed = false
                    while j < n {
                        if s[j] == "\\", j + 1 < n { j += 2; continue }
                        if matches(s, at: j, close) { j += close.count; closed = true; break }
                        j += 1
                    }
                    emit(.string, s[i..<j])
                    i = j
                    if closed || !multi { state = .normal }
                case .blockComment(var depth):
                    var j = i
                    var ended = false
                    while j < n {
                        if nestedBlockComments, matches(s, at: j, ["/", "*"]) { depth += 1; j += 2; continue }
                        if matches(s, at: j, ["*", "/"]) {
                            depth -= 1
                            j += 2
                            if depth == 0 { ended = true; break }
                            continue
                        }
                        j += 1
                    }
                    emit(.comment, s[i..<j])
                    i = j
                    state = ended ? .normal : .blockComment(depth: depth)
                case .normal:
                    let c = s[i]
                    // Comments.
                    if hashComments, c == "#" {
                        emit(.comment, s[i..<n]); i = n; continue
                    }
                    if !hashComments || language == .jsonYaml, matches(s, at: i, ["/", "/"]) {
                        emit(.comment, s[i..<n]); i = n; continue
                    }
                    if hasBlockComments, matches(s, at: i, ["/", "*"]) {
                        state = .blockComment(depth: 1)
                        emit(.comment, s[i..<(i + 2)])
                        i += 2
                        continue
                    }
                    // Strings.
                    if c == "\"" || (c == "'" && singleQuoteStrings) || (c == "`" && templateLiterals) {
                        if tripleQuotes, matches(s, at: i, [c, c, c]) {
                            state = .string(close: [c, c, c], multi: true)
                            emit(.string, s[i..<(i + 3)])
                            i += 3
                        } else {
                            state = .string(close: [c], multi: c == "`")
                            emit(.string, s[i..<(i + 1)])
                            i += 1
                        }
                        continue
                    }
                    // Identifiers and keywords.
                    if isIdentifierStart(c) {
                        var j = i + 1
                        while j < n, isIdentifierPart(s[j]) { j += 1 }
                        let word = String(String.UnicodeScalarView(s[i..<j]))
                        if keywords.contains(word) {
                            emit(.keyword, s[i..<j])
                        } else if typesByCase, (0x41...0x5A).contains(c.value) {
                            emit(.type, s[i..<j])
                        } else {
                            emit(.plain, s[i..<j])
                        }
                        i = j
                        continue
                    }
                    // Numbers.
                    if (0x30...0x39).contains(c.value) {
                        var j = i + 1
                        while j < n, isIdentifierPart(s[j]) || s[j] == "." { j += 1 }
                        emit(.number, s[i..<j])
                        i = j
                        continue
                    }
                    emit(.plain, s[i..<(i + 1)])
                    i += 1
                }
            }
            flush()
            // A single-line string left open ends with its line; a line comment ends with its line.
            if case .string(_, let multi) = state, !multi { state = .normal }
            return out
        }

        func matches(_ s: [Unicode.Scalar], at i: Int, _ pattern: [Unicode.Scalar]) -> Bool {
            guard i + pattern.count <= s.count else { return false }
            for (k, p) in pattern.enumerated() where s[i + k] != p { return false }
            return true
        }

        func isIdentifierStart(_ c: Unicode.Scalar) -> Bool {
            let v = c.value
            return (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) || v == 0x5F || v == 0x24 || (v > 0x7F && c.properties.isAlphabetic)
        }

        func isIdentifierPart(_ c: Unicode.Scalar) -> Bool {
            isIdentifierStart(c) || (0x30...0x39).contains(c.value)
        }

        static let swiftKeywords: Set<String> = [
            "let", "var", "func", "class", "struct", "enum", "protocol", "extension", "import", "if", "else", "guard", "return", "for",
            "while", "repeat", "in", "switch", "case", "default", "break", "continue", "where", "do", "try", "catch", "throw", "throws",
            "rethrows", "async", "await", "actor", "init", "deinit", "self", "Self", "super", "static", "final", "override", "public",
            "private", "fileprivate", "internal", "open", "mutating", "nonmutating", "inout", "is", "as", "nil", "true", "false", "some",
            "any", "typealias", "associatedtype", "subscript", "defer", "fallthrough", "operator", "indirect", "lazy", "weak", "unowned",
            "convenience", "required", "optional", "dynamic", "willSet", "didSet", "get", "set", "package", "consuming", "borrowing",
        ]
        static let typescriptKeywords: Set<String> = [
            "const", "let", "var", "function", "class", "interface", "type", "enum", "import", "export", "from", "as", "default", "return",
            "if", "else", "for", "while", "do", "switch", "case", "break", "continue", "new", "this", "super", "extends", "implements",
            "typeof", "instanceof", "in", "of", "void", "null", "undefined", "true", "false", "async", "await", "yield", "try", "catch",
            "finally", "throw", "delete", "static", "readonly", "public", "private", "protected", "abstract", "declare", "namespace",
            "module", "get", "set", "constructor", "keyof", "satisfies", "with", "debugger",
        ]
        static let pythonKeywords: Set<String> = [
            "def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "None", "True", "False",
            "import", "from", "as", "pass", "break", "continue", "try", "except", "finally", "raise", "with", "lambda", "yield", "global",
            "nonlocal", "assert", "del", "async", "await", "match", "case",
        ]
        static let jsonKeywords: Set<String> = ["true", "false", "null", "yes", "no", "True", "False", "Yes", "No", "TRUE", "FALSE", "YES", "NO"]
    }
}
