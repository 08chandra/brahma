import Testing
import Foundation
@testable import BrahmaCore

/// Plan ML Task 4: the handbook's Markdown structure — sections outside code fences, restriction markers, links, section
/// replacement, the single-section check and the diff summary.
@Suite(.scratch) struct KBMarkdownTests {
    private func slugs(_ body: String) -> [String] { KBMarkdown.sections(body, page: nil).map(\.slug) }

    @Test func sectionsSplitOutsideCodeFences() {
        let body = """
            Lead text
            # One
            ```swift
            # not a heading
            ```
            ## Two
            ~~~
            ## still code
            ~~~
            ### Three
            """
        let sections = KBMarkdown.sections(body, page: nil)
        #expect(sections.map(\.slug) == ["top", "one", "two", "three"])
        #expect(sections.map(\.level) == [0, 1, 2, 3])
        #expect(sections[0].heading == nil); #expect(sections[0].text == "Lead text")
        #expect(sections[1].heading == "One")
        #expect(sections[1].text == "```swift\n# not a heading\n```")
        #expect(sections[2].text == "~~~\n## still code\n~~~")
        // A fence closes only with the same character and at least its length: mismatched lengths stay open.
        let open = "# A\n````\n```\n# inside\n````\n# B\n~~~\n```\n# also inside\n"
        #expect(slugs(open) == ["top", "a", "b"])
        #expect(KBMarkdown.sections(open, page: nil)[2].text == "~~~\n```\n# also inside\n")
        // Duplicate slugs are numbered in order; a heading named Top does not take the lead's slug.
        #expect(slugs("# Notes\n# Notes\n## notes\n# Top") == ["top", "notes", "notes-2", "notes-3", "top-2"])
        // ATX needs a space after the hashes; four spaces of indent is not a heading; closing hashes are dropped.
        #expect(slugs("#NoSpace\n    # indented\n## Closed ##") == ["top", "closed"])
        #expect(KBMarkdown.slug("Hello, World — 2026!") == "hello-world--2026")
    }

    @Test func restrictedMarkerParsed() {
        let sections = KBMarkdown.sections("# Board [restricted]\n# Pay [restricted: cfo, CEO]\n# Open\n", page: nil)
        #expect(sections[1].heading == "Board"); #expect(sections[1].slug == "board")
        #expect(sections[1].marker == ["@executive"]); #expect(sections[1].restrictions == [["@executive"]])
        #expect(sections[2].heading == "Pay"); #expect(sections[2].marker == ["cfo", "ceo"])
        #expect(sections[3].marker == nil); #expect(sections[3].restrictions.isEmpty)
        // A page restriction leads every section's list, the lead's included.
        let paged = KBMarkdown.sections("lead\n# Pay [restricted: cfo]", page: ["@executive"])
        #expect(paged[0].restrictions == [["@executive"]])
        #expect(paged[1].restrictions == [["@executive"], ["cfo"]])
    }

    @Test func restrictionsAccumulateFromEnclosingHeadings() {
        let body = """
            # Company
            ## Board [restricted: cfo]
            ### Notes [restricted: cto]
            #### Detail
            ## Public
            ### Sub
            """
        let s = KBMarkdown.sections(body, page: nil)
        let by = Dictionary(uniqueKeysWithValues: s.map { ($0.slug, $0.restrictions) })
        #expect(by["board"] == [["cfo"]])
        #expect(by["notes"] == [["cfo"], ["cto"]])
        #expect(by["detail"] == [["cfo"], ["cto"]])
        #expect(by["public"] == [])
        #expect(by["sub"] == [])
    }

    @Test func linksParsedPerSection() {
        let body = """
            See [[Engineering/Deploy]] first.
            # Runbook
            Follow kb:Operations/On-call#paging, then [[kb:Design]].
            Ignore [[../bad]] and kb:.hidden and [[INDEX]].
            # Again
            Back to [[engineering/deploy#rollback]] and kb:Product.
            """
        let links = KBMarkdown.links(body)
        #expect(links.map { "\($0.sectionSlug)>\($0.path)" } == [
            "top>Engineering/Deploy", "runbook>Operations/On-call", "runbook>Design", "again>engineering/deploy", "again>Product",
        ])
    }

    @Test func replacingSectionStopsAtNextHeadingOfAnyLevel() {
        let body = "lead\n# A\nold a\n### Deep\ndeep text\n# B\nb text"
        #expect(KBMarkdown.replacing(section: "a", in: body, with: "new a") == "lead\n# A\nnew a\n### Deep\ndeep text\n# B\nb text")
        #expect(KBMarkdown.replacing(section: "deep", in: body, with: "x\ny") == "lead\n# A\nold a\n### Deep\nx\ny\n# B\nb text")
        #expect(KBMarkdown.replacing(section: "top", in: body, with: "") == "# A\nold a\n### Deep\ndeep text\n# B\nb text")
        #expect(KBMarkdown.replacing(section: "missing", in: body, with: "zzz") == body)
    }

    @Test func singleSectionTextCheck() {
        #expect(!KBMarkdown.isSingleSectionText("text\n```\nunclosed", belowLevel: 2))
        #expect(!KBMarkdown.isSingleSectionText("## x", belowLevel: 2))
        #expect(!KBMarkdown.isSingleSectionText("# x", belowLevel: 2))
        #expect(KBMarkdown.isSingleSectionText("### x\nmore", belowLevel: 2))
        #expect(KBMarkdown.isSingleSectionText("```\n## inside a fence\n```", belowLevel: 2))
        #expect(!KBMarkdown.isSingleSectionText("````\n```", belowLevel: 2), "a shorter run does not close the fence")
        #expect(KBMarkdown.isSingleSectionText("plain", belowLevel: 1))
    }

    @Test func diffSummaryCounts() {
        #expect(KBMarkdown.diffSummary(old: "", new: "a\nb") == "+2 −0 lines")
        #expect(KBMarkdown.diffSummary(old: "a\nb\nc", new: "a\nc\nd") == "+1 −1 lines")
        // A multiset: a repeated line counts each time.
        #expect(KBMarkdown.diffSummary(old: "x\nx", new: "x") == "+0 −1 lines")
        #expect(KBMarkdown.diffSummary(old: "same", new: "same") == "+0 −0 lines")
    }

    @Test(arguments: ["Engineering", "Engineering/Deploy guide", "Go-to-market/Pricing (2026), A&B's", "a/b/c/d/e/f"])
    func pathValidationAccepts(_ p: String) throws {
        #expect(try HandbookPath.normalize(p) == p)
    }

    @Test func pathNormalizationTrimsAndStrips() throws {
        #expect(try HandbookPath.normalize("  kb:Engineering /  Deploy   guide #rollback") == "Engineering/Deploy guide")
        let ref = try HandbookPath.normalizeRef("KB:Ops/Paging#On call")
        #expect(ref.path == "Ops/Paging"); #expect(ref.section == "On call")
        #expect(try HandbookPath.normalizeRef("Ops").section == nil)
        #expect(HandbookPath.section(of: "Ops/Paging/Night") == "Ops")
        #expect(HandbookPath.defaultTitle(of: "Ops/Paging/Night") == "Night")
        // Reserved only at the top level.
        #expect(try HandbookPath.normalize("Engineering/README") == "Engineering/README")
    }
}
