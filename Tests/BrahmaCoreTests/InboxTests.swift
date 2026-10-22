import Testing
import Foundation
import GRDB
@testable import BrahmaCore

@Suite struct InboxTests {
    private struct W {
        let store: Store, company: Company
        let ceo: Agent, cto: Agent, cpo: Agent, eng: Agent
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        init(name: String = "Acme", catalog: PackCatalog = .builtin, preset: AutonomyPreset = .important) throws {
            let s = try Store.inMemory(catalog: catalog)
            let c = try s.createCompany(name: name, goal: "g", workspacesRoot: try tempDir())
            func hire(_ n: String, _ role: String) throws -> Agent { try s.hire(companyId: c.id, name: n, role: role, model: "sonnet") }
            store = s; company = c
            ceo = try hire("ceo", "ceo"); cto = try hire("cto", "cto"); cpo = try hire("cpo", "cpo"); eng = try hire("eng-1", "engineer")
            try s.setAutonomy(companyId: c.id, preset)
        }

        @discardableResult
        func propose(_ kind: AskKind, by: Agent? = nil, category: String? = nil, risk: AskRisk? = nil, title: String = "Title",
                     payload: AskPayload? = nil, itemId: String? = nil, supersedes: String? = nil, requestId: String? = nil,
                     decisionClass: DecisionClass = .taste) throws -> Ask {
            try store.propose(companyId: company.id, by: .agent((by ?? eng).id), kind: kind, risk: risk, category: category,
                              title: title, summary: "why", payload: payload, itemId: itemId, subjectId: nil, supersedes: supersedes,
                              requestId: requestId, decisionClass: decisionClass, now: now)
        }

        @discardableResult
        func decide(_ ask: Ask, by: Agent, approve: Bool = true, note: String = "ok", category: String? = nil,
                    risk: AskRisk? = nil) throws -> Ask {
            try store.internalDecide(askId: ask.id, by: .agent(by.id), approve: approve, note: note, category: category, risk: risk, now: now)
        }

        func fresh(_ a: Ask) throws -> Ask { try #require(try store.ask(id: a.id)) }

        func dms(_ a: String, _ b: String = "system") throws -> [String] {
            guard let ch = try store.channel(companyId: company.id, name: "dm:" + [a, b].sorted().joined(separator: ":")) else { return [] }
            return try store.messages(channelId: ch.id, limit: 100).map(\.text)
        }

        func activity() throws -> [ActivityEvent] { try store.events(afterId: 0, companyId: company.id) }

        func tools(_ a: Agent) -> CompanyTools { CompanyTools(store: store, companyId: company.id, agentId: a.id) }

        func writeDoc(_ relative: String, _ text: String) throws -> String {
            let url = URL(fileURLWithPath: company.workspacePath).appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return relative
        }
    }

    // MARK: Kinds, table, routing

