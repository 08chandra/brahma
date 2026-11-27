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
        model.navDefaults = TestDefaults.make("refviews")
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

    // MARK: Fix round 1

    /// I-2a: a ranged ref always renders as code with its range (an `.html` file included), never as the page.
    @Test func rangedHtmlRefRendersAsCode() throws {
        var files = RefWorld.defaultFiles
        files["web/index.html"] = "<h1>Habit tracker</h1>\n<p>Daily streaks</p>\n<p>Reminders</p>\n"
        let w = try RefWorld(files: files)
        let body = try RefBodies.bodyNow(for: try w.resolve("web/index.html:1-2"), store: w.store, companyId: w.company.id,
                                         context: try w.renderContext(), via: nil)
        guard case .code(let lines, _, let highlight, _) = body.content else {
            Issue.record("expected code, got \(body.content)")
            return
        }
        #expect(highlight == LineRange(start: 1, end: 2))
        #expect(lines.first.map { $0.map(\.text).joined() } == "<h1>Habit tracker</h1>")
    }

    /// I-1: a static diff is drawn only when the engine's reading of the same patch agrees (sections, paths, hunk starts and
    /// counts); otherwise nothing of it is drawn.
    @Test func staticDiffIsVerifiedAgainstTheEnginesReading() {
        let gate = GlobalSearch.TextGate(knownValues: [])
        let good = "diff --git a/src/a.ts b/src/a.ts\n--- a/src/a.ts\n+++ b/src/a.ts\n@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n"
        #expect(RefBodies.verifiedDiff(patch: good, gate: gate)?.files.map(\.displayPath) == ["src/a.ts"])
        // The engine reads this deleted file's path from `--- a/`; the parse doesn't agree: refused.
        let hostile = "diff --git a/x b/y.txt b/x b/y.txt\ndeleted file mode 100644\n--- a/x b/y.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-gone\n"
        let engine = ChangesPatch.identity(hostile)
        if DiffModel.parse(patch: hostile, gate: gate).files.map(\.path) != engine.paths {
            #expect(RefBodies.verifiedDiff(patch: hostile, gate: gate) == nil)
        }
        // A parse that disagrees with the engine's identity is refused whatever the cause.
        let parsed = DiffModel.parse(patch: good, gate: gate)
        #expect(ChangesTabModel.verify(parsed, paths: ["src/b.ts"], hunks: ChangesPatch.identity(good).hunks) == ChangesTabModel.unverifiedText)
        #expect(ChangesTabModel.verify(parsed, paths: ["src/a.ts"], hunks: ChangesPatch.identity(good).hunks) == nil)
    }

    /// I-1: the agent "now" live diff is the verified one, with the model's chips (UNCOMMITTED, LIVE, TAINTED…), never LIVE
    /// when refused.
    @Test func agentNowLiveDiffIsVerifiedWithTheModelsChips() throws {
        let c = try ChangesWorld()
        let body = try RefBodies.bodyNow(for: try c.w.resolve("@eng-1"), store: c.w.store, companyId: c.w.company.id,
                                         context: try c.w.renderContext(), via: nil)
        guard case .agentNow(let now) = body.content else {
            Issue.record("expected the agent now view, got \(body.content)")
            return
        }
        #expect(now.liveDiff != nil && now.liveRefusal == nil)
        #expect(now.liveChips.contains(RefChip(text: "UNCOMMITTED", tone: .warn)))
        #expect(now.liveChips.contains(RefChip(text: "LIVE", tone: .busy)))
        // The header carries no LIVE of its own: only the verified section does.
        #expect(!body.header.chips.contains { $0.text == "LIVE" })
        // Refused: no diff, the refusal, and never LIVE.
        let refused = AgentNowModel.verifiedLiveDiff(DiffModel.parse(patch: "diff --git a/src/a.ts b/src/a.ts\n", gate: GlobalSearch.TextGate(knownValues: [])),
                                                    paths: ["other"], hunks: [[]], chips: now.liveChips)
        #expect(refused.diff == nil && refused.refusal == ChangesTabModel.unverifiedText)
        #expect(!refused.chips.contains { $0.text == "LIVE" })
    }

    /// M-3: Save As… suggests the gated display name, sanitized: its last component, no separators, no control or bidi.
    @Test func saveNameIsTheGatedDisplayName() {
        #expect(RefBodies.saveName(title: "src/ev\u{202E}il/a b.ts", kind: .file) == "a b.ts")
        #expect(RefBodies.saveName(title: "../../.ssh/id\u{0007}", kind: .file) == "id")
        #expect(RefBodies.saveName(title: "INITE-3 Reminder fires twice", kind: .item) == "INITE-3 Reminder fires twice")
        #expect(RefBodies.saveName(title: "/", kind: .diff) == "diff")
        #expect(RefBodies.saveName(title: ".hidden", kind: .file) == "file.hidden")
    }

    /// M-6: READS lists the company's recorded reads from the engine's rows, never parsed back out of display text.
    @Test func readsComeFromStructuredRows() async throws {
        let w = try RefWorld()
        let app = await w.app()
        // Opened, never shared: no share event names it, yet its read is listed.
        await app.openRef(try w.ref("src/a.ts"), origin: .owner)
        let rows = try await app.sharingRows(reads: true)
        #expect(rows.contains { $0.result.hasPrefix("read") && $0.ref.contains("src/a.ts") })
        #expect(try w.store.recentRefReads(companyId: "other-company", limit: 50, owner: try w.owner()).isEmpty)
    }

    /// M-9: "Can't provide → reply" is the engine's decline (recorded as declined), owner only.
    @Test func cantProvideDeclinesTheFileRequest() async throws {
        let w = try RefWorld()
        let ask = try w.store.requestFileFromOwner(companyId: w.company.id, by: w.eng1.id, title: "Logo", question: "Can you send it?",
                                                   details: nil, knownValues: [], now: w.now)
        let app = await w.app()
        #expect(await app.declineFileRequest(askId: ask.id, note: "no logo yet"))
        let after = try #require(try w.store.ask(id: ask.id))
        #expect(after.status != .pendingOwner && after.ownerAnswer == "declined: no logo yet")
    }

    /// Ruling C7a-2: a truncated static diff fails closed — its cut (last) section's hunks are checked too: every complete one
    /// against the engine's, the partial one's start lines exactly and its counts within the engine's; anything else is refused.
    @Test func truncatedDiffChecksItsCutSection() {
        let gate = GlobalSearch.TextGate(knownValues: [])
        let patch = "diff --git a/src/a.ts b/src/a.ts\n--- a/src/a.ts\n+++ b/src/a.ts\n@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n"
            + "@@ -10,3 +10,3 @@ func x() {\n ten\n-eleven\n+ELEVEN\n twelve\n"
        // Cut inside the second hunk: verified against the engine's own reading, marked truncated.
        let cut = RefBodies.verifiedDiff(patch: patch, gate: gate, maxLines: 5)
        #expect(cut?.truncated == true && cut?.files.first?.hunks.count == 2)
        // The same cut parse against an engine whose cut section reads a complete hunk elsewhere (the N3-1 pattern): refused.
        let model = DiffModel.parse(patch: patch, gate: gate, maxLines: 5)
        let engine = ChangesPatch.identity(patch)
        var shifted = engine.hunks
        shifted[0][0] = HunkSpan(oldStart: 13, newStart: 13, old: shifted[0][0].old, new: shifted[0][0].new, shown: shifted[0][0].shown)
        #expect(!RefBodies.verifiedTruncated(model, paths: engine.paths, hunks: shifted))
        // …or whose partial hunk starts elsewhere: refused.
        var moved = engine.hunks
        moved[0][1] = HunkSpan(oldStart: 11, newStart: 11, old: moved[0][1].old, new: moved[0][1].new, shown: moved[0][1].shown)
        #expect(!RefBodies.verifiedTruncated(model, paths: engine.paths, hunks: moved))
        #expect(RefBodies.verifiedTruncated(model, paths: engine.paths, hunks: engine.hunks))
    }
}

