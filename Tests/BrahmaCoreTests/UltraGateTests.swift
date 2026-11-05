import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// Inputs that pass every hard gate for Ultra-small on max5x in the Max usage mode.
func passingUltraGates() -> UltraGateInputs {
    var g = UltraGateInputs()
    g.profile = .sandboxed
    g.passedGates = Set(UltraGate.requiredGates)
    g.initToolsHaveWorkflow = true
    g.planTier = .max5x
    g.planTierConfirmed = true
    g.weekWindows = 10; g.fiveHourWindows = 12
    g.pctPerDollar = 0.001          // $15 is 1.5% of the week
    g.pctPerDollar5h = 0.01         // $15 is 15% of five hours
    g.pace = .onPace; g.sevenDayUtil = 0.20; g.allowedWeek = 0.50
    g.freshFiveHourUtil = 0.30
    g.extraUsageEnabled = false
    g.allowanceLeftLE = 50
    g.freeSlots = 8
    g.usageMode = .max
    return g
}

/// An Ultra-eligible work turn's mode inputs (confirmed tier L).
func eligibleUltraInputs() -> ModeInputs {
    var i = ModeInputs()
    i.hasItem = true; i.tier = .l; i.budgetLeftLE = 40; i.usageMode = .max
    return i
}

/// The approval routing through the store: a company, its manager, its engineer and an item.
private struct ApprovalWorld {
    let store: Store, company: Company
    let mgr: Agent, eng: Agent
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init(preset: AutonomyPreset = .important, profile: PermissionProfile = .sandboxed) throws {
        store = try Store.inMemory()
        company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        mgr = try store.hire(companyId: company.id, name: "mgr", role: "manager", model: "sonnet")
        eng = try store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet", managerId: mgr.id)
        try store.setAutonomy(companyId: company.id, preset)
        if profile != .sandboxed {
            try store.writer.write { db in try db.execute(sql: "UPDATE company SET permissionProfile = ? WHERE id = ?",
                                                          arguments: [profile.rawValue, company.id]) }
        }
    }

    func item(_ title: String = "Hard thing") throws -> WorkItem {
        try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(type: .task, title: title, ownerId: eng.id,
                                                                                         status: .ready), now: now)
    }

    func request(_ item: WorkItem, _ mode: String, by agent: Agent? = nil, id: String = "r1") throws -> ModeRequestResult {
        try store.requestMode(companyId: company.id, by: (agent ?? eng).id, itemKey: item.key, mode: mode, reason: "needs a sweep",
                              requestId: id, now: now)
    }

    func boosts(_ item: WorkItem) throws -> [Ask] { try store.asks(companyId: company.id).filter { $0.kind == .boost && $0.itemId == item.id } }
}

@Suite(.scratch) struct UltraGateTests {
    // MARK: Eligibility and gates

    @Test func ultraNeedsConfirmedEligibility() throws {
        #expect(UltraEligibility.basis(eligibleUltraInputs()) == "confirmed tier L")
        var p0 = ModeInputs(); p0.hasItem = true; p0.tier = .m; p0.priority = 0; p0.blockingCount = 2
        #expect(UltraEligibility.basis(p0) == "confirmed P0 blocking 2")
        p0.blockingCount = 1
        #expect(UltraEligibility.basis(p0) == nil)
        var audit = ModeInputs(); audit.hasItem = true; audit.tier = .s; audit.itemType = "Research spike"
        #expect(UltraEligibility.basis(audit) == "confirmed research-spike item")
        var trigger = ModeInputs(); trigger.hasItem = true; trigger.tier = .s; trigger.ultraTrigger = true
        #expect(UltraEligibility.basis(trigger) != nil)
        // Effective values only: a self-authored tier L counts as M, a self-authored P0 as P2, and neither qualifies.
        #expect(EffectiveSpec.tier(stored: .l, confirmedBy: nil, holderId: "a") == .m)
        #expect(EffectiveSpec.priority(stored: 0, confirmedBy: "a:manager", holderId: "a") == 2, "the holder cannot confirm its own")
        var plain = ModeInputs(); plain.hasItem = true; plain.tier = .m
        #expect(UltraEligibility.check(plain) != nil)
        // Never a review, notice or itemless turn.
        var review = eligibleUltraInputs(); review.turnKind = .review
        #expect(UltraEligibility.basis(review) == nil)
        var itemless = eligibleUltraInputs(); itemless.hasItem = false
        #expect(UltraEligibility.basis(itemless) == nil)
    }

