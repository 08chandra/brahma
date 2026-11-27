import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite(.scratch) struct PreviewNavTests {
    static func opened(_ key: String) -> OpenedRef {
        OpenedRef(ref: WorkRef(kind: .item, id: key), title: "\(key) title", kindChip: "ITEM", origin: .owner)
    }

    @Test func historyBackForward() {
        var nav = PreviewNav()
        nav.open(Self.opened("A"), select: true)
        nav.open(Self.opened("B"), select: true)
        nav.open(Self.opened("C"), select: true)
        #expect(nav.opened?.ref.id == "C" && nav.selection == PreviewTabID.ref)
        #expect(nav.back.map(\.ref.id) == ["A", "B"] && nav.forward.isEmpty)
        let back1 = nav.goBack()
        #expect(back1 && nav.opened?.ref.id == "B")
        let back2 = nav.goBack()
        #expect(back2 && nav.opened?.ref.id == "A")
        let back3 = nav.goBack()
        #expect(!back3)
        let fwd = nav.goForward()
        #expect(fwd && nav.opened?.ref.id == "B")
        #expect(nav.forward.map(\.ref.id) == ["C"])
        nav.open(Self.opened("D"), select: false)
        #expect(nav.opened?.ref.id == "D" && nav.forward.isEmpty && nav.back.map(\.ref.id) == ["A", "B"])
        for i in 0..<60 { nav.open(Self.opened("N\(i)"), select: true) }
        #expect(nav.back.count == PreviewNav.maxHistory && PreviewNav.maxHistory == 50)
        #expect(nav.back.last?.ref.id == "N58")
        // Forward is capped too.
        for _ in 0..<60 { _ = nav.goBack() }
        #expect(nav.forward.count <= PreviewNav.maxHistory)
    }

    @Test func historyIsPerCompany() {
        let defaults = TestDefaults.make("previewNav")
        var c = PreviewNav()
        c.open(Self.opened("ENG-1"), select: true)
        var d = PreviewNav()
        d.open(Self.opened("DCO-9"), select: true)
        PreviewNavStore.save(c, companyId: "C", defaults: defaults)
        PreviewNavStore.save(d, companyId: "D", defaults: defaults)
        #expect(PreviewNavStore.load(companyId: "C", defaults: defaults).opened?.ref.id == "ENG-1")
        #expect(PreviewNavStore.load(companyId: "D", defaults: defaults).opened?.ref.id == "DCO-9")
        #expect(PreviewNavStore.load(companyId: "E", defaults: defaults) == PreviewNav())
        // A decode failure is an empty state, never a crash.
        defaults.set(Data("not json".utf8), forKey: "brahma.previewNav.C")
        #expect(PreviewNavStore.load(companyId: "C", defaults: defaults) == PreviewNav())
    }

    @Test func stepsChips() {
        let steps = [WorkRef(kind: .preview, id: "web", params: ["path": "/checkout", "viewport": "iphone"]),
                     WorkRef(kind: .artifact, id: "4"), WorkRef(kind: .run, id: "551")]
        var r = OpenedRef(ref: steps[0], title: "preview web/checkout", kindChip: "PREVIEW", origin: .showAnswer(requestId: "r1", by: "@eng-1"),
                          steps: steps, stepIndex: 0)
        #expect(r.stepChips == ["1 PREVIEW", "2 ARTIFACT", "3 RUN"])
        var nav = PreviewNav()
        nav.open(r, select: true)
        nav.step(to: 2)
        #expect(nav.opened?.ref == steps[2] && nav.opened?.stepIndex == 2 && nav.opened?.kindChip == "RUN")
        nav.step(to: 7)  // out of range: unchanged
        #expect(nav.opened?.stepIndex == 2)
        // Stepping is not history.
        #expect(nav.back.isEmpty)
        r.steps = nil
        #expect(r.stepChips == nil)
    }

    @Test func openedTabUsesRefId() {
        var p = PreviewSnapshot.empty
        p.surfaces = [PreviewSurface(id: "s1", companyId: "c", name: "web", position: 0, build: nil, run: "npm start",
                                     url: "http://127.0.0.1:{port}/", smoke: [], setById: "a1", createdAt: .now, updatedAt: .now)]
        let none = PreviewTabs.make(p, opened: nil)
        #expect(none.map(\.id) == ["surface:s1"])
        let tabs = PreviewTabs.make(p, opened: Self.opened("ENG-1"))
        #expect(tabs.map(\.id) == ["surface:s1", PreviewTabID.ref])
        let opened = tabs.last!
        #expect(opened.title == "OPENED" && opened.statusTitle == "ITEM" && opened.tone == .accent && opened.surfaceId == nil)
        #expect(opened.closable && !tabs[0].closable)
        #expect(PreviewTabs.resolve(PreviewTabID.ref, tabs) == PreviewTabID.ref)
        #expect(PreviewTabs.defaultSelection(tabs) == "surface:s1")
        // `.ref` is a `PreviewBody` case the pane can show.
        let body = PreviewBody.ref(RefBody(header: RefHeader(title: "t", subtitle: "", chips: [], actions: []), content: .unavailable("X")))
        if case .ref(let b) = body { #expect(b.content == .unavailable("X")) } else { Issue.record("not a ref body") }
    }
}