    @Test func askKindsAndReservedList() {
        #expect(AskKind.reserved.map(\.rawValue) == ["request", "grant", "deploy", "humanTask", "outbox", "spend", "staffing", "stage", "role"])
        for k in AskKind.reserved { #expect(AskKind(rawValue: k.rawValue) == k); #expect(k.isReservedKind) }
        #expect(AskKind.gates.map(\.rawValue) == ["prd", "architecture", "sprintPlan", "release"])
        #expect(AskKind.prd.isGate && !AskKind.other.isGate && !AskKind.boost.isReservedKind)
        #expect(AskKind.info.isDecision == false && AskKind.engineAlert.isDecision == false && AskKind.boost.isDecision)
        #expect(AskKind.prd.title == "Idea / PRD"); #expect(AskKind.other.title == "Decision"); #expect(AskKind.info.title == "Question")
        #expect(AskKind.deploy.title == "Deploy"); #expect(AskKind.role.title == "Role")
        #expect(ReservedMatters.categories.count == 14)
    }

    @Test func routesToPackApprover() throws {
        let w = try W()
        let prd = try w.propose(.prd), arch = try w.propose(.architecture), plan = try w.propose(.sprintPlan)
        let other = try w.propose(.other, category: "general")
        #expect([prd.ref, arch.ref, plan.ref, other.ref] == ["A-1", "A-2", "A-3", "A-4"])
        #expect(prd.internalApproverId == w.ceo.id); #expect(arch.internalApproverId == w.cto.id)
        #expect(plan.internalApproverId == w.cpo.id); #expect(other.internalApproverId == w.ceo.id)
        #expect([prd, arch, plan, other].allSatisfy { $0.status == .pendingInternal })
        // The requester is skipped; a paused or killed approver is skipped too.
        #expect(try w.propose(.prd, by: w.ceo).internalApproverId == w.cpo.id)
        try w.store.setPaused(agentId: w.cto.id, true)
        #expect(try w.propose(.architecture).internalApproverId == w.ceo.id)
        try w.store.setPaused(agentId: w.cto.id, false)
        _ = try w.store.transition(agentId: w.cto.id, to: .killed)
        #expect(try w.propose(.architecture).internalApproverId == w.ceo.id)
        // The approver is told.
        #expect(try w.dms("ceo").contains { $0.contains("A-1") })
    }

    @Test func presetTable() {
        let pack = SoftwarePack.pack
        func role(_ k: AskKind, _ r: AskRisk, _ p: AutonomyPreset, cat: String? = nil, cls: DecisionClass = .taste) -> OwnerRole {
            AutonomyPolicy.ownerRole(kind: k, risk: r, category: cat, preset: p, pack: pack, decisionClass: cls)
        }
        for r in AskRisk.allCases {
            for k in [AskKind.prd, .architecture, .sprintPlan, .release, .other, .boost] {
                #expect(role(k, r, .everything) == .approve, "\(k) \(r)")
                #expect(role(k, r, .auto) == .fyi, "\(k) \(r)")
            }
            for k in [AskKind.prd, .architecture, .release] { #expect(role(k, r, .important) == .approve) }
            #expect(role(.sprintPlan, r, .important) == .fyi)
            #expect(role(.other, r, .important) == (r == .high ? .approve : .fyi))
            #expect(role(.boost, r, .important) == (r == .high ? .approve : .fyi))
            for p in AutonomyPreset.allCases {
                #expect(role(.info, r, p) == .approve); #expect(role(.engineAlert, r, p) == .approve)
                for k in AskKind.reserved { #expect(role(k, r, p) == .approve) }
                #expect(role(.other, r, p, cat: "pricing") == .approve)
                #expect(role(.sprintPlan, r, p, cls: .goalChanging) == .approve)
            }
        }
        #expect(AskRisk.low < AskRisk.medium && AskRisk.medium < AskRisk.high)
    }

    @Test func reservedCategoryNeverAutoApproved() throws {
        var pack = SoftwarePack.pack
        pack.reservedCategories = ["fisheries"]
        let w = try W(catalog: PackCatalog(packs: [pack]), preset: .auto)
        for cat in ["pricing", "money", "fisheries"] {
            let a = try w.propose(.other, category: cat, risk: .low)
            let d = try w.decide(a, by: w.ceo)
            #expect(d.status == .pendingOwner, "\(cat)"); #expect(!d.fyi)
        }
        // An ordinary category under auto is policy-approved.
        let ok = try w.decide(try w.propose(.other, category: "tooling"), by: w.ceo)
        #expect(ok.status == .approved); #expect(ok.fyi); #expect(ok.decidedBy == "policy:auto")
        #expect(ReservedMatters.isReserved("Pricing ", pack: pack)); #expect(ReservedMatters.isReserved("fisheries", pack: pack))
        #expect(!ReservedMatters.isReserved("fisheries", pack: SoftwarePack.pack)); #expect(!ReservedMatters.isReserved(nil, pack: pack))
    }

    @Test func otherNeedsCategory() throws {
        let w = try W()
        let list = ReservedMatters.allowed(extra: []).joined(separator: ", ")
        #expect(throws: WorkError.invalid("other asks must name a category: \(list)")) { try w.propose(.other) }
        #expect(throws: WorkError.invalid("other asks must name a category: \(list)")) { try w.propose(.other, category: "vibes") }
        #expect(try w.propose(.other, category: "Process").category == "process")
        // Gate kinds carry no category.
        #expect(try w.propose(.prd, category: "pricing").category == nil)
    }

    @Test func sprintPlanIsFYIUnderImportant() throws {
        let w = try W()
        let plan = try w.propose(.sprintPlan, title: "Sprint 1")
        let d = try w.decide(plan, by: w.cpo)
        #expect(d.status == .approved); #expect(d.fyi); #expect(d.decidedBy == "policy:important")
        #expect(d.internalDecidedAt == w.now)
        #expect(try w.activity().contains { $0.kind == .approval && $0.text == "FYI: A-1 Sprint plan approved by @cpo under important: Sprint 1" })
        #expect(try w.dms("eng-1").contains("A-1 approved by policy (important): ok"))
        #expect(try w.store.hasApproved(companyId: w.company.id, kind: .sprintPlan))
        // The owner can acknowledge an FYI.
        let ack = try w.store.acknowledge(askId: plan.id, now: w.now)
        #expect(ack.acknowledgedAt == w.now)
        #expect(throws: WorkError.conflict("A-1 is already acknowledged")) { try w.store.acknowledge(askId: plan.id, now: w.now) }
        // An architecture ask under important goes to the owner.
        let arch = try w.decide(try w.propose(.architecture), by: w.cto)
        #expect(arch.status == .pendingOwner); #expect(!arch.fyi)
        #expect(try w.activity().contains {
            $0.kind == .approval && $0.text == "Owner approval needed: A-2 Architecture: Title (brahma approve acme A-2)"
        })
        #expect(try w.dms("owner").contains { $0.contains("A-2") })
        // Rejecting never reaches the owner.
        let rej = try w.decide(try w.propose(.prd), by: w.ceo, approve: false, note: "not now")
        #expect(rej.status == .rejected); #expect(rej.internalNote == "not now")
        #expect(try w.dms("eng-1").contains("A-3 rejected by @ceo: not now"))
    }

    @Test func requestFromOwnerAndAnswer() throws {
        let w = try W()
        try w.store.advanceActive(companyId: w.company.id, by: 100)
        let q = try w.store.requestFromOwner(companyId: w.company.id, by: .agent(w.eng.id), title: "Which db?", question: "Postgres or SQLite?",
                                             details: "tradeoffs", expiresInHours: 2, now: w.now)
        #expect(q.kind == .info); #expect(q.status == .pendingOwner); #expect(q.payload?.question == "Postgres or SQLite?")
        #expect(q.createdActive == 100); #expect(q.expiresActive == 7300.0)
        #expect(try w.activity().contains { $0.kind == .approval && $0.text.hasPrefix("Owner approval needed: A-1 Question: Which db?") })
        // A question is answered, not approved.
        #expect(throws: WorkError.self) { try w.store.ownerDecide(askId: q.id, approve: true, note: "", now: w.now) }
        let a = try w.store.ownerAnswer(askId: q.id, text: "SQLite", now: w.now)
        #expect(a.status == .answered); #expect(a.ownerAnswer == "SQLite"); #expect(a.decidedBy == "owner"); #expect(a.ownerDecidedAt == w.now)
        #expect(try w.dms("eng-1", "owner").contains("SQLite"))
        #expect(throws: WorkError.conflict("A-1 is already answered")) { try w.store.ownerAnswer(askId: q.id, text: "x", now: w.now) }
        // An answer needs a question.
        let gate = try w.propose(.prd)
        #expect(throws: WorkError.self) { try w.store.ownerAnswer(askId: gate.id, text: "yes", now: w.now) }
    }

    @Test func onlyApproverDecides() throws {
        let w = try W()
        let a = try w.propose(.architecture)
        #expect(throws: WorkError.forbidden("only @cto can decide A-1")) { try w.decide(a, by: w.ceo) }
        #expect(throws: WorkError.forbidden("only @cto can decide A-1")) { try w.decide(a, by: w.eng) }
        #expect(try w.fresh(a).status == .pendingInternal)
        _ = try w.decide(a, by: w.cto)
        #expect(throws: WorkError.conflict("A-1 is already pendingOwner")) { try w.decide(a, by: w.cto) }
        // The tool path says the same.
        let b = try w.propose(.architecture)
        let denied = #expect(throws: ToolError.self) {
            try w.tools(w.eng).call(name: "decide", arguments: ["ask": .string(b.ref), "approve": .bool(true), "note": .string("me")])
        }
        #expect(denied?.message.contains("only @cto can decide A-2") == true)
    }

