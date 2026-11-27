import Testing
import Foundation
@testable import BrahmaCore
@testable import BrahmaAppModel

/// Plan C Task C7a: the small model seams the views need (a card's ref to open, the Inbox file request card, the SHARING rows,
/// "Open in chat"), each a thin owner-side call over an existing engine API, failing closed without the stored values.
@MainActor @Suite(.scratch) struct RefViewsModelTests {
    /// The app over `w` with `vault` as its secret store (the test defaults otherwise).
    func app(_ w: RefWorld, vault: any SecretVault) async -> AppModel {
        let model = AppModel(store: w.store, paths: w.paths, secretVault: vault, clock: { Date() })
        model.refArchives = { _, _, _ in UnavailableArchiveReader() }
        model.navDefaults = UserDefaults(suiteName: "brahma.tests.refviews.\(UUID().uuidString)") ?? .standard
        await model.load()
        await model.selectCompany(w.company.id)
        return model
    }

    @Test func cardCarriesItsRefToOpen() throws {
        let w = try RefWorld()
        let ctx = try w.renderContext()
        let item = try AttachmentCards.make(try w.resolve("ENG-1"), store: w.store, context: ctx)
        #expect(item.ref == (try w.ref("ENG-1")))
        // An agent's note never rides along on the card's ref.
        var noted = try w.resolve("ENG-1")
        noted.ref.params["note"] = "look at this"
        #expect(try AttachmentCards.make(noted, store: w.store, context: ctx).ref?.params["note"] == nil)
        // A locked card opens nothing.
        let locked = ResolvedRef(ref: WorkRef(kind: .file, id: "x"), reader: .agent(w.eng1.id), visibility: .locked(approverRole: "cto"),
                                 title: "", subtitle: "", bytes: nil, provenance: .engine, tainted: false, taintReason: nil,
                                 accessClass: .ownerOnly, newer: nil, state: .ok, opaqueId: "o")
        #expect(try AttachmentCards.make(locked, store: w.store, context: ctx).ref == nil)
    }

    @Test func fileRequestCardIsTheEnginesGatedCard() async throws {
        let w = try RefWorld()
        let ask = try w.store.requestFileFromOwner(companyId: w.company.id, by: w.eng1.id, title: "Logo", question: "Can you send the logo SVG?",
                                                   details: nil, knownValues: [], now: w.now)
        let app = await w.app()
        let card = await app.fileRequestCard(askId: ask.id)
        #expect(card?.askId == ask.id && card?.title == "Logo" && card?.question == "Can you send the logo SVG?")
        #expect(card?.requesterHandle.contains("eng-1") == true)
        // Anything that is not one of this company's file requests: nothing.
        #expect(await app.fileRequestCard(askId: "nope") == nil)
    }

    @Test func fileRequestCardRefusesWithoutStoredValues() async throws {
        let w = try RefWorld()
        try w.store.setSecret(companyId: w.company.id, name: "API_KEY", value: "v-" + String(repeating: "q", count: 20), isTest: false,
                              vault: MemoryVault())
        let ask = try w.store.requestFileFromOwner(companyId: w.company.id, by: w.eng1.id, title: "Logo", question: "Can you send it?",
                                                   details: nil, knownValues: [], now: w.now)
        let app = await app(w, vault: UnavailableVault())
        #expect(await app.fileRequestCard(askId: ask.id) == nil)
    }

    @Test func sharingRowsFollowTheFeedAndTheReadsToggle() async throws {
        let w = try RefWorld()
        let app = await w.app()
        let ref = try w.ref("Sources/App.swift")
        #expect(await app.share(refs: [ref], to: "#general", note: nil))
        await app.tick(forceSnapshot: true)
        let rows = try await app.sharingRows(reads: false)
        #expect(rows.contains { $0.ref.contains("Sources/App.swift") && $0.to == "#general" })
        #expect(!rows.contains { $0.result.hasPrefix("read") })
        // The owner opens it: with READS on, the read is a row of its own.
        await app.openRef(ref, origin: .owner)
        let withReads = try await app.sharingRows(reads: true)
        #expect(withReads.contains { $0.result.hasPrefix("read") && $0.ref.contains("Sources/App.swift") })
    }

    @Test func sharingRowsRefuseWithoutStoredValues() async throws {
        let w = try RefWorld()
        try w.store.setSecret(companyId: w.company.id, name: "API_KEY", value: "v-" + String(repeating: "q", count: 20), isTest: false,
                              vault: MemoryVault())
        let app = await app(w, vault: UnavailableVault())
        await #expect(throws: (any Error).self) { try await app.sharingRows(reads: true) }
    }

    @Test func openInChatSelectsTheConversationAndHighlights() async throws {
        let w = try RefWorld()
        let app = await w.app()
        let posted = try MessageRouter(store: w.store).postDetailed(companyId: w.company.id, channel: "general", from: .owner, text: "hello there",
                                                                    replyTo: nil)
        await app.openInChat(messageId: posted.message.id)
        #expect(app.sidebarSelection == .channel(id: w.general.id))
        #expect(app.highlightedMessageId == posted.message.id)
        // A message of nobody's: the generic refusal, nothing selected.
        app.select(.missionControl)
        await app.openInChat(messageId: "nope")
        #expect(app.sidebarSelection == .missionControl && app.errorMessage != nil)
    }

    // MARK: Ruling C7a-1: "Concierge" only from the engine's own flag, never from a name

    @Test func anAgentNamedLikeTheConciergeShowsItsHandle() throws {
        let w = try RefWorld()
        var m = Message(id: "m1", companyId: w.company.id, channelId: "ch", senderId: w.eng1.id,
                        text: "The checkout totals are wrong on mobile [1].", createdAt: w.now)
        m.kind = .showAnswer
        m.answerVerified = true
        let body = RefBodies.answerBody(message: m, refs: [try w.ref("ENG-1")], by: "@Concierge-helper", knownValues: [])
        guard case .answer(_, _, _, _, _, let by, let concierge) = body.content else {
            Issue.record("expected an answer body, got \(body.content)")
            return
        }
        #expect(!concierge && by == "@Concierge-helper")
        #expect(RefBodies.authorLabel(by: by, concierge: concierge) == "@Concierge-helper")
        #expect(body.header.subtitle == "from @Concierge-helper")
        // The origin of steps an agent's answer opened says the same.
        #expect(OpenOrigin.showAnswer(requestId: "r", by: "@concierge-helper").answeredBy == "@concierge-helper")
        #expect(OpenOrigin.showAnswer(requestId: "r", by: "Brahma").answeredBy == "Brahma")
        #expect(OpenOrigin.owner.answeredBy == nil)
    }

    @Test func theConciergesOwnAnswerShowsConcierge() throws {
        let w = try RefWorld()
        var m = Message(id: "m2", companyId: w.company.id, channelId: "ch", senderId: ConciergeCaps.agentId,
                        text: "Nothing is blocked right now [1].", createdAt: w.now)
        m.kind = .showAnswer
        m.answerVerified = true
        let body = RefBodies.answerBody(message: m, refs: [try w.ref("ENG-1")], by: "Brahma", knownValues: [])
        guard case .answer(_, _, _, _, _, let by, let concierge) = body.content else {
            Issue.record("expected an answer body, got \(body.content)")
            return
        }
        #expect(concierge)
        #expect(RefBodies.authorLabel(by: by, concierge: concierge) == "Concierge")
        #expect(OpenOrigin.showAnswer(requestId: "r", by: "Brahma", concierge: true).answeredBy == "Concierge")
    }
}
