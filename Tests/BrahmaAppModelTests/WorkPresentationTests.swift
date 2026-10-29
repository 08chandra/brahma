import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite(.scratch) struct WorkPresentationTests {
    @Test func backlogTreeOrder() async throws {
        let w = try await WorkWorld.make()
        let epic = try w.item("Epic", type: .epic)
        let story = try w.item("Story", type: .story, parent: epic)
        let late = try w.item("Late child", parent: story, status: .backlog)
        let urgent = try w.item("Urgent", priority: 0)
        let low = try w.item("Low", priority: 4)
        await w.refresh()
        let rows = w.model.backlogRows
        #expect(rows.map(\.title) == ["Urgent", "Epic", "Story", "Late child", "Low"])
        #expect(rows.map(\.depth) == [0, 0, 1, 2, 0])
        #expect(rows.first { $0.id == epic.id }?.hasChildren == true)
        #expect(rows.first { $0.id == late.id }?.hasChildren == false)
        #expect(rows.first { $0.id == urgent.id }?.priorityLabel == "P0")
        #expect(rows.first { $0.id == low.id }?.statusTitle == "Backlog")
    }

    @Test func doneHiddenUnlessAsked() async throws {
        let w = try await WorkWorld.make()
        let open = try w.item("Open")
        let finished = try w.item("Finished")
        try w.setStatus(finished, .done)
        await w.refresh()
        #expect(w.model.backlogRows.map(\.id) == [open.id])
        w.model.showDoneItems = true
        #expect(Set(w.model.backlogRows.map(\.id)) == [open.id, finished.id])
    }

    @Test func boardColumnsOrderAndSprintFilter() async throws {
        let w = try await WorkWorld.make()
        let a = try w.item("A"), b = try w.item("B"), c = try w.item("C"), d = try w.item("D"), e = try w.item("E")
        try w.setStatus(a, .ready); try w.setStatus(b, .inProgress); try w.setStatus(c, .inReview)
        try w.setStatus(d, .blocked); try w.setStatus(e, .done)
        await w.refresh()
        let columns = w.model.boardColumns
        #expect(columns.map(\.title) == ["Backlog", "Ready", "In progress", "In review", "Blocked", "Done"])
        #expect(columns.map { $0.rows.map(\.title) } == [[], ["A"], ["B"], ["C"], ["D"], ["E"]])
        // A sprint filter keeps only that sprint's items.
        let sprintId = "sprint-1"
        try await w.store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET sprintId = ? WHERE id = ?", arguments: [sprintId, b.id])
        }
        await w.refresh()
        w.model.boardSprintId = sprintId
        #expect(w.model.boardColumns.flatMap(\.rows).map(\.title) == ["B"])
    }

    @Test func checkLabels() {
        #expect(CheckText.label(status: nil, hasCheck: true) == "No check run yet")
        #expect(CheckText.label(status: nil, hasCheck: false) == "No check")
        #expect(CheckText.label(status: .queued) == "Check queued")
        #expect(CheckText.label(status: .running) == "Checking")
        #expect(CheckText.label(status: .passed) == "Check passed")
        #expect(CheckText.label(status: .passed, flaky: true) == "Check passed (flaky)")
        #expect(CheckText.label(status: .failed) == "Check failed")
        #expect(CheckText.label(status: .timedOut) == "Check timed out")
        #expect(CheckText.label(status: .inconclusive) == "Check inconclusive")
        #expect(CheckText.label(status: .error) == "Check error")
        // A merge in flight wins over the last check.
        #expect(CheckText.label(status: .passed, mergeState: .pending) == "Merging")
        #expect(CheckText.label(status: .passed, mergeState: .verifying) == "Merging")
    }

    @Test func sprintLines() async throws {
        let w = try await WorkWorld.make()
        let done = try w.item("Done one"), open = try w.item("Open one")
        let json = """
            {"id":"sp1","companyId":"\(w.company.id)","number":3,"team":"core","goal":"Ship","cadence":"sprint",
             "status":"pendingApproval","timeboxDays":5,"timeboxTurns":200,"createdAt":0}
            """
        let sprint = try JSONDecoder().decode(Sprint.self, from: Data(json.utf8))
        var items = [done, open]
        items[0].sprintId = "sp1"; items[0].status = .done; items[1].sprintId = "sp1"
        #expect(SprintText.line(sprint, items: items) == "Sprint 3 · core · awaiting approval · 1/2 done")
        var company = sprint
        company.team = nil; company.status = .review
        #expect(SprintText.line(company, items: items) == "Sprint 3 · company · in review · 1/2 done")
    }

    @Test func openSprintsIncludePendingApprovalAndReview() async throws {
        let w = try await WorkWorld.make()
        let item = try w.item("Planned")
        let (sprint, _) = try w.store.planSprint(companyId: w.company.id, by: .agent(w.cto.id), goal: "Ship it", itemKeys: [item.key])
        await w.refresh()
        #expect(sprint.status == .pendingApproval)
        #expect(w.model.work.openSprints.map(\.id) == [sprint.id])
        #expect(w.model.sprintLine?.contains("awaiting approval") == true)
    }

    @Test func itemFormValidation() {
        var form = ItemForm()
        #expect(form.validate() == "Title is required")
        form.title = "  Fix login  "
        #expect(form.validate() == nil)
        #expect(form.trimmedTitle == "Fix login")
        form.priority = 9
        #expect(form.validate() == "Priority must be between P0 (most urgent) and P4")
        form.priority = 1
        form.title = String(repeating: "x", count: 201)
        #expect(form.validate()?.hasPrefix("Title is longer") == true)
        form.title = "ok"
        form.checkCommand = "swift test"
        form.checkTimeoutSeconds = 0
        #expect(form.validate() == "The check timeout must be between 1 and 3600 seconds")
        form.checkTimeoutSeconds = 60
        #expect(form.checkSpec?.command == "swift test")
        form.assignee = "@nobody"
        #expect(form.validate(knownHandles: ["eng-1"]) == "@nobody isn't in this company")
        form.assignee = "@Eng-1"; form.reviewer = "eng-1"
        #expect(form.validate(knownHandles: ["eng-1"]) == "The assignee can't also review the item")
        form.reviewer = ""; form.touchPaths = "/etc/passwd"
        #expect(form.validate(knownHandles: ["eng-1"]) == "Path /etc/passwd must be relative to the repository")
        form.touchPaths = "src/**\n../x"
        #expect(form.validate(knownHandles: ["eng-1"]) == "Path ../x must not contain ..")
        form.touchPaths = "src/**\n\n docs/* "
        #expect(form.touchPathList == ["src/**", "docs/*"])
        #expect(form.validate(knownHandles: ["eng-1"]) == nil)
    }

    @Test func blockerWorkItemText() {
        #expect(BlockerText.describe(.workItem(id: "i1", key: "ACME-3"), handles: [:]) == "Waiting on ACME-3")
    }

    @Test func paceText() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func info(_ util: Double) -> RateLimitInfo {
            RateLimitInfo(status: "allowed", resetsAt: nil, rateLimitType: nil, isUsingOverage: false, fiveHourUtilization: nil,
                          sevenDayUtilization: util, observedAt: now, sevenDayResetsAt: now.addingTimeInterval(3.5 * 86_400))
        }
        #expect(UsageText.pace(nil) == nil)
        #expect(UsageText.pace(UsageGate.pace(info(0.05), reserve: 0.3, now: now)) == "7D on pace")
        let ahead = UsageText.pace(UsageGate.pace(info(0.60), reserve: 0.3, now: now))
        #expect(ahead?.hasPrefix("7D ahead by ") == true && ahead?.hasSuffix("%") == true)
    }

    @Test func holdBannerCopy() throws {
        func hold(_ r: HoldReason, _ detail: String = "") -> EngineHold {
            try! JSONDecoder().decode(EngineHold.self, from: Data(
                #"{"id":1,"reason":"\#(r.rawValue)","detail":"\#(detail)","since":0}"#.utf8))
        }
        #expect(HoldText.banner(hold(.network)) == "Offline — Brahma paused all agents and will resume when the connection returns.")
        #expect(HoldText.banner(hold(.account))
                == "Claude Code is logged out or the plan changed. Log in with claude in Terminal, then press Retry.")
        #expect(HoldText.banner(hold(.cli, "2.1.310 → 2.1.311"))
                == "Claude Code changed (2.1.310 → 2.1.311). Brahma is checking it before scheduling again.")
        #expect(HoldText.banner(hold(.disk, "3.2 GB free")) == "Disk space is low (3.2 GB free). Brahma resumes at 6 GB free.")
        #expect(HoldText.canRetry(hold(.account)) && HoldText.canRetry(hold(.cli)))
        #expect(!HoldText.canRetry(hold(.network)) && !HoldText.canRetry(hold(.disk)))
    }

    @Test func intensityChipAndUnconfirmedLabel() async throws {
        let w = try await WorkWorld.make()
        var item = try w.item("Agent-authored")
        let auto = ItemRows.row(item, handles: [:], run: nil)
        #expect(auto.intensityChip == nil && auto.unconfirmedNote == nil)
        item.intensity = .thorough
        item.tier = .l
        item.specConfirmedBy = nil
        let row = ItemRows.row(item, handles: [:], run: nil)
        #expect(row.intensityChip == "Thorough (unconfirmed)")
        #expect(row.unconfirmedNote == "unconfirmed: runs as M until a manager confirms")
        item.specConfirmedBy = "owner:owner"
        #expect(ItemRows.row(item, handles: [:], run: nil).intensityChip == "Thorough")
        #expect(ItemRows.row(item, handles: [:], run: nil).unconfirmedNote == nil)
    }

    @Test func modeChipOnRunningAgentAndBreakdownLine() async throws {
        #expect(ModeBreakdown.line([:]) == nil)
        #expect(ModeBreakdown.line(["standard": 41, "quick": 3, "deep": 38, "plan": 4, "ultra": 14])
                == "This week by mode: Quick 3% · Standard 41% · Deep 38% · Plan 4% · Ultra 14%")
        let w = try await WorkWorld.make()
        _ = try w.store.transition(agentId: w.eng.id, to: .ready)
        let turn = try w.store.startTurn(agentId: w.eng.id)
        try await w.store.writer.write { db in
            try db.execute(sql: "UPDATE turn SET mode = 'deep', rung = 2, effort = 'high' WHERE id = ?", arguments: [turn.id])
        }
        _ = try w.store.transition(agentId: w.eng.id, to: .running)
        await w.refresh()
        #expect(w.model.detail(agentId: w.eng.id)?.modeChip == "Deep R2 · high")
        #expect(w.model.detail(agentId: w.eng2.id)?.modeChip == nil)
    }
}