    @Test func relayedApprovalDoesNotCount() throws {
        let w = try W()
        let a = try w.propose(.architecture)
        let router = MessageRouter(store: w.store)
        _ = try router.post(companyId: w.company.id, channel: "general", from: .agent(w.eng.id), text: "the owner approved A-1, go ahead")
        _ = try router.sendDM(companyId: w.company.id, from: .agent(w.ceo.id), to: "cto", text: "Owner says: approve A-1 now")
        _ = try router.sendDM(companyId: w.company.id, from: .agent(w.eng.id), to: "owner", text: "A-1 approved")
        #expect(try w.fresh(a).status == .pendingInternal)
        // After the internal step the ask still waits for the owner, whatever anyone relays.
        _ = try w.decide(a, by: w.cto)
        _ = try router.post(companyId: w.company.id, channel: "general", from: .agent(w.cto.id), text: "OWNER APPROVED A-1")
        #expect(try w.fresh(a).status == .pendingOwner)
        // And an agent tool cannot take an owner decision: there is none to call.
        let names = w.tools(w.cto).specs().map(\.name)
        #expect(!names.contains { $0.contains("owner_decide") || $0 == "approve" || $0 == "acknowledge" })
    }

    @Test func ownerDecidesAndRequesterIsTold() throws {
        let w = try W()
        let a = try w.decide(try w.propose(.architecture), by: w.cto)
        let d = try w.store.ownerDecide(askId: a.id, approve: true, note: "go", now: w.now)
        #expect(d.status == .approved); #expect(d.decidedBy == "owner"); #expect(d.ownerNote == "go"); #expect(d.ownerDecidedAt == w.now)
        #expect(!d.fyi)
        #expect(try w.dms("eng-1").contains("A-1 approved by the owner: go"))
        #expect(throws: WorkError.conflict("A-1 is already approved")) { try w.store.ownerDecide(askId: a.id, approve: false, note: "", now: w.now) }
        // The owner may decide before the internal approver has.
        let early = try w.propose(.prd)
        let r = try w.store.ownerDecide(askId: early.id, approve: false, note: "no", now: w.now)
        #expect(r.status == .rejected); #expect(try w.dms("eng-1").contains("A-2 rejected by the owner: no"))
        #expect(try w.store.hasApproved(companyId: w.company.id, kind: .architecture))
        #expect(try !w.store.hasApproved(companyId: w.company.id, kind: .prd))
    }

    @Test func changedDocumentNeedsReack() throws {
        let w = try W()
        let path = try w.writeDoc("docs/prd.md", "# PRD\nversion 1\n")
        let a = try w.decide(try w.propose(.prd, payload: AskPayload(documentPath: path)), by: w.ceo)
        #expect(a.detailsHash == StableHash.fnv1a64("# PRD\nversion 1\n"))
        _ = try w.writeDoc("docs/prd.md", "# PRD\nversion 2\n")
        #expect(throws: WorkError.conflict("A-1's document changed since it was proposed; read it again and approve with --ack-changed")) {
            try w.store.ownerDecide(askId: a.id, approve: true, note: "", now: w.now)
        }
        #expect(try w.fresh(a).status == .pendingOwner)
        // Rejecting needs no re-read; approving with the acknowledgement works.
        let d = try w.store.ownerDecide(askId: a.id, approve: true, note: "read it", acknowledgeChange: true, now: w.now)
        #expect(d.status == .approved)
        #expect(try w.store.documentChanged(d) == true)
    }