    @Test func ultraRefusedOnWorkspaceProfile() {
        #expect(UltraGate.admit(.small, passingUltraGates()) == .success(.small))
        for profile in [PermissionProfile.workspace, .full] {
            var g = passingUltraGates(); g.profile = profile
            guard case .failure(let r) = UltraGate.admit(.small, g) else { Issue.record("admitted on \(profile)"); continue }
            #expect(r.gate == 1); #expect(r.reason == "Ultra runs only on the sandboxed profile")
        }
    }

    @Test func ultraRefusedUntilU3AndV1V2V8V9Pass() async throws {
        // Fix round 1, I3: every gate of the Ultra shape, not a subset.
        #expect(UltraGate.requiredGates == ProbeGates.catalog(.ultra)); #expect(UltraGate.requiredGates.count == 14)
        for missing in UltraGate.requiredGates {
            var g = passingUltraGates(); g.passedGates.remove(missing); g.cliVersion = "2.1.320"
            #expect(UltraGate.admit(.small, g) == .failure(UltraRefusal(gate: 1, reason: "probe gate \(missing) failing for claude 2.1.320")))
        }
        var noWorkflow = passingUltraGates(); noWorkflow.initToolsHaveWorkflow = false
        #expect(UltraGate.admit(.full, noWorkflow) == .failure(UltraRefusal(gate: 1, reason: "the CLI offers no Workflow tool")))
        // V-9 is pending the owner: running it records a failure and runs nothing.
        let store = try Store.inMemory()
        let r = await ProbeGates.run(gate: "V-9", shape: .ultra, runner: RecordingGates(), store: store, fingerprint: "fp")
        #expect(!r.passed); #expect(r.detail.hasPrefix("pending owner decision"))
        #expect(try store.passedProbeGates(fingerprint: "fp", shape: .ultra).isEmpty)
        #expect(try store.probeGateRows(fingerprint: "fp").map(\.gate) == ["V-9"])
    }

    @Test func ultraRefusedWhenOverageAllowed() {
        var g = passingUltraGates(); g.overageStatus = "allowed"
        #expect(UltraGate.admit(.small, g) == .failure(UltraRefusal(gate: 2, reason: "extra usage is on")))
        g = passingUltraGates(); g.isUsingOverage = true
        #expect(UltraGate.failures(.small, g).first?.gate == 2)
    }

    @Test func ultraRefusedOnUnconfirmedPlanTier() {
        var g = passingUltraGates(); g.planTierConfirmed = false
        #expect(UltraGate.admit(.small, g) == .failure(UltraRefusal(gate: 3, reason: "plan tier not confirmed")))
        g = passingUltraGates(); g.planTier = .pro
        #expect(UltraGate.failures(.small, g).first == UltraRefusal(gate: 3, reason: "the Pro plan has no Ultra"))
        // A tier that was never reported is not confirmed.
        #expect(!PlanTierEffective.resolve(configured: .max5x, reported: nil).confirmed)
    }

    // MARK: Plan tier

    @Test func cliMaxAgreesWithMax5x() {
        for tier in [PlanTier.max5x, .max20x] {
            let e = PlanTierEffective.resolve(configured: tier, reported: "max")
            #expect(e.tier == tier); #expect(e.confirmed); #expect(e.mismatch == nil)
        }
        #expect(PlanTierEffective.resolve(configured: .max5x, reported: "max_5x").confirmed)
    }

