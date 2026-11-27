import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

/// One line of source and the exact `(text, kind)` spans it highlights to.
struct CodeFixture: CustomTestStringConvertible, Sendable {
    var name: String
    var language: CodeLanguage
    var source: String
    var expected: [(String, TokenKind)]
    var testDescription: String { name }
}

enum CodeFixtures {
    static let all: [CodeFixture] = [
        CodeFixture(name: "swift-let", language: .swift, source: "let x: Int = 42 // answer",
                    expected: [("let", .keyword), (" x: ", .plain), ("Int", .type), (" = ", .plain), ("42", .number), (" ", .plain), ("// answer", .comment)]),
        CodeFixture(name: "swift-string", language: .swift, source: "print(\"hi \\(name)\") /* c */",
                    expected: [("print(", .plain), ("\"hi \\(name)\"", .string), (") ", .plain), ("/* c */", .comment)]),
        CodeFixture(name: "swift-hex", language: .swift, source: "guard let v = 0xFF_FF else { return }",
                    expected: [("guard", .keyword), (" ", .plain), ("let", .keyword), (" v = ", .plain), ("0xFF_FF", .number), (" ", .plain),
                               ("else", .keyword), (" { ", .plain), ("return", .keyword), (" }", .plain)]),
        CodeFixture(name: "ts-jsx", language: .typescript, source: "const el = <Div className=\"x\">{count}</Div>;",
                    expected: [("const", .keyword), (" el = <", .plain), ("Div", .type), (" className=", .plain), ("\"x\"", .string),
                               (">{count}</", .plain), ("Div", .type), (">;", .plain)]),
        CodeFixture(name: "ts-template", language: .typescript, source: "return `a ${b}` + 'c'",
                    expected: [("return", .keyword), (" ", .plain), ("`a ${b}`", .string), (" + ", .plain), ("'c'", .string)]),
        CodeFixture(name: "python", language: .python, source: "def f(n): return None  # c",
                    expected: [("def", .keyword), (" f(n): ", .plain), ("return", .keyword), (" ", .plain), ("None", .keyword), ("  ", .plain),
                               ("# c", .comment)]),
        CodeFixture(name: "python-class", language: .python, source: "class Foo(Base): x = 1.5e3",
                    expected: [("class", .keyword), (" ", .plain), ("Foo", .type), ("(", .plain), ("Base", .type), ("): x = ", .plain),
                               ("1.5e3", .number)]),
        CodeFixture(name: "json", language: .jsonYaml, source: "{\"a\": 1.5, \"b\": true, \"c\": null}",
                    expected: [("{", .plain), ("\"a\"", .string), (": ", .plain), ("1.5", .number), (", ", .plain), ("\"b\"", .string),
                               (": ", .plain), ("true", .keyword), (", ", .plain), ("\"c\"", .string), (": ", .plain), ("null", .keyword),
                               ("}", .plain)]),
        CodeFixture(name: "yaml", language: .jsonYaml, source: "count: 3 # note",
                    expected: [("count: ", .plain), ("3", .number), (" ", .plain), ("# note", .comment)]),
        CodeFixture(name: "plain", language: .plain, source: "let x = 42 // not code",
                    expected: [("let x = 42 // not code", .plain)]),
    ]
}

@MainActor @Suite(.scratch) struct CodeHighlighterTests {
    @Test(arguments: CodeFixtures.all) func highlighterFixtures(_ f: CodeFixture) {
        let lines = CodeHighlighter.highlight(f.source, language: f.language)
        #expect(lines.count == 1)
        let got = lines.first?.map { ($0.text, $0.kind) } ?? []
        #expect(got.count == f.expected.count, "\(got)")
        for (g, e) in zip(got, f.expected) {
            #expect(g.0 == e.0 && g.1 == e.1, "\(g) vs \(e)")
        }
        #expect(lines.first?.allSatisfy { !$0.hidden } == true)
        // The spans spell the line.
        #expect(lines.first?.map(\.text).joined() == f.source)
    }

