import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Controller Ruling 48 (C3b fix round 2): inside a turn, `brahma mcp` never runs the archive or PDF helpers. When the gate
/// needs one, the tool queues a `gateRequest` naming only the ref (no bytes, no path the tool chose), authenticated by the
/// turn's live credential; the engine resolves the ref for the agent itself, reads the bytes, runs the sandboxed helpers
/// outside the turn's sandbox and answers only the verdict and the gated bytes (or the rendered text). No engine answer in
/// time refuses (fail closed).
@Suite(.scratch) struct EngineGateTests {
    /// An archive reader that records every call (where the helper would run) and answers as the stubs do: members from a
    /// fixed table, PDFs through `UnverifiedPDFReader`.
    final class Recording: ArchiveReader, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let members: [String: Data]
        let pdf: UnverifiedPDFReader

        init(members: [String: Data] = [:], pdf: UnverifiedPDFReader = UnverifiedPDFReader(parts: [PDFPart(kind: .pageText, data: Data("page".utf8))])) {
            self.members = members; self.pdf = pdf
        }

        var calls: Int { lock.withLock { count } }
        private func note() { lock.withLock { count += 1 } }

        func members(of data: Data, wanted: @Sendable (String) -> Bool, limits: ArchiveLimits) throws -> [(name: String, data: Data)] {
            note()
            let entries = try ZipInventory.entries(of: data)
            return entries.filter { wanted($0.name) }.compactMap { e in members[e.name].map { (e.name, $0) } }
        }

        func pdfParts(of data: Data, maxBytes: Int, timeout: Duration) throws -> [PDFPart] {
            note()
            return try pdf.pdfParts(of: data, maxBytes: maxBytes, timeout: timeout)
        }