    @Test func cliProClampsAndAlerts() async throws {
        let e = PlanTierEffective.resolve(configured: .max5x, reported: "pro")
        #expect(e.tier == .pro); #expect(!e.confirmed); #expect(e.mismatch?.contains("pro") == true)
        #expect(PlanTierEffective.resolve(configured: .max20x, reported: "max_5x").tier == .max5x, "the lower of the two")
        // The engine uses the lower tier for Ultra and raises one engine alert while it is open.
        let w = try World()
        try w.store.setPlanTier(.max5x)
        try w.store.saveProbe(DoctorReport(cliVersion: nil, items: [], checkedAt: w.clock.now, reportedSubscription: "pro"))
        let c = try w.company("Acme", mode: .max, profile: .sandboxed)
        let a = try w.hire(c, "eng-1", role: "engineer")
        let g = await w.orchestrator.ultraGateInputs(company: c, agent: a, profile: .sandboxed)
        #expect(g.planTier == .pro); #expect(!g.planTierConfirmed)
        _ = await w.orchestrator.ultraGateInputs(company: c, agent: a, profile: .sandboxed)
        let alerts = try w.store.asks(companyId: c.id).filter {
            $0.kind == .engineAlert && $0.subjectId == EngineAlerts.askSubject(reason: Orchestrator.planTierAlertReason)
        }
        #expect(alerts.count == 1)
        #expect(UltraGate.failures(.small, g).contains { $0.gate == 3 })
    }

    // MARK: Pacing

    @Test func ultraRefusedUncalibrated() {
        var g = passingUltraGates(); g.weekWindows = 9
        #expect(UltraGate.admit(.small, g) == .failure(UltraRefusal(gate: 4, reason: "not calibrated yet (9/10 windows)")))
        g = passingUltraGates(); g.pctPerDollar5h = nil
        #expect(UltraGate.failures(.small, g).first?.gate == 4)
        #expect(UltraStatus.explain(UltraGateInputs()).contains("not calibrated yet (0/10 windows)"))
    }

    @Test func ultraMustFitPace() {
        for state in [PaceState.ahead, .closed] {
            var g = passingUltraGates(); g.pace = state
            #expect(UltraGate.failures(.small, g).first?.gate == 5)
        }
        // 0.20 + (0 + 15) × 0.001 = 0.215 fits 0.216; with $10 of open reservations it does not (0.225).
        var g = passingUltraGates(); g.allowedWeek = 0.216
        #expect(UltraGate.admit(.full, g) == .success(.full))
        g.openReservationLE = 10
        #expect(UltraGate.failures(.full, g).first?.gate == 5)
        // There is no critical-path exemption, and no reading is no admission.
        g = passingUltraGates(); g.sevenDayUtil = nil
        #expect(UltraGate.failures(.small, g).first?.gate == 5)
    }