    @Test func detectsLanguages() {
        #expect(CodeLanguage.detect(path: "Sources/App.swift") == .swift)
        for ext in ["ts", "tsx", "js", "jsx", "mjs", "cjs"] { #expect(CodeLanguage.detect(path: "a/b.\(ext)") == .typescript) }
        #expect(CodeLanguage.detect(path: "x.py") == .python)
        for ext in ["json", "yaml", "yml"] { #expect(CodeLanguage.detect(path: "c.\(ext)") == .jsonYaml) }
        #expect(CodeLanguage.detect(path: "README.md") == .plain)
        #expect(CodeLanguage.detect(path: "Makefile") == .plain)
        #expect(CodeLanguage.detect(path: "WEIRD.SWIFT") == .swift)
    }

    @Test func multiLineStates() {
        let swift = CodeHighlighter.highlight("/* a\nb */ let x\n\"\"\"\nraw\n\"\"\"", language: .swift)
        #expect(swift.count == 5)
        #expect(swift[0] == [CodeSpan(text: "/* a", kind: .comment, hidden: false)])
        #expect(swift[1].map(\.kind) == [.comment, .plain, .keyword, .plain])
        #expect(swift[3] == [CodeSpan(text: "raw", kind: .string, hidden: false)])
        let python = CodeHighlighter.highlight("s = '''x\ny''' + 1", language: .python)
        #expect(python[1].map(\.kind) == [.string, .plain, .number])
        // An unterminated single-line string ends at its line.
        let ts = CodeHighlighter.highlight("a = \"oops\nlet b", language: .typescript)
        #expect(ts[1].map(\.kind) == [.keyword, .plain])
        // Nested Swift block comments.
        let nested = CodeHighlighter.highlight("/* a /* b */ c */ let", language: .swift)
        #expect(nested[0].map(\.kind) == [.comment, .plain, .keyword])
    }

    @Test func highlighterFuzz() {
        func timed(_ what: String, _ body: () -> [[CodeSpan]]) -> [[CodeSpan]] {
            let start = AwakeTime.now
            let out = body()
            let took = start.duration(to: AwakeTime.now)
            #expect(took < .seconds(1), "\(what) took \(took)")
            return out
        }
        // Unterminated strings and block comments.
        for lang in [CodeLanguage.swift, .typescript, .python, .jsonYaml, .plain] {
            _ = timed("unterminated \(lang)") { CodeHighlighter.highlight("x = \"never closed\n/* never closed\n`still\n'''open", language: lang) }
        }
        // A 100 KB single line.
        let long = String(repeating: "let a = \"x\" + 1 /* c */ ", count: 4_000)
        let longOut = timed("100 KB line") { CodeHighlighter.highlight(long, language: .swift) }
        #expect(longOut.count == 1 && longOut[0].map(\.text).joined() == long)
        // 25k lines: past the cap every span is plain.
        let many = (1...25_000).map { "let v\($0) = \($0) // c" }.joined(separator: "\n")
        let manyOut = timed("25k lines") { CodeHighlighter.highlight(many, language: .swift) }
        #expect(manyOut.count == 25_000 && manyOut.allSatisfy { line in line.allSatisfy { $0.kind == .plain } })
        #expect(CodeHighlighter.maxLines == 20_000)
        // Random bytes decoded lossily.
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<50_000).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let garbage = String(decoding: bytes, as: UTF8.self)
        for lang in [CodeLanguage.swift, .typescript, .python, .jsonYaml] {
            let out = timed("garbage \(lang)") { CodeHighlighter.highlight(garbage, language: lang) }
            // Lines are split by scalar on U+000A with a trailing U+000D dropped (CRLF), so the round trip is modulo that.
            // Hidden characters become markers, so the visible text round-trips modulo them (and modulo CRLF).
            var expected = garbage.replacingOccurrences(of: "\r\n", with: "\n")
            if expected.unicodeScalars.last == "\r" { expected.unicodeScalars.removeLast() }
            expected = String(String.UnicodeScalarView(expected.unicodeScalars.filter { $0 == "\n" || !InvisibleMarkers.isHidden($0) }))
            #expect(out.map { $0.filter { !$0.hidden }.map(\.text).joined() }.joined(separator: "\n") == expected)
        }
        // CRLF and NUL survive.
        let odd = CodeHighlighter.highlight("a\r\nb\u{0}c\n", language: .typescript)
        #expect(odd.count == 3)
    }

    @Test func bidiMarkersShown() {
        let marked = InvisibleMarkers.mark("a\u{202E}b\u{200B}c\u{00AD}")
        #expect(marked.hasHidden)
        #expect(marked.spans.map(\.text) == ["a", "⟦U+202E⟧", "b", "⟦U+200B⟧", "c", "⟦U+00AD⟧"])
        #expect(marked.spans.map(\.hidden) == [false, true, false, true, false, true])
        #expect(InvisibleMarkers.mark("plain text").hasHidden == false)
        #expect(InvisibleMarkers.mark("tab\tand space").spans.count == 1)
        // Inside highlighted code the marker keeps the token's kind and is flagged hidden.
        let lines = CodeHighlighter.highlight("let s = \"a\u{202E}b\"", language: .swift)
        let spans = lines[0]
        #expect(spans.contains { $0.text == "⟦U+202E⟧" && $0.hidden && $0.kind == .string })
        #expect(CodeHighlighter.hasHidden(lines))
        #expect(!CodeHighlighter.hasHidden(CodeHighlighter.highlight("let s = 1", language: .swift)))
        // A marker is visible text: it has no hidden character of its own.
        #expect(InvisibleMarkers.mark("⟦U+202E⟧").hasHidden == false)
    }
}