    @Test func supersedesMarksOldAsk() throws {
        let w = try W()
        let old = try w.store.ownerDecide(askId: try w.propose(.architecture).id, approve: true, note: "v1", now: w.now)
        let rejected = try w.store.ownerDecide(askId: try w.propose(.architecture).id, approve: false, note: "no", now: w.now)
        let new = try w.propose(.architecture, supersedes: old.id)
        #expect(new.supersedesId == old.id)
        #expect(try w.fresh(old).status == .approved)       // only when the new one is approved
        _ = try w.store.ownerDecide(askId: new.id, approve: true, note: "v2", now: w.now)
        #expect(try w.fresh(old).status == .superseded)
        #expect(try w.store.hasApproved(companyId: w.company.id, kind: .architecture))   // the new one counts
        // A rejected ask stays rejected when superseded.
        let again = try w.propose(.architecture, supersedes: rejected.id)
        _ = try w.store.ownerDecide(askId: again.id, approve: true, note: "", now: w.now)
        #expect(try w.fresh(rejected).status == .rejected)
        // Same kind, same company.
        #expect(throws: WorkError.invalid("supersedes must name an ask of the same kind")) { try w.propose(.prd, supersedes: old.id) }
        let globex = try w.store.createCompany(name: "Globex", goal: "g", workspacesRoot: try tempDir())
        let gEng = try w.store.hire(companyId: globex.id, name: "eng-9", role: "engineer", model: "sonnet")
        let foreign = try w.store.propose(companyId: globex.id, by: .agent(gEng.id), kind: .architecture, risk: nil, category: nil,
                                          title: "g", summary: "", payload: nil, itemId: nil, subjectId: nil, supersedes: nil, now: w.now)
        #expect(throws: WorkError.forbidden("not in your company")) {
            try w.store.propose(companyId: w.company.id, by: .agent(w.eng.id), kind: .architecture, risk: nil, category: nil, title: "x",
                                summary: "", payload: nil, itemId: nil, subjectId: nil, supersedes: foreign.id, now: w.now)
        }
        // A superseded ask no longer counts as the gate.
        let only = try W()
        let first = try only.store.ownerDecide(askId: try only.propose(.release).id, approve: true, note: "", now: w.now)
        #expect(try only.store.hasApproved(companyId: only.company.id, kind: .release))
        try only.store.writer.write { db in try db.execute(sql: "UPDATE ask SET status = 'rescinded' WHERE id = ?", arguments: [first.id]) }
        #expect(try !only.store.hasApproved(companyId: only.company.id, kind: .release))
    }

    @Test func noInternalApproverGoesToOwnerEvenInAuto() throws {
        let w = try W(preset: .auto)
        // The CEO proposes `other`: nobody else in the list, so the owner decides, and is told.
        let a = try w.propose(.other, by: w.ceo, category: "tooling", risk: .low)
        #expect(a.status == .pendingOwner); #expect(a.internalApproverId == nil); #expect(!a.fyi)
        #expect(try w.activity().contains { $0.kind == .approval && $0.text.contains("A-1") && $0.text.contains("(brahma approve acme A-1)") })
        #expect(try w.dms("owner").contains { $0.contains("A-1") })
        // Same when the only approver is paused.
        try w.store.setPaused(agentId: w.ceo.id, true)
        #expect(try w.propose(.other, category: "tooling").status == .pendingOwner)
    }

    @Test func crossCompanyAskRefused() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let s = try Store.inMemory()
        let c1 = try s.createCompany(name: "One", goal: "g", workspacesRoot: try tempDir())
        let c2 = try s.createCompany(name: "Two", goal: "g", workspacesRoot: try tempDir())
        let cto1 = try s.hire(companyId: c1.id, name: "cto", role: "cto", model: "sonnet")
        let eng1 = try s.hire(companyId: c1.id, name: "eng-1", role: "engineer", model: "sonnet")
        let cto2 = try s.hire(companyId: c2.id, name: "cto", role: "cto", model: "sonnet")
        let eng2 = try s.hire(companyId: c2.id, name: "eng-2", role: "engineer", model: "sonnet")
        let item2 = try s.createWorkItem(companyId: c2.id, by: .owner, draft: WorkItemDraft(type: .task, title: "t"))
        let one = try s.propose(companyId: c1.id, by: .agent(eng1.id), kind: .architecture, risk: nil, category: nil, title: "t", summary: "",
                                payload: nil, itemId: nil, subjectId: nil, supersedes: nil, now: now)
        #expect(throws: WorkError.forbidden("not in your company")) {
            try s.internalDecide(askId: one.id, by: .agent(cto2.id), approve: true, note: "", now: now)
        }
        #expect(throws: WorkError.forbidden("not in your company")) {
            try s.propose(companyId: c1.id, by: .agent(eng2.id), kind: .architecture, risk: nil, category: nil, title: "t", summary: "",
                          payload: nil, itemId: nil, subjectId: nil, supersedes: nil, now: now)
        }
        #expect(throws: WorkError.forbidden("not in your company")) {
            try s.propose(companyId: c1.id, by: .agent(eng1.id), kind: .other, risk: nil, category: "general", title: "t", summary: "",
                          payload: nil, itemId: item2.id, subjectId: nil, supersedes: nil, now: now)
        }
        // A ref resolves only inside its own company.
        #expect(try s.ask(companyId: c2.id, ref: one.ref) == nil)
        #expect(try s.ask(companyId: c1.id, ref: "a-1")?.id == one.id)
        #expect(try s.ask(companyId: c1.id, ref: "1")?.id == one.id)
        #expect(try s.ask(companyId: c1.id, ref: "A-x") == nil)
        let tool = CompanyTools(store: s, companyId: c2.id, agentId: cto2.id)
        #expect(throws: ToolError.self) { try tool.call(name: "decide", arguments: ["ask": .string(one.ref), "approve": .bool(true), "note": .string("x")]) }
        #expect(try s.ask(id: one.id)?.status == .pendingInternal)
        _ = cto1
    }

    @Test func presetChangeIsNotRetroactive() throws {
        let w = try W(preset: .everything)
        let a = try w.decide(try w.propose(.sprintPlan), by: w.cpo)
        #expect(a.status == .pendingOwner)
        try w.store.setAutonomy(companyId: w.company.id, .auto)
        #expect(try w.fresh(a).status == .pendingOwner)
        #expect(try w.store.company(id: w.company.id)?.autonomy == .auto)
        // New asks follow the new preset.
        let b = try w.decide(try w.propose(.sprintPlan), by: w.cpo)
        #expect(b.status == .approved); #expect(b.fyi); #expect(b.decidedBy == "policy:auto")
        // The owner still decides the old one.
        #expect(try w.store.ownerDecide(askId: a.id, approve: true, note: "", now: w.now).status == .approved)
    }

    @Test func documentPathMustStayInWorkspace() throws {
        let w = try W()
        let outside = try tempDir().appending(path: "secret.md")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        let msg = WorkError.invalid("document_path must be inside the workspace")
        #expect(throws: msg) { try w.propose(.prd, payload: AskPayload(documentPath: "../../../../../../\(outside.path)")) }
        #expect(throws: msg) { try w.propose(.prd, payload: AskPayload(documentPath: outside.path)) }
        #expect(throws: msg) { try w.propose(.prd, payload: AskPayload(documentPath: "../outside.md")) }
        #expect(throws: WorkError.invalid("document_path does not exist")) { try w.propose(.prd, payload: AskPayload(documentPath: "nope.md")) }
        let rel = try w.writeDoc("docs/ok.md", "fine")
        let absolute = URL(fileURLWithPath: w.company.workspacePath).appending(path: rel).path
        #expect(try w.propose(.prd, payload: AskPayload(documentPath: rel)).detailsHash == StableHash.fnv1a64("fine"))
        #expect(try w.propose(.prd, payload: AskPayload(documentPath: absolute)).detailsHash == StableHash.fnv1a64("fine"))
    }

    @Test func documentSymlinkOutsideWorkspaceRefused() throws {
        let w = try W()
        let outside = try tempDir().appending(path: "secret.md")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        let ws = URL(fileURLWithPath: w.company.workspacePath)
        try FileManager.default.createSymbolicLink(at: ws.appending(path: "link.md"), withDestinationURL: outside)
        let dir = try tempDir()
        try "x".write(to: dir.appending(path: "in.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: ws.appending(path: "linkdir"), withDestinationURL: dir)
        let msg = WorkError.invalid("document_path must be inside the workspace")
        #expect(throws: msg) { try w.propose(.prd, payload: AskPayload(documentPath: "link.md")) }
        #expect(throws: msg) { try w.propose(.prd, payload: AskPayload(documentPath: "linkdir/in.md")) }
        // A symlink that stays inside is fine.
        _ = try w.writeDoc("real.md", "inside")
        try FileManager.default.createSymbolicLink(at: ws.appending(path: "alias.md"), withDestinationURL: ws.appending(path: "real.md"))
        #expect(try w.propose(.prd, payload: AskPayload(documentPath: "alias.md")).detailsHash == StableHash.fnv1a64("inside"))
    }

    // MARK: Decision brief

    @Test func duplicateRequestIdReturnsExistingAsk() throws {
        let w = try W()
        let a = try w.propose(.architecture, requestId: "r1")
        let b = try w.propose(.architecture, title: "Changed", requestId: "r1")
        #expect(a.id == b.id); #expect(b.title == "Title")
        #expect(try w.store.asks(companyId: w.company.id).count == 1)
        // Another requester, or another id, is a new ask.
        #expect(try w.propose(.architecture, by: w.ceo, requestId: "r1").id != a.id)
        #expect(try w.propose(.architecture, requestId: "r2").id != a.id)
        #expect(try w.store.asks(companyId: w.company.id).count == 3)
    }

    @Test func briefFieldsAreStoredAndBounded() throws {
        let w = try W()
        let opts = (1...4).map { AskOption(label: "o\($0)", pros: "p", cons: "c", effort: "S", risk: "low") }
        let payload = AskPayload(question: "q", options: opts, recommendation: "o2", stakes: "uptime", reversible: .twoWay, proposal: "switch to X")
        let a = try w.propose(.other, category: "tooling", payload: payload)
        #expect(a.payload == payload); #expect(try w.fresh(a).payload?.options.count == 4)
        #expect(throws: WorkError.self) {
            try w.propose(.other, category: "tooling", payload: AskPayload(options: opts + [AskOption(label: "o5")]))
        }
        #expect(throws: WorkError.self) { try w.propose(.other, category: "tooling", title: String(repeating: "x", count: 500)) }
        #expect(throws: WorkError.self) { try w.propose(.other, category: "tooling", title: "  ") }
    }

    @Test func mechanicalDecisionRecordedOnly() throws {
        let w = try W()
        let item = try w.store.createWorkItem(companyId: w.company.id, by: .owner, draft: WorkItemDraft(type: .task, title: "t"))
        let out = try w.tools(w.eng).call(name: "propose_decision", arguments: [
            "kind": .string("other"), "category": .string("tooling"), "title": .string("Use tabs"), "summary": .string("style"),
            "decision_class": .string("mechanical"), "item": .string(item.key)])
        #expect(out == "Recorded as a mechanical decision; no approval needed.")
        #expect(try w.store.asks(companyId: w.company.id).isEmpty)
        #expect(try w.activity().contains { $0.kind == .approval && $0.text.hasPrefix("Recorded: ") && $0.text.contains("Use tabs") })
        #expect(try w.store.itemEvents(itemId: item.id).contains { $0.text.contains("Recorded: ") && $0.text.contains("Use tabs") })
        // The Store refuses to file one.
        #expect(throws: WorkError.self) { try w.propose(.other, category: "tooling", decisionClass: .mechanical) }
    }

    @Test func goalChangingAlwaysNeedsOwner() throws {
        let w = try W(preset: .auto)
        let a = try w.propose(.other, category: "general", risk: .low, decisionClass: .goalChanging)
        #expect(a.decisionClass == .goalChanging)
        let d = try w.decide(a, by: w.ceo)
        #expect(d.status == .pendingOwner)
        // The same ask as taste is policy-approved.
        #expect(try w.decide(try w.propose(.other, category: "general", risk: .low), by: w.ceo).status == .approved)
    }

    @Test func approverCanRaiseRiskNotLower() throws {
        let w = try W(preset: .important)
        // Low-risk `other` is an FYI; the approver raises its risk to high and it goes to the owner.
        let a = try w.propose(.other, category: "tooling", risk: .low)
        let d = try w.decide(a, by: w.ceo, risk: .high)
        #expect(d.risk == .high); #expect(d.status == .pendingOwner)
        // Lowering is refused.
        let b = try w.propose(.other, category: "tooling", risk: .high)
        #expect(throws: WorkError.invalid("the approver can raise risk, never lower it")) { try w.decide(b, by: w.ceo, risk: .low) }
        #expect(try w.fresh(b).status == .pendingInternal)
        // The approver can move an ask into a reserved category, never out of one.
        let c = try w.propose(.other, category: "tooling", risk: .low)
        let rc = try w.decide(c, by: w.ceo, category: "pricing")
        #expect(rc.category == "pricing"); #expect(rc.status == .pendingOwner)
        let d2 = try w.propose(.other, category: "pricing", risk: .low)
        #expect(throws: WorkError.invalid("the approver can raise the category to a reserved matter, never lower it")) {
            try w.decide(d2, by: w.ceo, category: "tooling")
        }
        let e = try w.propose(.other, category: "tooling", risk: .low)
        #expect(throws: WorkError.invalid("the approver can raise the category to a reserved matter, never lower it")) {
            try w.decide(e, by: w.ceo, category: "process")
        }
        // The tool passes both through.
        let f = try w.propose(.other, category: "tooling", risk: .low)
        _ = try w.tools(w.ceo).call(name: "decide", arguments: ["ask": .string(f.ref), "approve": .bool(true), "note": .string("n"),
                                                               "category": .string("legal"), "risk": .string("high")])
        #expect(try w.fresh(f).category == "legal"); #expect(try w.fresh(f).risk == .high)
    }

    @Test func replanAnswer() throws {
        let w = try W()
        let a = try w.decide(try w.propose(.architecture), by: w.cto)
        let r = try w.store.ownerReplan(askId: a.id, text: "split it into two services", now: w.now)
        #expect(r.status == .rejected); #expect(r.ownerAnswer == "split it into two services"); #expect(r.decidedBy == "owner")
        #expect(try w.dms("eng-1").contains("A-1 needs a new plan: split it into two services"))
        #expect(throws: WorkError.conflict("A-1 is already rejected")) { try w.store.ownerReplan(askId: a.id, text: "x", now: w.now) }
        let q = try w.store.requestFromOwner(companyId: w.company.id, by: .agent(w.eng.id), title: "q", question: "q?", now: w.now)
        #expect(throws: WorkError.self) { try w.store.ownerReplan(askId: q.id, text: "x", now: w.now) }
    }

    @Test func smallCompanyCombinedGate() throws {
        let w = try W()      // four agents
        let prd = try w.propose(.prd, title: "Idea")
        #expect(try !w.store.hasApproved(companyId: w.company.id, kind: .architecture))
        _ = try w.decide(prd, by: w.ceo)
        #expect(try w.activity().contains { $0.kind == .approval && $0.text.contains("Brief & architecture") })
        #expect(try w.store.displayTitle(prd) == "Brief & architecture")
        _ = try w.store.ownerDecide(askId: prd.id, approve: true, note: "", now: w.now)
        #expect(try w.store.hasApproved(companyId: w.company.id, kind: .prd))
        #expect(try w.store.hasApproved(companyId: w.company.id, kind: .architecture))
        // Above eight agents the architecture gate stands alone.
        for i in 1...5 { _ = try w.store.hire(companyId: w.company.id, name: "e-\(i)", role: "engineer", model: "sonnet") }
        #expect(try !w.store.hasApproved(companyId: w.company.id, kind: .architecture))
        #expect(try w.store.displayTitle(prd) == "Idea / PRD")
        // Killed agents do not count toward the eight.
        for i in 1...2 { _ = try w.store.transition(agentId: try #require(try w.store.agent(companyId: w.company.id, name: "e-\(i)")).id, to: .killed) }
        #expect(try w.store.hasApproved(companyId: w.company.id, kind: .architecture))
    }

    // MARK: Tools

    @Test func proposeDecisionAndDecideTools() throws {
        let w = try W()
        let path = try w.writeDoc("docs/arch.md", "arch")
        let out = try w.tools(w.eng).call(name: "propose_decision", arguments: [
            "kind": .string("architecture"), "title": .string("Layers"), "summary": .string("how"), "document_path": .string(path),
            "risk": .string("high"), "recommendation": .string("go"), "stakes": .string("rework"), "reversible": .string("oneWay"),
            "proposal": .string("adopt layers"), "request_id": .string("q1"), "decision_class": .string("taste"),
            "options": .array([.object(["label": .string("A"), "pros": .string("p"), "cons": .string("c"), "effort": .string("S"), "risk": .string("low")])])])
        #expect(out.contains("A-1")); #expect(out.contains("@cto"))
        let a = try #require(try w.store.ask(companyId: w.company.id, ref: "A-1"))
        #expect(a.risk == .high); #expect(a.payload?.reversible == .oneWay); #expect(a.payload?.options.first?.label == "A")
        #expect(a.payload?.proposal == "adopt layers"); #expect(a.requestId == "q1")
        #expect(try w.tools(w.eng).call(name: "propose_decision", arguments: [
            "kind": .string("architecture"), "title": .string("Layers"), "summary": .string("how"), "request_id": .string("q1")]).contains("A-1"))
        #expect(try w.store.asks(companyId: w.company.id).count == 1)
        let done = try w.tools(w.cto).call(name: "decide", arguments: ["ask": .string("A-1"), "approve": .bool(true), "note": .string("fine")])
        #expect(done.contains("A-1")); #expect(done.contains("owner"))
        #expect(try w.fresh(a).status == .pendingOwner)
        // Bad input is a tool error, not a crash.
        #expect(throws: ToolError.self) { try w.tools(w.eng).call(name: "propose_decision", arguments: ["kind": .string("nonsense"), "title": .string("x"), "summary": .string("y")]) }
        #expect(throws: ToolError.self) { try w.tools(w.eng).call(name: "propose_decision", arguments: ["kind": .string("other"), "title": .string("x"), "summary": .string("y")]) }
        // Agents cannot file engine or reserved kinds.
        #expect(throws: ToolError.self) { try w.tools(w.eng).call(name: "propose_decision", arguments: ["kind": .string("engineAlert"), "title": .string("x"), "summary": .string("y")]) }
        let q = try w.tools(w.eng).call(name: "request_from_owner", arguments: ["title": .string("Budget?"), "question": .string("How much?"),
                                                                                "expires_in_hours": .number(1)])
        #expect(q.contains("A-2"))
        #expect(try w.store.ask(companyId: w.company.id, ref: "A-2")?.kind == .info)
        #expect(w.tools(w.eng).specs().map(\.name).contains("propose_decision"))
        #expect(w.tools(w.eng).specs().map(\.name).contains("request_mode"))
    }

    // MARK: Work modes (W6)

    private func modeItem(_ w: W) throws -> WorkItem {
        try w.store.createWorkItem(companyId: w.company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "Hard thing", ownerId: w.eng.id, status: .ready), now: w.now)
    }

    @Test func boostAskRoutedByPreset() throws {
        for (preset, risk, expected): (AutonomyPreset, AskRisk, AskStatus) in [
            (.everything, .medium, .pendingOwner), (.important, .medium, .approved), (.important, .high, .pendingOwner),
            (.auto, .high, .approved),
        ] {
            let w = try W(preset: preset)
            let i = try modeItem(w)
            let a = try w.propose(.boost, risk: risk, title: "Ultra for \(i.key)", itemId: i.id)
            #expect(a.kind == .boost); #expect(a.internalApproverId == w.ceo.id)
            let d = try w.decide(a, by: w.ceo)
            #expect(d.status == expected, "\(preset) \(risk)")
            #expect(d.category == nil)
        }
    }

    @Test func requestModeNextTurnOnly() throws {
        let w = try W()
        let item = try modeItem(w)
        _ = try w.store.transition(agentId: w.eng.id, to: .ready)
        let (_, turn) = try #require(try w.store.beginTurn(agentId: w.eng.id, now: w.now))
        let out = try w.tools(w.eng).call(name: "request_mode", arguments: [
            "key": .string(item.key), "mode": .string("deep"), "reason": .string("tricky parser"), "request_id": .string("m1")])
        #expect(out.contains("next turn")); #expect(out.contains("R2"))
        let after = try #require(try w.store.workItem(id: item.id))
        #expect(after.rungFloor == 2)
        let rec = try #require(try w.store.modeRequests(itemId: item.id).first)
        #expect(rec.turnId == turn.id); #expect(rec.mode == "deep"); #expect(rec.requestId == "m1")
        // The same request id is answered again, not recorded twice; a new one in the same window is refused.
        #expect(try w.tools(w.eng).call(name: "request_mode", arguments: [
            "key": .string(item.key), "mode": .string("deep"), "reason": .string("x"), "request_id": .string("m1")]).contains("already"))
        #expect(try w.store.modeRequests(itemId: item.id).count == 1)
        #expect(throws: ToolError.self) {
            try w.tools(w.eng).call(name: "request_mode", arguments: ["key": .string(item.key), "mode": .string("deep"), "reason": .string("x"), "request_id": .string("m2")])
        }
        // Three further turns lift the rate limit (the floor is already R2 then).
        for _ in 1...3 {
            _ = try w.store.finishTurn(id: try #require(try w.store.lastTurn(agentId: w.eng.id)).id, outcome: .succeeded, summary: nil, costUSD: nil, now: w.now)
            _ = try w.store.transition(agentId: w.eng.id, to: .sleeping)
            _ = try w.store.transition(agentId: w.eng.id, to: .ready)
            _ = try w.store.beginTurn(agentId: w.eng.id, now: w.now.addingTimeInterval(10))
        }
        let again = try w.tools(w.eng).call(name: "request_mode", arguments: ["key": .string(item.key), "mode": .string("deep"), "reason": .string("x"), "request_id": .string("m3")])
        #expect(again.contains("already"))
    }

    @Test func assigneeRequestCappedAtR2() throws {
        let w = try W()
        let item = try modeItem(w)
        // Only the assignee asks.
        #expect(throws: ToolError.self) {
            try w.tools(w.cto).call(name: "request_mode", arguments: ["key": .string(item.key), "mode": .string("deep"), "reason": .string("x"), "request_id": .string("a")])
        }
        #expect(try w.store.workItem(id: item.id)?.rungFloor == 0)
        // Ultra is not available yet, and never changes the floor or files an ask.
        let u = try w.tools(w.eng).call(name: "request_mode", arguments: ["key": .string(item.key), "mode": .string("ultra"), "reason": .string("x"), "request_id": .string("b")])
        #expect(u == "Ultra arrives with the sandbox (5-lite)")
        #expect(try w.store.workItem(id: item.id)?.rungFloor == 0); #expect(try w.store.asks(companyId: w.company.id).isEmpty)
        #expect(throws: ToolError.self) {
            try w.tools(w.eng).call(name: "request_mode", arguments: ["key": .string(item.key), "mode": .string("max"), "reason": .string("x"), "request_id": .string("c")])
        }
        // A floor the engine already raised above R2 stays.
        try w.store.writer.write { db in try db.execute(sql: "UPDATE workItem SET rungFloor = 4 WHERE id = ?", arguments: [item.id]) }
        let hi = try w.tools(w.eng).call(name: "request_mode", arguments: ["key": .string(item.key), "mode": .string("deep"), "reason": .string("x"), "request_id": .string("d")])
        #expect(hi.contains("already")); #expect(try w.store.workItem(id: item.id)?.rungFloor == 4)
    }

    @Test func failurePathUltraAlwaysAsksOwner() throws {
        for preset in AutonomyPreset.allCases {
            let w = try W(preset: preset)
            let item = try modeItem(w)
            let a = try w.store.fileFailurePathBoost(companyId: w.company.id, itemId: item.id, reason: "R4 and 2 more failures", now: w.now)
            #expect(a.kind == .boost); #expect(a.status == .pendingOwner, "\(preset)"); #expect(a.requesterId == "system")
            #expect(a.risk == .high); #expect(a.itemId == item.id); #expect(!a.fyi)
            // One unresolved boost per item.
            #expect(try w.store.fileFailurePathBoost(companyId: w.company.id, itemId: item.id, reason: "again", now: w.now).id == a.id)
            #expect(try w.store.ownerDecide(askId: a.id, approve: true, note: "", now: w.now).status == .approved)
            #expect(try w.dms("owner").contains { $0.contains(a.ref) })
        }
    }

    // MARK: Model context

    @Test func architectureApproverTurnUsesOpus() async throws {
        let w = try World()
        let c = try w.company("Acme")
        let cto = try w.store.hire(companyId: c.id, name: "cto", role: "cto", model: "auto")
        let ceo = try w.store.hire(companyId: c.id, name: "ceo", role: "ceo", model: "auto")
        let eng = try w.hire(c, "eng-1", role: "engineer")
        func model(_ name: String) -> String? { w.fake.requests.last { $0.agent.name == name }?.agent.model }
        let arch = try w.store.propose(companyId: c.id, by: .agent(eng.id), kind: .architecture, risk: nil, category: nil, title: "t", summary: "s",
                                       payload: nil, itemId: nil, subjectId: nil, supersedes: nil, now: w.clock.now)
        #expect(try w.store.pendingInternalAsks(approverId: cto.id, kind: .architecture).map(\.id) == [arch.id])
        #expect(try w.store.askModelContext(agentId: cto.id) == ModelContext(decidingArchitecture: true))
        #expect(try w.store.askModelContext(agentId: eng.id) == ModelContext())
        try await w.cycle()
        #expect(model("cto") == "opus")
        // A PRD approver gets opus too; an approver with nothing pending does not.
        let prd = try w.store.propose(companyId: c.id, by: .agent(eng.id), kind: .prd, risk: nil, category: nil, title: "p", summary: "s",
                                      payload: nil, itemId: nil, subjectId: nil, supersedes: nil, now: w.clock.now)
        #expect(try w.store.askModelContext(agentId: ceo.id) == ModelContext(decidingPRD: true))
        try await w.cycle()
        #expect(model("ceo") == "opus")
        _ = try w.store.internalDecide(askId: arch.id, by: .agent(cto.id), approve: false, note: "no", now: w.clock.now)
        _ = try w.store.internalDecide(askId: prd.id, by: .agent(ceo.id), approve: false, note: "no", now: w.clock.now)
        #expect(try w.store.askModelContext(agentId: cto.id) == ModelContext())
        try w.dm(c, cto); try await w.cycle()
        #expect(model("cto") != "opus")
    }
}
