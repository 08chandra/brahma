import Testing
import Foundation
import GRDB
@testable import BrahmaCore
@testable import BrahmaAppModel

/// C6 fix round 1: the review's findings on the render path (I1, I2/M7, I3, I4, I5, I6, M2, M4, M5, M6, M10, M12) and the
/// C6-1 refinement (owner provenance only from an owner-drop record).
@MainActor @Suite(.scratch) struct RefRenderGateTests {
    /// A Stripe-shaped live key, built from parts (Ruling C5b-4).
    static let secret = "sk_" + "live_" + String(repeating: "q", count: 24)

    static func commit(_ w: RefWorld, _ files: [(String, Data)]) throws -> String {
        for (path, data) in files {
            let url = w.workspace.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try RefWorld.git(["add", "-A"], in: w.workspace)
        try RefWorld.git(["commit", "-q", "-m", "assets"], in: w.workspace)
        let sha = try w.head()
        let companyId = w.company.id
        try w.write { db in try db.execute(sql: "UPDATE company SET mainCommit = ? WHERE id = ?", arguments: [sha, companyId]) }
        return sha
    }

    // MARK: I1 — every render goes through gatedBytes and honours its verdict

    @Test func patternsInRenderedFilesAreRedactedOrRefused() async throws {
        let w = try RefWorld()
        let s = Self.secret
        _ = try Self.commit(w, [("notes.md", Data("# Notes\n\nkey \(s) here\n".utf8)),
                                ("page.html", Data("<p>\(s)</p>".utf8)),
                                ("data.csv", Data("a,b\n1,\(s)\n".utf8)),
                                ("img/tagged.png", TinyPNG.make(text: s))])
        let ctx = try w.renderContext()
        for path in ["notes.md", "page.html", "data.csv"] {
            let body = try await RefBodies.body(for: try w.resolve(path), store: w.store, companyId: w.company.id, context: ctx)
            guard case .file(let fb, _) = body.content else {
                Issue.record("\(path): expected a file body, got \(body.content)")
                continue
            }
            let written = try String(contentsOf: fb.url, encoding: .utf8)
            #expect(!written.contains(s), "\(path)")
            #expect(written.contains("[redacted"), "\(path)")
        }
        // A PNG text chunk can't be redacted: nothing is drawn.
        let png = try await RefBodies.body(for: try w.resolve("img/tagged.png"), store: w.store, companyId: w.company.id, context: ctx)
        if case .file = png.content { Issue.record("a PNG holding a secret pattern was written for drawing") }
        if case .unavailable(let text) = png.content { #expect(!text.contains(s)) }
        // A card never writes the pattern either.
        let card = try AttachmentCards.make(try w.resolve("notes.md"), store: w.store, context: ctx)
        if case .code(let lines) = card.preview { #expect(!lines.flatMap { $0 }.map(\.text).joined().contains(s)) }
        // The render record says what the gate said.
        let render = try w.store.renderRef(companyId: w.company.id, ref: try w.ref("notes.md"), knownValues: [], paths: w.paths,
                                           archives: UnavailableArchiveReader(), via: nil, owner: try w.owner())
        if case .pattern = render.verdict {} else { Issue.record("verdict \(render.verdict)") }
        #expect(!String(decoding: render.data, as: UTF8.self).contains(s))
    }

    // MARK: C1 refinement — owner provenance only from an owner drop

    @Test func shareCopiesAreNeverOwnerProvenance() async throws {
        let w = try RefWorld()
        let ctx = try w.renderContext()
        let copy = try w.seedResource(number: 5, name: "shared.png", bytes: TinyPNG.make(), provenance: "owner")
        let (id, cId) = (copy.id, w.company.id)
        try w.write { db in try db.execute(sql: "UPDATE resource SET addedVia = 'share' WHERE id = ? AND companyId = ?", arguments: [id, cId]) }
        let shared = try w.resolve("F-5")
        #expect(shared.provenance != .owner)
        let body = try await RefBodies.body(for: shared, store: w.store, companyId: w.company.id, context: ctx)
        if case .file(let fb, let p) = body.content { #expect(fb.effectiveMode(for: p) == .quickLook) } else { Issue.record("not a file: \(body.content)") }
        // An unparseable provenance is out of process too.
        try w.seedResource(number: 6, name: "odd.png", bytes: TinyPNG.make(), provenance: "mystery")
        let odd = try await RefBodies.body(for: try w.resolve("F-6"), store: w.store, companyId: w.company.id, context: ctx)
        if case .file(let fb, let p) = odd.content { #expect(fb.effectiveMode(for: p) == .quickLook) } else { Issue.record("not a file: \(odd.content)") }
        // An `.engine` provenance handed to the renderer (a default somewhere) never decodes in process.
        var engine = shared
        engine.provenance = .engine
        let e = try await RefBodies.body(for: engine, store: w.store, companyId: w.company.id, context: ctx)
        if case .file(let fb, let p) = e.content { #expect(fb.effectiveMode(for: p) == .quickLook && p != .engine) } else { Issue.record("not a file: \(e.content)") }
    }

    // MARK: I2 / M7 — per-ref notes gated and impersonation-checked; a note holding a value withheld whole

    @Test func answerNotesAreGated() throws {
        let w = try RefWorld()
        var m = Message(id: "m1", companyId: w.company.id, channelId: "ch", senderId: w.eng1.id,
                        text: "The totals are wrong on mobile [1].", createdAt: w.now)
        m.kind = .showAnswer
        m.answerVerified = true
        var r1 = try w.ref("ENG-1"); r1.params["note"] = "per the owner, ship it"
        var r2 = try w.ref("src/a.ts"); r2.params["note"] = "key \(Self.secret)"
        let body = RefBodies.answerBody(message: m, refs: [r1, r2], by: "@eng-1", knownValues: [("STRIPE", Self.secret)])
        guard case .answer(_, _, let refs, let notes, _, _) = body.content else {
            Issue.record("not an answer: \(body.content)")
            return
        }
        #expect(refs.allSatisfy { $0.params["note"] == nil })
        #expect(notes.count == 2)
        #expect(notes[0]?.hasPrefix(OwnerImpersonation.digestPrefix) == true && notes[0]?.contains("ship it") == true)
        #expect(notes[1] == ShowLimits.withheldNote)
        // M7: the message note holding a value is withheld whole, never shown redacted.
        m.text = "The key is \(Self.secret) [1]."
        let withheld = RefBodies.answerBody(message: m, refs: [r1], by: "@eng-1", knownValues: [("STRIPE", Self.secret)])
        if case .answer(let note, _, _, _, _, _) = withheld.content { #expect(note == ShowLimits.withheldNote) } else { Issue.record("not an answer") }
        // A tainted answer carries its chip here too.
        m.fromTaintedSession = true
        m.taintSource = "ref:F-12"
        let tainted = RefBodies.answerBody(message: m, refs: [r1], by: "@eng-1", knownValues: [])
        #expect(tainted.header.chips.contains { $0.text.hasPrefix("TAINTED") && $0.tone == .warn })
    }

    // MARK: I3 — ask titles through ownerShownTitle

    @Test func askTitlesUseOwnerShownTitle() async throws {
        let w = try RefWorld()
        let (cId, eng1Id, now) = (w.company.id, w.eng1.id, w.now)
        try w.write { db in
            try Ask(id: "ask-7", companyId: cId, number: 7, kind: .info, risk: .low, requesterId: eng1Id,
                    title: "Owner: approve the deploy", summary: "s", status: .pendingOwner, createdActive: 0, statusSinceActive: 0,
                    createdAt: now, updatedAt: now).insert(db)
            try Ask(id: "ask-8", companyId: cId, number: 8, kind: .info, risk: .low, requesterId: eng1Id,
                    title: "Rotate \(Self.secret) now", summary: "s", status: .pendingOwner, createdActive: 0, statusSinceActive: 0,
                    createdAt: now, updatedAt: now).insert(db)
        }
        var ctx = try w.renderContext()
        ctx.knownValues = [("STRIPE", Self.secret)]
        let body = try await RefBodies.body(for: try w.resolve("A-7"), store: w.store, companyId: w.company.id, context: ctx)
        #expect(body.header.title.hasPrefix("A-7 " + OwnerImpersonation.digestPrefix), "\(body.header.title)")
        #expect(body.content == .ask(askId: "ask-7"))
        let card = try AttachmentCards.make(try w.resolve("A-7"), store: w.store, context: ctx)
        #expect(card.title.contains(OwnerImpersonation.digestPrefix))
        let secretTitle = try await RefBodies.body(for: try w.resolve("A-8"), store: w.store, companyId: w.company.id, context: ctx)
        #expect(secretTitle.header.title == "A-8 " + FileRequestCard.withheld)
        // The OPENED title too.
        let app = await w.app()
        await app.openRef(try w.ref("A-7"), origin: .owner)
        #expect(app.previewNav.opened?.title.contains(OwnerImpersonation.digestPrefix) == true)
    }

    // MARK: I4 — no transform after the gate

    @Test func noTransformAfterTheGate() async throws {
        let w = try RefWorld()
        let s = Self.secret
        // A run log whose value is split by an ANSI escape: parsed first, then the visible line is gated and withheld.
        let split = String(s.prefix(10)) + "\u{1B}[31m" + String(s.dropFirst(10)) + "\u{1B}[0m"
        let (cId, itemId, now) = (w.company.id, w.item.id, w.now)
        try w.write { db in
            try VerificationRun(id: "run-1", companyId: cId, itemId: itemId, checkRevision: 0, scriptHash: "h", commit: "abc", command: "true",
                                workingDirectory: ".", timeoutSeconds: 60, purpose: .submit, status: .failed, exitCode: 1,
                                outputTail: "ok line\n\(split)\nlast line", createdAt: now).insert(db)
        }
        var ctx = try w.renderContext()
        ctx.knownValues = [("STRIPE", s)]
        let run = try await RefBodies.body(for: try w.resolve("run:run-1"), store: w.store, companyId: w.company.id, context: ctx)
        guard case .run(let lines, _) = run.content else {
            Issue.record("not a run: \(run.content)")
            return
        }
        let visible = lines.map { $0.map(\.text).joined() }
        #expect(!visible.joined(separator: "\n").contains(s))
        #expect(visible.contains("ok line") && visible.contains("last line"))
        #expect(visible.contains("(withheld)"))
        // A handbook page whose value is split by markup: the rendered projection joins it, so the page is withheld.
        _ = try w.store.kbWrite(companyId: w.company.id, by: .owner, path: "Eng/Keys", body: "# Keys\n\n\(s.prefix(8))**\(s.dropFirst(8))**\n", knownValues: [])
        let kb = try await RefBodies.body(for: try w.resolve("kb:Eng/Keys"), store: w.store, companyId: w.company.id, context: ctx)
        if case .kb(let markdown, _, _) = kb.content {
            #expect(!markdown.contains(s))
            #expect(!String(SafeMarkdown.render(markdown).characters).contains(s))
        } else { Issue.record("not a kb body: \(kb.content)") }
        // A taint chip is uppercased before it is gated, never after.
        let tainted = ResolvedRef(ref: try w.ref("@eng-1"), reader: .owner, visibility: .full, title: "@eng-1", subtitle: "engineer · ready",
                                  bytes: nil, provenance: .agent(w.eng1.id), tainted: true, taintReason: "ref:F-\(s)", accessClass: .company,
                                  newer: nil, state: .ok, opaqueId: "o")
        let agent = try await RefBodies.body(for: tainted, store: w.store, companyId: w.company.id, context: ctx)
        #expect(!agent.header.chips.contains { $0.text.contains(s) || $0.text.contains(s.uppercased()) })
    }

    // MARK: I5 — SharingRows strings gated

    @Test func sharingRowsAreGated() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [ActivityEvent(id: 1, companyId: "c", agentId: "a1", turnId: nil, kind: .share,
                                    text: "@eng-1 shared src/\(Self.secret).ts with #general", createdAt: t0),
                      ActivityEvent(id: 2, companyId: "c", agentId: "a1", turnId: nil, kind: .access,
                                    text: "@eng-1's share was refused: \u{202E}evil", createdAt: t0 + 1)]
        let reads = [RefRead(companyId: "c", readerKind: "agent", readerId: "a1", canonical: "notes/\(Self.secret).md", rev: nil, bytes: 1,
                             tainted: false, via: "open_ref", turnId: nil, createdAt: t0 + 2)]
        let rows = SharingRows.make(events: events, reads: reads, handles: ["a1": "eng-1"], timeZone: TimeZone(identifier: "UTC")!,
                                    knownValues: [("STRIPE", Self.secret)])
        #expect(rows.count == 3)
        for row in rows {
            for text in [row.from, row.to, row.ref, row.result, row.session] {
                #expect(!text.contains(Self.secret))
                #expect(!text.unicodeScalars.contains { InvisibleMarkers.isHidden($0) })
            }
        }
        #expect(rows.contains { $0.ref == "(withheld)" })
    }

    // MARK: I6 — tainted answers keep their chip; chat messages carry a taint marker

    @Test func taintedAnswersKeepTheirChip() async throws {
        let w = try RefWorld()
        let app = await w.app()
        let (cId, eng1Id, now) = (w.company.id, w.eng1.id, w.now)
        let dm = try MessageRouter(store: w.store).sendDM(companyId: cId, from: .agent(eng1Id), to: "owner", text: "see [1]", now: now)
        try w.write { db in
            try db.execute(sql: "UPDATE message SET kind = 'showAnswer', fromTaintedSession = 1, taintSource = 'ref:F-12' WHERE id = ?", arguments: [dm.id])
            try ShowRequest(id: "req-1", companyId: cId, number: 1, kind: .show, query: "totals", attachedRef: nil, target: "agent", targetAgentId: eng1Id,
                            routedBy: "rule", reason: "holder", candidates: "[]", status: .answered, answerMessageId: dm.id, turnId: nil, costUSD: nil,
                            costShare5h: nil, autoOpenedAt: nil, createdAt: now, createdActive: 0).insert(db)
        }
        let auto = AutoOpen(requestId: "req-1", answerMessageId: dm.id, refs: [try w.ref("ENG-1"), try w.ref("src/a.ts")], by: "@eng-1")
        await app.applyAutoOpen(auto, decision: .openAndSelect, title: "Checkout totals · answered")
        try await eventually { app.openedBody != nil }
        #expect(app.openedBody?.header.chips.contains { $0.text.hasPrefix("TAINTED") && $0.tone == .warn } == true)
        // Chat: the message carries the marker for the view.
        let chat = ChatModel(store: w.store, companyId: cId, target: .dm(handle: "eng-1"))
        await chat.refresh()
        let shown = try #require(chat.messages.first { $0.id == dm.id })
        #expect(shown.isTainted && shown.taintSource == "ref:F-12")
    }

    // MARK: M2 — the 20k line cap

    @Test func renderedFilesStopAtTheLineCap() async throws {
        let w = try RefWorld()
        let many = (1...25_000).map { "line \($0)" }.joined(separator: "\n") + "\n"
        _ = try Self.commit(w, [("big.txt", Data(many.utf8))])
        let body = try await RefBodies.body(for: try w.resolve("big.txt"), store: w.store, companyId: w.company.id, context: try w.renderContext())
        guard case .code(let lines, _, _, _) = body.content else {
            Issue.record("not code: \(body.content)")
            return
        }
        #expect(lines.count == RefBodies.maxLines + 1 && RefBodies.maxLines == 20_000)
        #expect(lines.last?.map(\.text).joined().contains("5000 more lines") == true)
        #expect(body.header.chips.contains { $0.text == "TRUNCATED" })
    }

    // MARK: M4 — per-open copies live in a private dir and go away

    @Test func openCopiesAreCleanedUp() async throws {
        let w = try RefWorld()
        _ = try Self.commit(w, [("img/a.png", TinyPNG.make()), ("img/b.png", TinyPNG.make())])
        let app = await w.app()
        let root = app.renderScratch
        #expect(root.path.hasPrefix(w.paths.home.path))
        await app.openRef(try w.ref("img/a.png"), origin: .owner)
        try await eventually { app.openedBody != nil }
        func opens() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix("open-") } }
        #expect(opens().count == 1)
        await app.openRef(try w.ref("img/b.png"), origin: .owner)
        try await eventually { app.openedBody != nil }
        #expect(opens().count == 1)
        app.closeOpened()
        #expect(opens().isEmpty)
        // Launch cleans whatever an earlier run left.
        try FileManager.default.createDirectory(at: root.appending(path: "open-stale"), withIntermediateDirectories: true)
        let again = await w.app()
        #expect(!FileManager.default.fileExists(atPath: again.renderScratch.appending(path: "open-stale").path))
        let attrs = try FileManager.default.attributesOfItem(atPath: root.path)
        #expect((attrs[FileAttributeKey.posixPermissions] as? Int) == 0o700)
    }

    // MARK: M5 — copyRef is Ruling 58's literal, off the main actor

    @Test func copyRefIsAnEscapedLiteral() async throws {
        let w = try RefWorld()
        let app = await w.app()
        #expect(await app.copyRef(try w.ref("src/a.ts")) == "\"src/a.ts\"")
        #expect(await app.copyRef(WorkRef(kind: .file, id: "weird [x] \"q\".ts")) == "\"weird \\u005Bx\\u005D \\u0022q\\u0022.ts\"")
    }

    // MARK: M6 — purge only after an explicit owner confirmation

    @Test func purgeNeedsTheOwnersConfirmation() async throws {
        let w = try RefWorld()
        let app = await w.app()
        let before = try w.count("purgeLog")
        let report = await app.purge(try w.ref("src/a.ts"))
        #expect(report == nil && app.errorMessage?.contains("Confirm") == true)
        #expect(try w.count("purgeLog") == before)
        try w.seedResource(number: 9, name: "x.md", bytes: Data("x\n".utf8), provenance: "owner")
        app.errorMessage = nil
        _ = await app.purge(try w.ref("F-9"))
        #expect(app.errorMessage?.contains("Confirm") == true)
        #expect(try w.store.resource(companyId: w.company.id, number: 9)?.purgedAt == nil)
    }

    // MARK: M10 — artifact bytes through gatedBytes

    @Test func artifactsRenderThroughTheGate() async throws {
        let w = try RefWorld()
        let s = Self.secret
        let folder = ".brahma/artifacts/3-seeded"
        try RefWorld.write("\(folder)/index.html", "<p>\(s)</p>", in: w.workspace)
        let (cId, eng1Id, now) = (w.company.id, w.eng1.id, w.now)
        try w.write { db in
            try Artifact(id: UUID().uuidString, companyId: cId, number: 3, title: "Mock", kind: .html, storedPath: folder, entryFile: "index.html",
                         sourcePath: "/x", publishedById: eng1Id, itemId: nil, bytes: 20, createdAt: now).insert(db)
        }
        let body = try await RefBodies.body(for: try w.resolve("AR-3"), store: w.store, companyId: w.company.id, context: try w.renderContext())
        guard case .file(let fb, let p) = body.content else {
            Issue.record("expected a gated file body, got \(body.content)")
            return
        }
        #expect(fb.kind == .html && fb.mode == .web && p == .agent(w.eng1.id))
        #expect(!(try String(contentsOf: fb.url, encoding: .utf8)).contains(s))
        #expect(!fb.url.path.contains(".brahma/artifacts"))
    }

    // MARK: M12 — PreviewNav persists canonicals only and re-gates on restore

    @Test func previewNavPersistsCanonicalsOnly() async throws {
        var step = WorkRef(kind: .item, id: "ENG-2")
        step.params["note"] = "agent words"
        let opened = OpenedRef(ref: step, title: "ENG-2 agent title", kindChip: "ITEM", origin: .showAnswer(requestId: "r", by: "@eng-1"),
                               steps: [step, WorkRef(kind: .file, id: "src/a.ts")], stepIndex: 0)
        var nav = PreviewNav()
        nav.open(opened, select: true)
        let data = try JSONEncoder().encode(nav)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("agent title") && !json.contains("agent words") && !json.contains("\"title\""))
        let back = try JSONDecoder().decode(PreviewNav.self, from: data)
        #expect(back.opened?.ref.canonical == "ENG-2" && back.opened?.ref.params["note"] == nil)
        #expect(back.opened?.title == "" && back.opened?.kindChip == "ITEM" && back.opened?.steps?.count == 2)
        #expect(back.opened?.origin == .showAnswer(requestId: "r", by: "@eng-1"))
        // On restore the app re-resolves and re-gates the title.
        let w = try RefWorld()
        let defaults = UserDefaults(suiteName: "brahma.tests.nav.\(UUID().uuidString)")!
        var saved = PreviewNav()
        saved.open(OpenedRef(ref: try w.ref("ENG-1"), title: "stale", kindChip: "ITEM", origin: .owner), select: true)
        PreviewNavStore.save(saved, companyId: w.company.id, defaults: defaults)
        let model = AppModel(store: w.store, paths: w.paths)
        model.navDefaults = defaults
        await model.load()
        try await eventually { model.previewNav.opened?.title.contains("Checkout totals") == true }
        #expect(model.selectedPreviewTab == PreviewTabID.ref)
    }

    // MARK: Round 2 fold-ins

    @Test func askTitleIsGatedAfterJoining() async throws {
        let w = try RefWorld()
        let (cId, eng1Id, now) = (w.company.id, w.eng1.id, w.now)
        try w.write { db in
            try Ask(id: "ask-9", companyId: cId, number: 9, kind: .info, risk: .low, requesterId: eng1Id, title: "Which API?", summary: "s",
                    status: .pendingOwner, createdActive: 0, statusSinceActive: 0, createdAt: now, updatedAt: now).insert(db)
        }
        var ctx = try w.renderContext()
        // A stored value that is exactly the joined title: the join is gated, so the title is withheld.
        ctx.knownValues = [("JOINED", "A-9 Which API?")]
        let body = try await RefBodies.body(for: try w.resolve("A-9"), store: w.store, companyId: w.company.id, context: ctx)
        #expect(body.header.title == "A-9 " + FileRequestCard.withheld)
        ctx.knownValues = []
        let plain = try await RefBodies.body(for: try w.resolve("A-9"), store: w.store, companyId: w.company.id, context: ctx)
        #expect(plain.header.title == "A-9 Which API?")
    }

    @Test func cardsScratchIsPrivate() async throws {
        let w = try RefWorld()
        let app = await w.app()
        _ = try w.store.ownerShare(companyId: w.company.id, refs: ["src/a.ts"], to: "@eng-1", note: "see", replyTo: nil, knownValues: [], paths: w.paths,
                                   owner: try w.owner())
        let dm = try #require(try w.store.channel(companyId: w.company.id, name: "dm:eng-1:owner"))
        let shared = try #require(try w.store.messages(channelId: dm.id, limit: 5).first)
        try FileManager.default.createDirectory(at: app.renderScratch, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: app.renderScratch.path)
        let cards = try app.makeCardMaker(companyId: w.company.id)(shared)
        #expect(cards.count == 1 && cards[0].kindChip == "FILE")
        let attrs = try FileManager.default.attributesOfItem(atPath: app.renderScratch.path)
        #expect((attrs[FileAttributeKey.posixPermissions] as? Int) == 0o700)
    }

    @Test func refusedPurgeKeepsTheTab() async throws {
        let w = try RefWorld()
        try w.seedResource(number: 9, name: "x.md", bytes: Data("x\n".utf8), provenance: "owner")
        let app = await w.app()
        await app.openRef(try w.ref("F-9"), origin: .owner)
        #expect(app.previewNav.opened?.ref.canonical == "F-9")
        _ = await app.purge(try w.ref("F-9"))
        #expect(app.errorMessage?.contains("Confirm") == true)
        #expect(app.previewNav.opened?.ref.canonical == "F-9" && app.selectedPreviewTab == PreviewTabID.ref)
    }

    @Test func inspectorCopySurvivesTabChanges() async throws {
        let w = try RefWorld()
        _ = try Self.commit(w, [("img/a.png", TinyPNG.make()), ("img/b.png", TinyPNG.make())])
        let app = await w.app()
        await app.openRef(try w.ref("img/a.png"), origin: .owner)
        try await eventually { app.openedBody != nil }
        await app.openInInspector(try w.ref("img/b.png"), messageId: "m1")
        try await eventually { app.inspectorBody != nil }
        guard case .file(let inspected, _)? = app.inspectorBody?.content else {
            Issue.record("inspector has no file body: \(String(describing: app.inspectorBody))")
            return
        }
        #expect(FileManager.default.fileExists(atPath: inspected.url.path))
        await app.openRef(try w.ref("img/b.png"), origin: .owner)
        try await eventually { app.openedBody != nil }
        #expect(FileManager.default.fileExists(atPath: inspected.url.path))
        app.closeOpened()
        #expect(FileManager.default.fileExists(atPath: inspected.url.path))
        app.closeInspector()
        #expect(!FileManager.default.fileExists(atPath: inspected.url.path))
    }
}