    @Test func ultraFiveHourGateUsesFreshUsageAndReservations() async throws {
        var g = passingUltraGates(); g.freshFiveHourUtil = 0.61
        #expect(UltraGate.admit(.small, g) == .failure(UltraRefusal(gate: 6, reason: "5-hour use 61% is above 60%")))
        // 0.60 + (0 + 4) × 0.01 = 0.64 fits; with $22 open: 0.60 + 26 × 0.01 = 0.86 does not.
        g.freshFiveHourUtil = 0.60
        #expect(UltraGate.admit(.small, g) == .success(.small))
        g.openReservationLE = 22
        #expect(UltraGate.failures(.small, g).first == UltraRefusal(gate: 6, reason: "5-hour projection 86% would pass 85%"))
        g = passingUltraGates(); g.freshFiveHourUtil = nil
        #expect(UltraGate.failures(.small, g).first?.gate == 6)
        #expect(UltraGate.failures(.small, g, skipFresh: true).isEmpty, "the fresh reading is taken last")
        // The fresh reading is a zero-inference control session: a fake claude answers `get_usage` in the real format.
        let usage = #"{"type":"control_response","response":{"subtype":"success","request_id":"cu","response":{"subscription_type":"max","rate_limits":{"five_hour":{"utilization":42,"resets_at":"2026-10-22T02:20:00.397713+00:00"},"seven_day":{"utilization":12,"resets_at":"2026-10-22T14:00:00+00:00"},"extra_usage":{"is_enabled":false}}}}}"#
        let claude = try FakeTools.script("claude", """
        read line; read line
        echo '\(usage)'
        """)
        let root = try tempDir()
        let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
        let reading = try #require(await ControlProbe.getUsage(runner: ClaudeProcessRunner(claudePath: claude.path,
                                                                                          baseEnvironment: ["PATH": "/usr/bin:/bin"]),
                                                               paths: paths, hookExecutable: "/usr/local/bin/brahma"))
        #expect(reading.fiveHourUtil == 0.42); #expect(reading.sevenDayUtil == 0.12); #expect(reading.subscription == "max")
        #expect(reading.extraUsageEnabled == false); #expect(reading.fiveHourResetsAt != nil)
        #expect((try FileManager.default.contentsOfDirectory(atPath: paths.home.appending(path: "tmp").path)).isEmpty,
                "the probe's scratch is under the data home's tmp and removed")
        // A runner that cannot run control sessions takes no reading.
        #expect(await ControlProbe.getUsage(runner: FakeTurnRunner(), paths: paths) == nil)
    }

    // MARK: Caps

    @Test func ultraAllowanceAndReservation() throws {
        var g = passingUltraGates(); g.allowanceLeftLE = 3.99
        #expect(UltraGate.admit(.small, g) == .failure(UltraRefusal(gate: 7, reason: "allowance used")))
        g.allowanceLeftLE = nil
        #expect(UltraGate.failures(.small, g).first?.gate == 7)
        // The store: 15% of a 70% share at 0.1% of the week per $ is $105 LE; a reservation counts against it at its cap.
        let w = try ApprovalWorld()
        try w.store.writer.write { db in
            var cal = UsageCalibration()
            cal.week.samples = Array(repeating: 0.001, count: 10)
            try Store.saveCalibration(db, cal)
        }
        let item = try w.item()
        let before = try #require(try w.store.ultraAllowance(companyId: w.company.id, now: w.now))
        #expect(abs(before.totalLE - 105) < 1e-6); #expect(before.usedLE == 0)
        try w.store.reserveUltra(turnId: "t1", companyId: w.company.id, itemId: item.id,
                                 run: PendingUltraRun(variant: .full, approver: .owner, origin: .assignee, askId: nil), now: w.now)
        let after = try #require(try w.store.ultraAllowance(companyId: w.company.id, now: w.now))
        #expect(abs(after.leftLE - 90) < 1e-6)
        #expect(w.store.openReservationLE() == 15, "every other turn's 5-hour check counts it too")
        try w.store.writer.write { db in try Store.releaseUltra(db: db, turnId: "t1", actualLE: 6, now: w.now) }
        #expect(abs(try #require(try w.store.ultraAllowance(companyId: w.company.id, now: w.now)).leftLE - 99) < 1e-6)
        #expect(w.store.openReservationLE() == 0)
        // The owner's share: 0–50%.
        try w.store.setUltraShare(companyId: w.company.id, percent: 30)
        #expect(try w.store.company(id: w.company.id)?.ultraShare == 0.30)
        #expect(throws: SettingsError.self) { try w.store.setUltraShare(companyId: w.company.id, percent: 51) }
    }

    @Test func ultraDailyCap() {
        #expect(UltraCaps.max5x.perCompanyDay == 2); #expect(UltraCaps.max5x.fullPerCompanyDay == 1)
        var g = passingUltraGates(); g.ultraRunsToday = 2
        #expect(UltraGate.failures(.small, g).first?.gate == 8)
        g = passingUltraGates(); g.ultraRunsToday = 1; g.fullUltraRunsToday = 1
        #expect(UltraGate.failures(.full, g).first?.gate == 8, "at most one full Ultra a day on max5x")
        #expect(UltraGate.admit(.small, g) == .success(.small))
        g.planTier = .max20x; g.ultraRunsToday = 5; g.fullUltraRunsToday = 5
        #expect(UltraGate.admit(.full, g) == .success(.full))
    }

    @Test func ultraGlobalConcurrency() {
        var g = passingUltraGates(); g.runningUltra = 1
        #expect(UltraGate.failures(.small, g).first == UltraRefusal(gate: 8, reason: "another Ultra turn is running (at most 1 at once)"))
        g.planTier = .max20x; g.freeSlots = 16
        #expect(UltraGate.admit(.small, g) == .success(.small), "max20x allows two")
    }

    @Test func ultraSlotsLeaveOneFree() {
        #expect(UltraCaps.max5x.slots == 1 + UltraCaps.max5x.workflowAgents)
        var g = passingUltraGates(); g.freeSlots = 3
        #expect(UltraGate.failures(.small, g).first == UltraRefusal(gate: 9, reason: "no free slots (3 free, Ultra needs 4)"))
        g.freeSlots = 4
        #expect(UltraGate.admit(.small, g) == .success(.small))
    }

    @Test func max5xUltraOnlyInMaxMode() {
        for mode in [UsageMode.low, .balanced] {
            var g = passingUltraGates(); g.usageMode = mode; g.freeSlots = PlanTier.max5x.modeCap(mode)
            #expect(UltraGate.failures(.small, g).contains(UltraRefusal(gate: 9, reason: "needs the Max usage mode")), "\(mode)")
            #expect(UltraStatus.explain(g).contains("needs the Max usage mode"))
        }
        var low = passingUltraGates(); low.usageMode = .low
        #expect(UltraGate.failures(.small, low).contains { $0.gate == 10 && $0.reason == "Low usage mode" })
    }

    // MARK: Approvals

    @Test func ultraSmallPolicyOnlyForEndorsedUnescalated() throws {
        #expect(UltraApproval.route(.small, preset: .important, origin: .lead, escalated: false) == .policy)
        #expect(UltraApproval.route(.small, preset: .important, origin: .assignee, escalated: false) == .ownerAsk)
        #expect(UltraApproval.route(.small, preset: .important, origin: .lead, escalated: true) == .ownerAsk)
        #expect(UltraApproval.route(.small, preset: .everything, origin: .lead, escalated: false) == .ownerAsk)
        #expect(UltraApproval.route(.small, preset: .auto, origin: .assignee, escalated: true) == .policy)
        // The store: the manager above the assignee asks for Ultra-small: policy approves, the owner gets an FYI.
        let w = try ApprovalWorld()
        let item = try w.item()
        let r = try w.request(item, "ultra_small", by: w.mgr)
        #expect(r.kind == .ultraApproved)
        let ask = try #require(try w.boosts(item).first)
        #expect(ask.status == .approved); #expect(ask.fyi); #expect(ask.decidedBy == "policy:important")
        #expect(ask.payload?.proposal == "ultra_small"); #expect(ask.category == nil)
        #expect(try w.store.pendingUltraRun(itemId: item.id) == PendingUltraRun(variant: .small, approver: .policy, origin: .lead, askId: ask.id))
        #expect(try w.store.events(afterId: 0, companyId: w.company.id).contains { $0.kind == .approval && $0.text.hasPrefix("FYI: \(ask.ref)") })
        // The assignee's own Ultra-small request needs the owner.
        let w2 = try ApprovalWorld()
        let i2 = try w2.item()
        #expect(try w2.request(i2, "ultra_small").kind == .ultraAsked)
        #expect(try w2.boosts(i2).first?.status == .pendingOwner)
        // An item the engine escalated needs the owner even when the manager asks.
        let w3 = try ApprovalWorld()
        let i3 = try w3.item()
        try w3.store.applyEscalation(itemId: i3.id, actions: [.raiseFloor(to: 2, opus: false, reason: "2 counted failed checks")],
                                     kind: "failures", now: w3.now)
        #expect(try w3.request(i3, "ultra_small", by: w3.mgr).kind == .ultraAsked)
        // Someone outside the chain cannot ask.
        let outsider = try w3.store.hire(companyId: w3.company.id, name: "eng-2", role: "engineer", model: "sonnet")
        #expect(throws: WorkError.self) { try w3.request(try w3.item("Other"), "ultra_small", by: outsider) }
        // Not on the workspace profile: nothing is filed.
        let ws = try ApprovalWorld(profile: .workspace)
        let i4 = try ws.item()
        #expect(try ws.request(i4, "ultra").kind == .ultraUnavailable); #expect(try ws.boosts(i4).isEmpty)
    }

    @Test func ultraFullAsksOwnerUnderImportant() throws {
        for (preset, expected): (AutonomyPreset, UltraRoute) in [(.everything, .ownerAsk), (.important, .ownerAsk), (.auto, .policy)] {
            #expect(UltraApproval.route(.full, preset: preset, origin: .lead, escalated: false) == expected, "\(preset)")
        }
        let w = try ApprovalWorld()
        let item = try w.item()
        let r = try w.request(item, "ultra", by: w.mgr)
        #expect(r.kind == .ultraAsked)
        let ask = try #require(try w.boosts(item).first)
        #expect(ask.status == .pendingOwner); #expect(!ask.fyi)
        // M1: approve or reject only; "Thorough instead" had no effect and is not offered.
        #expect(ask.payload?.options.map(\.label) == ["Run Ultra once", "No, keep going"])
        #expect(ask.summary.hasPrefix("\(item.key) 'Hard thing' wants an Ultra run: @mgr: needs a sweep. Up to $15.00 LE ≈ ?% of this week"))
        #expect(ask.expiresActive == ask.createdActive + 86_400, "it expires after one active day")
        // A second request gets the open ask; the request's cooldown applies to a repeat.
        #expect(try w.request(item, "ultra", by: w.mgr, id: "r2").kind == .coolingDown)
        #expect(try w.boosts(item).count == 1)
        // Approved by the owner, the run waits for the item's next turn.
        _ = try w.store.ownerDecide(askId: ask.id, approve: true, note: "go", now: w.now)
        #expect(try w.store.pendingUltraRun(itemId: item.id)?.approver == .owner)
    }

    @Test func failurePathUltraAlwaysAsksOwner() throws {
        for preset in AutonomyPreset.allCases {
            #expect(UltraApproval.route(.full, preset: preset, origin: .failurePath, escalated: false) == .ownerAsk)
            #expect(UltraApproval.route(.small, preset: preset, origin: .failurePath, escalated: false) == .ownerAsk)
            let w = try ApprovalWorld(preset: preset)
            let item = try w.item()
            let a = try w.store.fileFailurePathBoost(companyId: w.company.id, itemId: item.id, reason: "2 counted failed checks at R4", now: w.now)
            #expect(a.status == .pendingOwner, "\(preset)"); #expect(a.requesterId == "system"); #expect(a.risk == .high)
            #expect(a.payload?.options.count == 2); #expect(a.summary.contains("wants an Ultra run: 2 counted failed checks at R4"))
            _ = try w.store.ownerDecide(askId: a.id, approve: true, note: "", now: w.now)
            let run = try #require(try w.store.pendingUltraRun(itemId: item.id))
            #expect(run.origin == .failurePath); #expect(run.variant == .full)
        }
    }

    @Test func ownerIntensityUltraIsOneRun() throws {
        let w = try ApprovalWorld()
        let item = try w.item()
        #expect(try w.store.pendingUltraRun(itemId: item.id) == nil)
        _ = try w.store.updateWorkItem(id: item.id, by: .owner, patch: WorkItemPatch(intensity: .ultra), now: w.now)
        let run = try #require(try w.store.pendingUltraRun(itemId: item.id))
        #expect(run == PendingUltraRun(variant: .full, approver: .owner, origin: .ownerIntensity, askId: nil))
        #expect(UltraApproval.route(.full, preset: .everything, origin: .ownerIntensity, escalated: true) == .ownerApproved)
        try w.store.reserveUltra(turnId: "t1", companyId: w.company.id, itemId: item.id, run: run, now: w.now)
        #expect(try w.store.workItem(id: item.id)?.intensity == .auto, "one run")
        #expect(try w.store.pendingUltraRun(itemId: item.id) == nil)
        // A run that never launched gives the intensity back.
        try w.store.cancelUltraReservation(turnId: "t1", now: w.now)
        #expect(try w.store.workItem(id: item.id)?.intensity == .ultra)
    }

    // MARK: Budget and taint

    @Test func ultraExtendsItemBudgetOnce() throws {
        let w = try ApprovalWorld()
        let item = try w.item()
        let run = PendingUltraRun(variant: .small, approver: .policy, origin: .lead, askId: "ask-1")
        try w.store.reserveUltra(turnId: "t1", companyId: w.company.id, itemId: item.id, run: run, now: w.now)
        try w.store.reserveUltra(turnId: "t1", companyId: w.company.id, itemId: item.id, run: run, now: w.now)
        #expect(try w.store.workItem(id: item.id)?.budgetBoostLE == 4)
        #expect(try w.store.ultraReservations(companyId: w.company.id).count == 1)
        let facts = try #require(try w.store.itemModeFacts(itemId: item.id, holderId: w.eng.id))
        #expect(facts.budgetLeftLE == TierBudget.of(item.tier).maxCostLE + 4)
    }

    @Test func ultraDoesNotTripTokenBudget() throws {
        let w = try ApprovalWorld()
        let item = try w.item()
        try w.store.writer.write { db in
            for (id, mode, tokens) in [("u1", "ultra", 5_000_000), ("s1", "standard", 1000)] {
                try db.execute(sql: """
                    INSERT INTO turn (id, agentId, companyId, startedAt, endedAt, outcome, kind, itemId, mode, inputTokens, costLE, infra)
                    VALUES (?, ?, ?, ?, ?, 'succeeded', 'work', ?, ?, ?, 3, 0)
                    """, arguments: [id, w.eng.id, w.company.id, w.now, w.now, item.id, mode, tokens])
            }
        }
        let usage = try w.store.itemUsage(itemId: item.id)
        #expect(usage.tokens == 1000, "the Ultra turn's tokens stay out of the tier token cap")
        #expect(usage.turns == 2, "it counts as one turn"); #expect(usage.costLE == 6, "its $LE counts")
    }

    @Test func ultraNotReservedMatter() throws {
        #expect(!ReservedMatters.isReserved(nil, extra: []))
        // Under `auto` even a full Ultra is Brahma policy's (gate 2 guarantees it spends no money), never a reserved ask.
        let w = try ApprovalWorld(preset: .auto)
        let item = try w.item()
        #expect(try w.request(item, "ultra").kind == .ultraApproved)
        let ask = try #require(try w.boosts(item).first)
        #expect(ask.category == nil); #expect(ask.status == .approved); #expect(ask.decidedBy == "policy:auto")
    }

    @Test func taintedSessionNoUltra() {
        var g = passingUltraGates(); g.sessionTainted = true
        #expect(UltraGate.admit(.small, g) == .failure(UltraRefusal(gate: 10, reason: "the session read outside content")))
        g = passingUltraGates(); g.trust = "T0"
        #expect(UltraGate.failures(.small, g).first?.gate == 10)
    }
}

