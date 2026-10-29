import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

@Suite(.scratch) struct SafeMarkdownTests {
    func text(_ a: AttributedString) -> String { String(a.characters) }

    func workspace() throws -> URL {
        let url = try tempDir().appending(path: "ws", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func linksBecomePlainText() {
        let out = SafeMarkdown.render("Read [the docs](https://evil.example/x) now, or <https://evil.example/auto>.")
        #expect(text(out).contains("Read the docs now"))
        #expect(text(out).contains("https://evil.example/auto"))
        #expect(out.runs.allSatisfy { $0.link == nil })
    }

    @Test func imagesNotLoaded() {
        let out = SafeMarkdown.render("Look: ![architecture diagram](https://evil.example/pixel.png) and ![](https://evil.example/b.png)")
        #expect(text(out).contains("architecture diagram [image not shown]"))
        #expect(text(out).contains("[image not shown]"))
        #expect(!text(out).contains("evil.example"))
        #expect(out.runs.allSatisfy { $0.imageURL == nil && $0.link == nil })
    }

    @Test func htmlStaysLiteral() {
        let out = SafeMarkdown.render("Hi <b>bold</b> <script>alert(1)</script> <a href=\"https://evil.example\">x</a>\n\n<div>block</div>")
        #expect(text(out).contains("<b>bold</b>"))
        #expect(text(out).contains("<script>alert(1)</script>"))
        #expect(text(out).contains("<a href=\"https://evil.example\">x</a>"))
        #expect(text(out).contains("<div>block</div>"))
        #expect(out.runs.allSatisfy { $0.link == nil })
    }

    @Test func headingsAndListsKept() {
        let out = SafeMarkdown.render("# Title\n\nIntro with **bold**.\n\n- one\n- two\n\n1. first\n2. second\n")
        let plain = text(out)
        #expect(plain.contains("Title\nIntro with bold."))
        #expect(plain.contains("• one\n• two"))
        #expect(plain.contains("1. first\n2. second"))
        let title = out.runs.first { text(AttributedString(out[$0.range])) == "Title" }
        #expect(title?.presentationIntent?.components.contains { $0.kind == .header(level: 1) } == true)
        #expect(out.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    @Test func pathOutsideWorkspaceRefused() throws {
        let ws = try workspace()
        let outside = ws.deletingLastPathComponent().appending(path: "secret.md")
        try "top secret".write(to: outside, atomically: true, encoding: .utf8)
        try "fine".write(to: ws.appending(path: "ok.md"), atomically: true, encoding: .utf8)
        if case .failure(let e) = SafeMarkdown.load(documentPath: "ok.md", workspace: ws.path) { Issue.record("refused: \(e)") }
        for path in ["../secret.md", outside.path, "/etc/hosts", "sub/../../secret.md"] {
            #expect(SafeMarkdown.load(documentPath: path, workspace: ws.path) == .failure(.outsideWorkspace), "\(path)")
        }
        // A symlink inside the workspace that points outside is followed before the check.
        try FileManager.default.createSymbolicLink(at: ws.appending(path: "link.md"), withDestinationURL: outside)
        #expect(SafeMarkdown.load(documentPath: "link.md", workspace: ws.path) == .failure(.outsideWorkspace))
        // So is one that points to a directory outside.
        try FileManager.default.createSymbolicLink(at: ws.appending(path: "dir"), withDestinationURL: ws.deletingLastPathComponent())
        #expect(SafeMarkdown.load(documentPath: "dir/secret.md", workspace: ws.path) == .failure(.outsideWorkspace))
        // A symlink to a file inside the workspace is fine.
        try FileManager.default.createSymbolicLink(at: ws.appending(path: "alias.md"), withDestinationURL: ws.appending(path: "ok.md"))
        if case .failure(let e) = SafeMarkdown.load(documentPath: "alias.md", workspace: ws.path) { Issue.record("refused: \(e)") }
    }

    @Test func tooLargeRefused() throws {
        let ws = try workspace()
        try Data(repeating: UInt8(ascii: "a"), count: SafeMarkdown.maxBytes + 1).write(to: ws.appending(path: "big.md"))
        try Data(repeating: UInt8(ascii: "a"), count: SafeMarkdown.maxBytes).write(to: ws.appending(path: "edge.md"))
        #expect(SafeMarkdown.load(documentPath: "big.md", workspace: ws.path) == .failure(.tooLarge))
        if case .failure(let e) = SafeMarkdown.load(documentPath: "edge.md", workspace: ws.path) { Issue.record("refused: \(e)") }
    }

    @Test func nonTextRefused() throws {
        let ws = try workspace()
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: ws.appending(path: "image.md"))
        try FileManager.default.createDirectory(at: ws.appending(path: "folder"), withIntermediateDirectories: true)
        #expect(SafeMarkdown.load(documentPath: "image.md", workspace: ws.path) == .failure(.notText))
        #expect(SafeMarkdown.load(documentPath: "folder", workspace: ws.path) == .failure(.notText))
        #expect(SafeMarkdown.load(documentPath: "missing.md", workspace: ws.path) == .failure(.notFound))
    }
}
