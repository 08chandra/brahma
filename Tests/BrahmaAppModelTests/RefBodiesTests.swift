import Testing
import Foundation
import GRDB
@testable import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite(.scratch) struct RefBodiesTests {
    static func resolved(_ ref: WorkRef, visibility: Visibility = .full, state: RefState = .ok, provenance: Provenance = .agent("workspace")) -> ResolvedRef {
        ResolvedRef(ref: ref, reader: .owner, visibility: visibility, title: "t", subtitle: "s", bytes: nil, provenance: provenance,
                    tainted: false, taintReason: nil, accessClass: .company, newer: nil, state: state, opaqueId: "o")
    }

    @Test func unavailableWhenGone() async throws {
        let w = try RefWorld()
        let ctx = try w.renderContext()
        let purged = Self.resolved(WorkRef(kind: .file, id: "src/a.ts"), state: .purged)
        let body = try await RefBodies.body(for: purged, store: w.store, companyId: w.company.id, context: ctx)
        #expect(body.content == .unavailable("NO LONGER AVAILABLE"))
        for v in [Visibility.locked(approverRole: "cto"), .refused, .missing] {
            let b = try await RefBodies.body(for: Self.resolved(WorkRef(kind: .item, id: "ENG-1"), visibility: v), store: w.store,
                                             companyId: w.company.id, context: ctx)
            #expect(b.content == .unavailable("NO LONGER AVAILABLE"))
            #expect(b.header.title == "")
        }
        let memory = try await RefBodies.body(for: Self.resolved(WorkRef(kind: .memory, id: "3")), store: w.store, companyId: w.company.id, context: ctx)
        #expect(memory.content == .unavailable("OPEN THIS IN THE MEMORY BROWSER"))
        let channel = try await RefBodies.body(for: Self.resolved(WorkRef(kind: .channel, id: "general")), store: w.store, companyId: w.company.id, context: ctx)
        #expect(channel.content == .unavailable("OPEN IN CHAT"))
        // A ref that is gone from the store resolves `.missing` for the owner and shows the same text.
        let gone = try w.resolve("src/nothing.ts")
        let goneBody = try await RefBodies.body(for: gone, store: w.store, companyId: w.company.id, context: ctx)
        #expect(goneBody.content == .unavailable("NO LONGER AVAILABLE"))
    }

    @Test func previewPathValidation() async throws {
        let w = try RefWorld()
        try w.seedPreviewSurface()
        let ctx = try w.renderContext()
        let r = try w.resolve("preview:web/checkout@iphone")
        #expect(r.visibility == .full)
        let body = try await RefBodies.body(for: r, store: w.store, companyId: w.company.id, context: ctx)
        guard case .preview(let surfaceId, let path, let viewport, let builtBy) = body.content else {
            Issue.record("expected a preview body, got \(body.content)")
            return
        }
        #expect(!surfaceId.isEmpty && path == "/checkout" && viewport == .iphone && builtBy == "@eng-1")
        // A stored ref whose path would not pass `PreviewRefParams.validate` (two leading slashes) is never built into a URL.
        let evil = Self.resolved(WorkRef(kind: .preview, id: "web", params: ["path": "//evil", "viewport": "iphone"]))
        let evilBody = try await RefBodies.body(for: evil, store: w.store, companyId: w.company.id, context: ctx)
        #expect(evilBody.content == .unavailable("NO LONGER AVAILABLE"))
        let badViewport = Self.resolved(WorkRef(kind: .preview, id: "web", params: ["path": "/ok", "viewport": "9999x1"]))
        let badBody = try await RefBodies.body(for: badViewport, store: w.store, companyId: w.company.id, context: ctx)
        #expect(badBody.content == .unavailable("NO LONGER AVAILABLE"))
    }

    @Test func agentFilesUseOutOfProcessModes() async throws {
        let w = try RefWorld()
        try w.seedResource(number: 1, name: "logo.png", bytes: TinyPNG.make(), provenance: "agent:\(w.eng1.id)")
        try w.seedResource(number: 2, name: "mine.png", bytes: TinyPNG.make(), provenance: "owner")
        let ctx = try w.renderContext()
        let agent = try await RefBodies.body(for: try w.resolve("F-1"), store: w.store, companyId: w.company.id, context: ctx)
        guard case .file(let fb, let provenance) = agent.content else {
            Issue.record("expected a file body, got \(agent.content)")
            return
        }
        #expect(fb.kind == .image && fb.mode == .image && provenance == .agent(w.eng1.id))
        #expect(fb.effectiveMode(for: provenance) == .quickLook)
        #expect(fb.url.path.hasPrefix(ctx.tempRoot.path))
        #expect(fb.root.path.hasPrefix(ctx.tempRoot.path))
        #expect(FileManager.default.fileExists(atPath: fb.url.path))
        let owner = try await RefBodies.body(for: try w.resolve("F-2"), store: w.store, companyId: w.company.id, context: ctx)
        if case .file(let fb2, let p2) = owner.content { #expect(fb2.effectiveMode(for: p2) == .image) } else { Issue.record("not a file") }
        // A text file renders as code with its lines highlighted.
        let code = try await RefBodies.body(for: try w.resolve("Sources/App.swift"), store: w.store, companyId: w.company.id, context: ctx)
        guard case .code(let lines, let first, _, let hidden) = code.content else {
            Issue.record("expected code, got \(code.content)")
            return
        }
        #expect(lines.count == 3 && first == 1 && !hidden)
        #expect(lines[0].first?.text == "let" && lines[0].first?.kind == .keyword)
        #expect(code.header.chips.isEmpty)
        #expect(code.header.actions.contains(.copyRef) && code.header.actions.contains(.saveAs) && !code.header.actions.contains(.openInChat))
    }

    @Test func tabOpenWritesRefRead() async throws {
        let w = try RefWorld()
        let app = await w.app()
        #expect(try w.store.refReads(companyId: w.company.id, canonical: "src/a.ts", limit: 10).isEmpty)
        await app.openRef(try w.ref("src/a.ts"), origin: .owner)
        #expect(app.previewNav.opened?.ref.id == "src/a.ts")
        #expect(app.selectedPreviewTab == PreviewTabID.ref)
        try await eventually { try w.store.refReads(companyId: w.company.id, canonical: "src/a.ts", limit: 10).contains { $0.via == "tab" } }
        let reads = try w.store.refReads(companyId: w.company.id, canonical: "src/a.ts", limit: 10)
        #expect(reads.first?.readerKind == "owner")
        try await eventually { app.openedBody != nil }
        if case .code(let lines, _, _, _)? = app.openedBody?.content { #expect(lines.count == 2) } else { Issue.record("not code: \(String(describing: app.openedBody))") }
        // The OPENED tab shows the ref body.
        if case .ref = app.previewBody(forTab: PreviewTabID.ref) {} else { Issue.record("no ref body for the OPENED tab") }
        // A tab the navigation does not know still shows the product.
        if case .ref = app.previewBody(forTab: nil) { Issue.record("the default tab is not the OPENED one") }
    }

    @Test func unverifiedAnswerLabelled() async throws {
        let w = try RefWorld()
        let refs = [try w.ref("ENG-1"), try w.ref("src/a.ts")]
        var m = Message(id: "m1", companyId: w.company.id, channelId: "ch", senderId: w.eng1.id,
                        text: "The checkout totals are wrong on mobile [1]. Nobody looked at the tax line yet.", createdAt: w.now)
        m.kind = .showAnswer
        m.answerVerified = false
        let body = RefBodies.answerBody(message: m, refs: refs, by: "@eng-1", knownValues: [])
        #expect(body.header.chips.contains(RefChip(text: "UNVERIFIED", tone: .warn)))
        guard case .answer(let note, let claims, let shownRefs, _, let verified, let by, _) = body.content else {
            Issue.record("expected an answer body, got \(body.content)")
            return
        }
        #expect(!verified && by == "@eng-1" && shownRefs == refs)
        #expect(note.contains("checkout totals"))
        #expect(claims.contains { $0.cites == [1] && $0.text.contains("checkout totals") })
        #expect(claims.contains { $0.cites.isEmpty && $0.text.contains("tax line") })

        m.text = "The checkout totals are wrong on mobile [1]. The tax line is computed in the shared helper [2]."
        m.answerVerified = true
        let good = RefBodies.answerBody(message: m, refs: refs, by: "@eng-1", knownValues: [])
        #expect(!good.header.chips.contains { $0.text == "UNVERIFIED" })
        if case .answer(_, let claims, _, _, let verified, _, _) = good.content {
            #expect(verified && claims.count == 2 && claims.allSatisfy { !$0.cites.isEmpty })
        } else { Issue.record("not an answer") }

        // An answer from the concierge's thread is labelled as the concierge's, never as engine text.
        m.senderId = ConciergeCaps.agentId
        let concierge = RefBodies.answerBody(message: m, refs: refs, by: "Brahma", knownValues: [])
        #expect(concierge.header.subtitle.contains("Brahma (concierge)"))
        // A note holding a stored value is withheld as a whole.
        let secret = "sk_" + "live_" + String(repeating: "z", count: 24)
        m.text = "The key is \(secret) [1]."
        let gated = RefBodies.answerBody(message: m, refs: refs, by: "@eng-1", knownValues: [("STRIPE", secret)])
        if case .answer(let note, _, _, _, _, _, _) = gated.content { #expect(!note.contains(secret)) } else { Issue.record("not an answer") }
    }

    /// Controller Ruling C6-1: workspace, worktree and commit content is agent-made (whoever committed it), so its bytes decode
    /// only on the out-of-process path: a PNG is Quick Look's, a PDF is the sandboxed helper's (refused when there is none), and
    /// the resolver says so in the provenance itself (never patched at render time).
    @Test func agentWorkspaceContentDecodesOutOfProcess() async throws {
        let w = try RefWorld()
        try FileManager.default.createDirectory(at: w.workspace.appending(path: "img"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: w.workspace.appending(path: "docs"), withIntermediateDirectories: true)
        try TinyPNG.make().write(to: w.workspace.appending(path: "img/agent.png"))
        try Data("%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n".utf8)
            .write(to: w.workspace.appending(path: "docs/agent.pdf"))
        try RefWorld.git(["add", "-A"], in: w.workspace)
        try RefWorld.git(["commit", "-q", "-m", "agent assets"], in: w.workspace)
        let sha = try w.head()
        let companyId = w.company.id
        try w.write { db in try db.execute(sql: "UPDATE company SET mainCommit = ? WHERE id = ?", arguments: [sha, companyId]) }
        let ctx = try w.renderContext()

        // Committed files: agent-made, whatever the resolver knows about the author.
        let png = try w.resolve("img/agent.png")
        #expect(png.provenance == .agent("workspace"))
        let pngBody = try await RefBodies.body(for: png, store: w.store, companyId: w.company.id, context: ctx)
        guard case .file(let fb, let p) = pngBody.content else {
            Issue.record("expected a file body, got \(pngBody.content)")
            return
        }
        #expect(p == .agent("workspace") && fb.mode == .image && fb.effectiveMode(for: p) == .quickLook)
        let pdf = try w.resolve("docs/agent.pdf")
        #expect(pdf.provenance == .agent("workspace"))
        let pdfBody = try await RefBodies.body(for: pdf, store: w.store, companyId: w.company.id, context: ctx)
        switch pdfBody.content {
        case .file(let fb, let p):
            // With a helper it would be Quick Look's; in-process never.
            #expect(fb.effectiveMode(for: p) == .quickLook && p != .owner && p != .engine)
        case .unavailable:
            break  // no sandboxed PDF helper in tests: refused, fail closed
        default:
            Issue.record("a PDF rendered as \(pdfBody.content)")
        }
        // Even an owner-authored pinned file (`@<sha>`) is workspace content.
        #expect(try w.resolve("img/agent.png@\(sha)").provenance == .agent("workspace"))

        // A live worktree file: the lease holder's.
        let ws = GitWorkspace(root: w.workspace)
        let wt = try ws.addWorktree(key: w.item.key)
        try FileManager.default.createDirectory(at: wt.appending(path: "img"), withIntermediateDirectories: true)
        try TinyPNG.make().write(to: wt.appending(path: "img/wt.png"))
        let (cId, itemId, eng3Id, now) = (w.company.id, w.item.id, w.eng3.id, w.now)
        try w.write { db in
            try WorkLease(itemId: itemId, companyId: cId, agentId: eng3Id, acquiredAt: now, expiresActive: 1_000_000_000).insert(db)
        }
        let live = try w.resolve("\(w.item.key):img/wt.png@worktree")
        #expect(live.visibility == .full && live.provenance == .agent(w.eng3.id))
        let liveBody = try await RefBodies.body(for: live, store: w.store, companyId: w.company.id, context: ctx)
        if case .file(let fb, let p) = liveBody.content { #expect(fb.effectiveMode(for: p) == .quickLook && p == .agent(w.eng3.id)) }
        else { Issue.record("expected a file body, got \(liveBody.content)") }

        // Diffs and commits: agent-made too (the holder's for a live diff, the workspace's for commits).
        #expect(try w.resolve("commit:\(sha)").provenance == .agent("workspace"))
        #expect(try w.resolve("\(w.item.key):diff@worktree").provenance == .agent(w.eng3.id))
        // A resource the owner dropped keeps the owner's provenance (recorded by the engine).
        try w.seedResource(number: 4, name: "mine.png", bytes: TinyPNG.make(), provenance: "owner")
        #expect(try w.resolve("F-4").provenance == .owner)
    }

    /// Owner-only paths have no agent tool (controller note from C2b): `purge` and `viewOriginal` are reachable only from the app.
    @Test func ownerOnlyActionsHaveNoTool() {
        let tools = Set(CompanyToolNames.all)
        for name in ["purge", "view_original", "viewOriginal", "purge_ref", "export", "export_ref"] { #expect(!tools.contains(name), "\(name)") }
    }
}