/// Fix round 1 (S26–S28, I2–I4 and the security minors), gate-level.
@Suite(.scratch, .serialized) struct UltraGateFixTests {
    @Test func gate1RequiresEveryUltraGate() {
        for missing in ProbeGates.catalog(.ultra) {
            var g = passingUltraGates(); g.passedGates.remove(missing)
            #expect(UltraGate.failures(.small, g).first?.gate == 1, "\(missing) unproven must refuse")
        }
        // The six gates of the first build are no longer enough.
        var six = passingUltraGates(); six.passedGates = ["U-1", "U-3", "V-1", "V-2", "V-8", "V-9"]
        #expect(UltraGate.failures(.small, six).first?.gate == 1)
    }

    @Test func gate2FailsClosedWithoutEvidence() {
        var g = passingUltraGates(); g.extraUsageEnabled = nil; g.overageStatus = nil
        #expect(UltraGate.admit(.small, g) == .failure(UltraRefusal(gate: 2, reason: "extra usage status unknown (none)")))
        g.overageStatus = "something_new"
        #expect(UltraGate.failures(.small, g).first?.gate == 2, "an unknown status is not evidence")
        g.overageStatus = "rejected"
        #expect(UltraGate.admit(.small, g) == .success(.small), "a known off status and no overage in use")
        g.isUsingOverage = true
        #expect(UltraGate.failures(.small, g).first?.gate == 2)
        g = passingUltraGates(); g.overageStatus = nil; g.extraUsageEnabled = false
        #expect(UltraGate.admit(.small, g) == .success(.small), "the fresh reading says extra usage is off")
        g.extraUsageEnabled = true
        #expect(UltraGate.failures(.small, g).first == UltraRefusal(gate: 2, reason: "extra usage is on"))
        // Before the fresh reading only a positive "on" is judged.
        var early = passingUltraGates(); early.extraUsageEnabled = nil
        #expect(UltraGate.failures(.small, early, skipFresh: true).isEmpty)
    }