        func flattenPDF(of data: Data, maxBytes: Int, timeout: Duration) throws -> Data {
            note()
            return try pdf.flattenPDF(of: data, maxBytes: maxBytes, timeout: timeout)
        }
    }

    /// The engine side, on its own thread until stopped: what the orchestrator's tick runs.
    final class Engine: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private let done = DispatchSemaphore(value: 0)

        init(store: Store, paths: BrahmaPaths, archives: any ArchiveReader) {
            Thread.detachNewThread { [self] in   // scope-escape: the engine's gate pass; it makes no scratch dirs
                while lock.withLock({ running }) {
                    _ = try? store.serveGateRequests(archives: { _ in archives }, knownValues: { _ in SecretGateTests.known }, paths: paths,
                                                     now: Store.now())
                    usleep(20_000)
                }
                done.signal()
            }
        }

        /// Idempotent: a second stop returns at once.
        func stop() {
            let wasRunning = lock.withLock { () -> Bool in let r = running; running = false; return r }
            if wasRunning { done.wait() }
        }
    }

    struct W {
        let cf: CollabFixture
        let turnId: String
        var store: Store { cf.store }
        var fx: RefFixture { cf.fx }

        init() throws {
            cf = try CollabFixture()
            _ = try cf.store.createChannel(companyId: cf.c.id, name: "team", members: [cf.fx.cto.id, cf.fx.eng1.id, cf.fx.qa2.id])
            if try cf.store.agent(id: cf.fx.eng1.id)?.state != .ready { _ = try cf.store.transition(agentId: cf.fx.eng1.id, to: .ready) }
            let (_, turn) = try #require(try cf.store.beginTurn(agentId: cf.fx.eng1.id, now: Store.now()))
            _ = try cf.store.issueTurnCredential(turnId: turn.id)
            turnId = turn.id
        }

        /// eng-1's tools as `brahma mcp` builds them for a turn: the engine gate, no helper of its own.
        func tools(timeout: Duration = .seconds(30)) -> CompanyTools {
            CompanyTools(store: store, companyId: cf.c.id, agentId: fx.eng1.id, quotaTurnId: turnId, paths: cf.paths,
                         archives: EngineGateArchives(broker: QueuedRefGate(store: store, turnId: turnId, timeout: timeout)))
        }

        func zip(_ members: [String: String]) throws -> Data {
            var z = ZipBuilder()
            for (name, text) in members.sorted(by: { $0.key < $1.key }) { z.add(name, text) }
            let url = try tempDir().appending(path: "a.zip")
            try z.write(to: url)
            return try Data(contentsOf: url)
        }

        func refusal(_ body: () throws -> Any) -> String? {
            do { _ = try body(); return nil } catch let e as ToolError { return e.message } catch { return "\(error)" }
        }

        func requests() throws -> Int {
            try store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM gateRequest") ?? 0 }
        }
    }

    @Test func sandboxedTurnSharesZipAndPDFEngineSide() throws {
        let w = try W()
        let clean = try w.zip(["notes.txt": "hello"])
        let leaky = try w.zip(["env.txt": "STRIPE=\(SecretGateTests.value)"])
        try w.cf.addResource(60, name: "clean.zip", ext: "zip", bytes: clean)
        try w.cf.addResource(61, name: "leaky.zip", ext: "zip", bytes: leaky)
        let pdf = Data("%PDF-1.4 an anomalous pdf\n%%EOF\n".utf8)
        try w.cf.addResource(62, name: "plan.pdf", ext: "pdf", bytes: pdf)
        let documentXML = "<w:document><w:body><w:p><w:r><w:t>Hello docx</w:t></w:r></w:p></w:body></w:document>"
        let docx = try w.zip(["word/document.xml": documentXML])
        let engineReader = Recording(members: ["notes.txt": Data("hello".utf8), "env.txt": Data("STRIPE=\(SecretGateTests.value)".utf8),
                                               "word/document.xml": Data(documentXML.utf8)])
        let engine = Engine(store: w.store, paths: w.cf.paths, archives: engineReader)
        defer { engine.stop() }
        let tools = w.tools()
        // The clean zip is gated (its members read by the engine) and shared.
        #expect(try tools.call(name: "share", arguments: ["refs": .array([.string("F-60")]), "to": .string("@qa-2")]) == "Shared F-60 with @qa-2.")
        #expect(engineReader.calls >= 1)
        // A stored value inside a member: refused, with the engine's gate text.
        let leaked = try #require(w.refusal { try tools.call(name: "share", arguments: ["refs": .array([.string("F-61")]), "to": .string("@qa-2")]) })
        #expect(leaked.contains("contains a stored secret"), "\(leaked)")
        #expect(!leaked.contains(SecretGateTests.value))
        // The PDF: its structure couldn't be verified by the engine's helper, so it is refused.
        let unverified = try #require(w.refusal { try tools.call(name: "share", arguments: ["refs": .array([.string("F-62")]), "to": .string("@qa-2")]) })
        #expect(unverified.hasPrefix("this PDF's structure couldn't be verified"), "\(unverified)")
        // Vouched, it is opened as the engine's flattened copy (bytes the engine read and gated), and rendered by the engine.
        _ = try w.store.vouchFile(companyId: w.cf.c.id, canonical: "F-62", sha256: SHA256.hex(pdf), now: w.cf.now)
        let copied = try tools.call(name: "open_ref", arguments: ["ref": .string("F-62"), "copy": .bool(true)])
        #expect(copied.hasPrefix("Copied F-62 to .brahma/labs/eng-1/in/F-62-1.pdf"), "\(copied)")
        let bytes = try Data(contentsOf: w.cf.workspace.appending(path: ".brahma/labs/eng-1/in/F-62-1.pdf"))
        #expect(bytes.starts(with: UnverifiedPDFReader.copyMark) && bytes != pdf)
        let shown = try tools.call(name: "open_ref", arguments: ["ref": .string("F-62")])
        #expect(shown.contains("[resource F-62") && shown.contains("    | pdf · "), "\(shown)")
        // A docx: gated and its text extracted by the engine (the members the engine's reader read).
        try w.cf.addResource(63, name: "spec.docx", ext: "docx", bytes: docx)
        let before = engineReader.calls
        let text = try tools.call(name: "open_ref", arguments: ["ref": .string("F-63")])
        #expect(text.contains("    | Hello docx"), "\(text)")
        #expect(engineReader.calls > before)
        // Every request is answered and gone; none named bytes or a path (only the ref).
        #expect(try w.requests() == 0)
    }

    @Test func requestsNameOnlyTheRefAndNeedALiveCredential() throws {
        let w = try W()
        try w.cf.addResource(60, name: "clean.zip", ext: "zip", bytes: try w.zip(["notes.txt": "hello"]))
        let gate = QueuedRefGate(store: w.store, turnId: w.turnId, timeout: .seconds(30))
        let engineReader = Recording(members: ["notes.txt": Data("hello".utf8)])
        // What the tool writes: the ref (as JSON), the purpose, the turn and the agent; no bytes.
        let clean = try w.zip(["notes.txt": "hello"])
        let id = try gate.enqueue(companyId: w.cf.c.id, agentId: w.fx.eng1.id, ref: try w.fx.ref("F-60"), purpose: .check,
                                  expected: (clean.count, SHA256.hex(clean)))
        let row = try #require(try w.store.writer.read { db in try Row.fetchOne(db, sql: "SELECT * FROM gateRequest WHERE id = ?", arguments: [id]) })
        #expect(row["turnId"] == w.turnId && row["status"] == "pending" && (row["result"] as Data?) == nil)
        #expect(row["expectedSize"] == clean.count && row["expectedSha256"] == SHA256.hex(clean))
        #expect((row["ref"] as String).contains("\"kind\":\"resource\""))
        // The turn ends: the engine answers no request of it.
        try w.store.writer.write { db in
            try db.execute(sql: "UPDATE turn SET outcome = 'succeeded', endedAt = ? WHERE id = ?", arguments: [Date(), w.turnId])
        }
        _ = try w.store.serveGateRequests(archives: { _ in engineReader }, knownValues: { _ in [] }, paths: w.cf.paths, now: Store.now())
        let after = try #require(try w.store.writer.read { db in try Row.fetchOne(db, sql: "SELECT * FROM gateRequest WHERE id = ?", arguments: [id]) })
        #expect(after["status"] == "refused" && engineReader.calls == 0)
        // N2-4: a live turn of qa-2 asks about a ref qa-2 can't read in full: refused by the engine's own resolution and read
        // check (the credential is live), with nothing read and nothing returned.
        if try w.store.agent(id: w.fx.qa2.id)?.state != .ready { _ = try w.store.transition(agentId: w.fx.qa2.id, to: .ready) }
        let (_, qaTurn) = try #require(try w.store.beginTurn(agentId: w.fx.qa2.id, now: Store.now()))
        _ = try w.store.issueTurnCredential(turnId: qaTurn.id)
        let qaGate = QueuedRefGate(store: w.store, turnId: qaTurn.id, timeout: .seconds(30))
        let lab = try qaGate.enqueue(companyId: w.cf.c.id, agentId: w.fx.qa2.id, ref: try w.fx.ref(".brahma/labs/eng-1/mine.txt"), purpose: .check,
                                     expected: (8, SHA256.hex(Data("eng lab\n".utf8))))
        #expect(try w.store.turnCredentialIsLive(turnId: qaTurn.id, companyId: w.cf.c.id, agentId: w.fx.qa2.id))
        _ = try w.store.serveGateRequests(archives: { _ in engineReader }, knownValues: { _ in [] }, paths: w.cf.paths, now: Store.now())
        let refused = try #require(try w.store.writer.read { db in try Row.fetchOne(db, sql: "SELECT * FROM gateRequest WHERE id = ?", arguments: [lab]) })
        #expect(refused["status"] == "refused" && (refused["result"] as Data?) == nil)
        #expect(refused["message"] == Store.refUnavailable && engineReader.calls == 0)
    }

    @Test func noEngineAnswerRefuses() throws {
        let w = try W()
        try w.cf.addResource(60, name: "clean.zip", ext: "zip", bytes: try w.zip(["notes.txt": "hello"]))
        // No engine running: the tool waits its deadline, then refuses; the request is withdrawn.
        let refused = w.refusal { try w.tools(timeout: .milliseconds(300)).call(name: "share", arguments: [
            "refs": .array([.string("F-60")]), "to": .string("@qa-2"),
        ]) }
        #expect(refused == "that ref couldn't be checked for secrets just now (the engine didn't answer); try again")
        #expect(try w.requests() == 0)
        let shares = try w.store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE kind = 'share'") ?? 0 }
        #expect(shares == 0)
        // Plain text never needs the engine.
        #expect(try w.tools(timeout: .milliseconds(300)).call(name: "share", arguments: [
            "refs": .array([.string("src/a.ts")]), "to": .string("@qa-2"),
        ]).hasPrefix("Shared src/a.ts"))
    }

    /// Ruling 52: the engine gates exactly the bytes its caller acts on. A secret past the shown-read limit (2 MB) of a file
    /// the caller reads whole is caught; a request whose bytes don't match what the engine reads is refused.
    @Test func engineGatesTheWholeBytesAskedAbout() throws {
        let w = try W()
        let padding = String(repeating: "a", count: SafeGit.maxTextBytes + 1024)
        let member = padding + "\nSTRIPE=\(SecretGateTests.value)\n"
        let big = try w.zip(["big.txt": member])
        #expect(big.count > SafeGit.maxTextBytes)
        try w.cf.addResource(64, name: "big.zip", ext: "zip", bytes: big)
        let engineReader = Recording(members: ["big.txt": Data(member.utf8)])
        let engine = Engine(store: w.store, paths: w.cf.paths, archives: engineReader)
        defer { engine.stop() }
        let refused = try #require(w.refusal { try w.tools().call(name: "share", arguments: ["refs": .array([.string("F-64")]), "to": .string("@qa-2")]) })
        #expect(refused.contains("contains a stored secret"), "\(refused)")
        // A request naming other bytes than the engine reads: refused, never a verdict.
        let gate = QueuedRefGate(store: w.store, turnId: w.turnId, timeout: .seconds(30))
        let wrong = Data("not the file".utf8)
        let message = w.refusal {
            try gate.gate(companyId: w.cf.c.id, agentId: w.fx.eng1.id, ref: try w.fx.ref("F-64"), purpose: .check,
                          expected: (wrong.count, SHA256.hex(wrong)))
        }
        #expect(message?.contains("changed while it was being checked") == true, "\(message ?? "")")
    }

    /// Final wave B1 item 11: the engine's gate broker accepts the concierge's live `conciergeRun` credential like a live turn
    /// credential, so the concierge can open (and cite) a PDF or an Office file; the engine resolves the ref as `.concierge`.
    /// A request under an ended run, or naming the concierge without a live run of that request, is refused.
    @Test func conciergeRunCredentialIsAcceptedByTheEngineGate() throws {
        let w = try W()
        let pdf = Data("%PDF-1.4 an anomalous pdf\n%%EOF\n".utf8)
        try w.cf.addResource(62, name: "plan.pdf", ext: "pdf", bytes: pdf)
        let documentXML = "<w:document><w:body><w:p><w:r><w:t>Hello docx</w:t></w:r></w:p></w:body></w:document>"
        try w.cf.addResource(63, name: "spec.docx", ext: "docx", bytes: try w.zip(["word/document.xml": documentXML]))
        let engineReader = Recording(members: ["word/document.xml": Data(documentXML.utf8)])
        let engine = Engine(store: w.store, paths: w.cf.paths, archives: engineReader)
        defer { engine.stop() }
        // The PDF's structure was refused once (a turn's share), and the owner vouched for those bytes.
        _ = w.refusal { try w.tools().call(name: "share", arguments: ["refs": .array([.string("F-62")]), "to": .string("@qa-2")]) }
        _ = try w.store.vouchFile(companyId: w.cf.c.id, canonical: "F-62", sha256: SHA256.hex(pdf), now: w.cf.now)
        let r = try w.store.createShowRequest(companyId: w.cf.c.id, kind: .show, query: "the plan", attachedRef: nil,
                                              routed: ConciergeTests.routed, candidates: [], now: w.cf.now, owner: .test)
        _ = try #require(try w.store.beginConciergeRun(r, now: w.cf.now))
        let tools = CompanyTools(store: w.store, companyId: w.cf.c.id, agentId: ConciergeCaps.agentId, paths: w.cf.paths, vault: MemoryVault(),
                                 archives: EngineGateArchives(broker: QueuedRefGate(store: w.store, conciergeRequestId: r.id, timeout: .seconds(30))),
                                 conciergeRequestId: r.id)
        let shown = ConciergeTests.call(tools, "open_ref", ["ref": .string("F-62")])
        #expect(shown.contains("[resource F-62") && shown.contains("    | pdf · "), "\(shown)")
        let text = ConciergeTests.call(tools, "open_ref", ["ref": .string("F-63")])
        #expect(text.contains("    | Hello docx"), "\(text)")
        #expect(engineReader.calls >= 1)
        #expect(try w.requests() == 0)
        // The run ends: the engine answers no request under it.
        let gate = QueuedRefGate(store: w.store, conciergeRequestId: r.id, timeout: .seconds(30))
        engine.stop()
        w.store.endConciergeRun(requestId: r.id, now: Store.now())
        let ended = try gate.enqueue(companyId: w.cf.c.id, agentId: ConciergeCaps.agentId, ref: try w.fx.ref("F-62"), purpose: .render,
                                     expected: (pdf.count, SHA256.hex(pdf)))
        // A turn's id under the concierge's name is not a concierge credential.
        let forged = try QueuedRefGate(store: w.store, turnId: w.turnId).enqueue(companyId: w.cf.c.id, agentId: ConciergeCaps.agentId,
                                                                                 ref: try w.fx.ref("F-62"), purpose: .render,
                                                                                 expected: (pdf.count, SHA256.hex(pdf)))
        let before = engineReader.calls
        _ = try w.store.serveGateRequests(archives: { _ in engineReader }, knownValues: { _ in [] }, paths: w.cf.paths, now: Store.now())
        for id in [ended, forged] {
            let row = try #require(try w.store.writer.read { db in try Row.fetchOne(db, sql: "SELECT * FROM gateRequest WHERE id = ?", arguments: [id]) })
            #expect(row["status"] == "refused" && (row["result"] as Data?) == nil, "\(id)")
        }
        #expect(engineReader.calls == before)
        // `brahma mcp` wires the concierge's server to the engine gate.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/brahma/MCPCommand.swift"), encoding: .utf8)
        #expect(source.contains("QueuedRefGate(store: store, conciergeRequestId: request)"))
    }

    /// `brahma mcp` passes the engine gate, never a helper of its own.
    @Test func mcpCommandUsesTheEngineGate() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/brahma/MCPCommand.swift"), encoding: .utf8)
        #expect(source.contains("EngineGateArchives(broker: QueuedRefGate("))
        #expect(!source.contains("liveArchives") && !source.contains("SandboxedUnzipReader") && !source.contains("SandboxedPDFReader"))
    }
}
