import Testing
import Foundation
@testable import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite(.scratch) struct ShowAnswerRouterTests {
    static let auto = AutoOpen(requestId: "r1", answerMessageId: "m1", refs: [WorkRef(kind: .item, id: "ENG-1")], by: "@eng-1")

    @Test func unsolicitedIsCardOnly() {
        #expect(ShowAnswerRouter.decide(auto: nil, waitingChipVisible: true) == .cardOnly)
        #expect(ShowAnswerRouter.decide(auto: nil, waitingChipVisible: false) == .cardOnly)
    }

    @Test func openSelectsOnlyWhileWaiting() {
        #expect(ShowAnswerRouter.decide(auto: Self.auto, waitingChipVisible: true) == .openAndSelect)
        #expect(ShowAnswerRouter.decide(auto: Self.auto, waitingChipVisible: false) == .openInBackground)
        // The decision never asks for focus: no case carries it.
        for d in [AutoOpenDecision.openAndSelect, .openInBackground, .cardOnly] { #expect(!d.requestsFocus) }
        let chip = WaitingChip(text: "Brahma is answering…", requestId: "r1")
        #expect(chip.requestId == "r1" && chip.text.hasPrefix("Brahma"))
    }

    @Test func appliedOpensInTheSlot() async throws {
        let w = try RefWorld()
        let app = await w.app()
        let answer = AutoOpen(requestId: "r1", answerMessageId: "m1", refs: [try w.ref("ENG-1"), try w.ref("src/a.ts")], by: "@eng-1")
        // No chip visible: the answer opens in the background, with a badge and without changing the selected tab.
        app.selectPreviewTab(PreviewTabID.live)
        await app.applyAutoOpen(answer, decision: .openInBackground, title: "Checkout totals · answered")
        #expect(app.previewNav.opened?.ref.canonical == "ENG-1")
        #expect(app.previewNav.opened?.steps?.count == 2 && app.previewNav.opened?.stepIndex == 0)
        #expect(app.previewNav.opened?.origin == .showAnswer(requestId: "r1", by: "@eng-1"))
        #expect(app.selectedPreviewTab == PreviewTabID.live)
        #expect(app.autoOpenBadge == 1)
        // Chip visible: it opens and selects.
        await app.applyAutoOpen(answer, decision: .openAndSelect, title: "Checkout totals · answered")
        #expect(app.selectedPreviewTab == PreviewTabID.ref)
        #expect(app.autoOpenBadge == 0)
    }
}