    @Test func trustFailsClosedAndRoleCapHoldsAtR5() {
        for trust in ["T0", "", "t1", "T9", "admin"] {
            var g = passingUltraGates(); g.trust = trust
            #expect(UltraGate.failures(.small, g).first?.gate == 10, "trust '\(trust)'")
        }
        var t2 = passingUltraGates(); t2.trust = "T2"
        #expect(UltraGate.admit(.small, t2) == .success(.small))
        var capped = passingUltraGates(); capped.roleMaxRung = 3
        #expect(UltraGate.failures(.small, capped).first == UltraRefusal(gate: 10, reason: "the role is capped at R3"))
        // And the policy never compiles R5 for such a role, whatever was admitted.
        var i = eligibleUltraInputs(); i.roleMaxRung = 3
        i.ultra = UltraAdmission(variant: .full, approver: .owner, workflowAgents: 2, basis: "confirmed tier L")
        let d = ModePolicy.select(i)
        #expect(d.mode != .ultra); #expect(d.workflow == nil); #expect(d.reason.contains("Ultra not admitted: the role is capped at R3"))
    }

    /// S28: the count gates are judged again in the reserving transaction: of two admissions racing for one concurrent slot,
    /// exactly one reserves; the per-day caps hold the same way.
    @Test func reserveRechecksCountGatesInTransaction() async throws {
        let store = try Store.inMemory()
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let eng = try store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
        try await store.writer.write { db in
            var cal = UsageCalibration()
            cal.week.samples = Array(repeating: 0.001, count: 10)
            try Store.saveCalibration(db, cal)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let items = try (0..<4).map { n in
            try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(type: .task, title: "I\(n)", ownerId: eng.id,
                                                                                             status: .ready), now: now)
        }
        let small = PendingUltraRun(variant: .small, approver: .owner, origin: .assignee, askId: nil)
        let reserved = await withTaskGroup(of: Bool.self) { group in
            for n in 0..<2 {
                group.addTask {
                    (try? store.reserveUltra(turnId: "t\(n)", companyId: company.id, itemId: items[n].id, run: small, caps: .max5x, now: now)) != nil
                }
            }
            var ok = 0
            for await r in group where r { ok += 1 }
            return ok
        }
        #expect(reserved == 1, "the concurrent cap (1 on max5x) admits exactly one")
        #expect(try store.runningUltraCount() == 1)
        // Released, the second run of the day reserves; a third is over the day's cap (2 on max5x).
        let first = try #require(try store.ultraReservations(companyId: company.id).first)
        try await store.writer.write { db in try Store.releaseUltra(db: db, turnId: first.turnId, actualLE: 1, now: now) }
        try store.reserveUltra(turnId: "t2", companyId: company.id, itemId: items[2].id, run: small, caps: .max5x, now: now)
        try await store.writer.write { db in try Store.releaseUltra(db: db, turnId: "t2", actualLE: 1, now: now) }
        #expect(throws: UltraRefusal.self) {
            try store.reserveUltra(turnId: "t3", companyId: company.id, itemId: items[3].id, run: small, caps: .max5x, now: now)
        }
        // A refused reservation consumed nothing.
        #expect(try store.workItem(id: items[3].id)?.budgetBoostLE == 0)
        #expect(try store.ultraReservation(turnId: "t3") == nil)
        // The allowance is judged there too.
        try store.setUltraShare(companyId: company.id, percent: 0)
        #expect(throws: UltraRefusal.self) {
            try store.reserveUltra(turnId: "t4", companyId: company.id, itemId: items[3].id, run: small, caps: .max20x, now: now)
        }
    }

    /// I4: gate 9 counts slots as the scheduler does (the engine's hard cap and its engine-wide room).
    @Test func gate9UsesTheSchedulersEffectiveCap() async throws {
        let w = try World(config: World.config(hardCap: 2))
        let c = try w.company("Acme", mode: .max, profile: .sandboxed)
        let a = try w.hire(c, "eng-1", role: "engineer")
        #expect(PlanTier.max20x.modeCap(.max) == 16)
        #expect(await w.orchestrator.ultraFreeSlots(company: c, includingAsking: false) == 2)
        let g = await w.orchestrator.ultraGateInputs(company: c, agent: a, profile: .sandboxed)
        #expect(g.freeSlots == 2)
        #expect(UltraGate.failures(.small, g).contains { $0.gate == 9 }, "16 by the tier, but the engine runs at most 2")
    }
}

/// A probe-gate runner that passes what it is told and records what it was asked.
final class RecordingGates: ProbeGateRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _asked: [String] = []
    let passing: Set<String>
    init(passing: Set<String> = []) { self.passing = passing }
    var asked: [String] { lock.withLock { _asked } }
    func run(gate: String, shape: ProbeShape) async -> GateResult {
        lock.withLock { _asked.append("\(shape.rawValue)/\(gate)") }
        return GateResult(gate: gate, shape: shape, passed: passing.contains(gate), detail: passing.contains(gate) ? "fake pass" : "fake fail")
    }
}
