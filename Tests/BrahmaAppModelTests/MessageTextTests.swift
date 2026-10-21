import Testing
import Foundation
@testable import BrahmaAppModel

@Suite struct MessageTextTests {
    private func emphasized(_ a: AttributedString) -> [String] {
        a.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(a[$0.range].characters) }
    }

    @Test func messageTextIsVerbatim() {
        let input = "[click](http://evil.example) **bold** @ceo"
        let a = MessageText.attributed(input, handles: ["ceo"])
        #expect(String(a.characters) == input)
        #expect(a.runs.allSatisfy { $0.link == nil })
        #expect(emphasized(a) == ["@ceo"])
        let boldRun = a.runs.first { String(a[$0.range].characters).contains("**bold**") }
        #expect(boldRun != nil)
        #expect(boldRun?.inlinePresentationIntent == nil)
    }

    @Test func unknownMentionNotHighlighted() {
        #expect(emphasized(MessageText.attributed("@ghost hi", handles: ["ceo"])).isEmpty)
        #expect(emphasized(MessageText.attributed("hi @owner", handles: ["ceo"])) == ["@owner"])
        #expect(emphasized(MessageText.attributed("mail a@ceo", handles: ["ceo"])).isEmpty)
    }

    @Test func mentionCompletion() {
        #expect(MentionCompleter.suggestions(for: "hi @c", handles: ["ceo", "cto", "eng"]) == ["ceo", "cto"])
        #expect(MentionCompleter.suggestions(for: "hi @", handles: ["eng", "ceo"]) == ["ceo", "eng"])
        #expect(MentionCompleter.suggestions(for: "mail a@c", handles: ["ceo"]).isEmpty)
        #expect(MentionCompleter.suggestions(for: "hi @ceo done", handles: ["ceo"]).isEmpty)
        #expect(MentionCompleter.complete("hi @c", with: "cto") == "hi @cto ")
        #expect(MentionCompleter.complete("@", with: "ceo") == "@ceo ")
        #expect(MentionCompleter.suggestions(for: "line\n@e", handles: ["eng"]) == ["eng"])
    }
}
