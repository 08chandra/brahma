import Testing
import Foundation
@testable import BrahmaCore

@Suite(.scratch) struct WorkPolicyTests {
    // Actors: the assignee, the author, the reviewer, a manager and a stranger. "owner" and "system" are privileged.
    private func item(status: WorkItemStatus = .ready, check: CheckSpec? = nil) -> WorkItem {
        WorkItem(id: "i1", companyId: "c1", number: 1, key: "ACME-1", type: .task, title: "t", checkSpec: check, status: status,
                 authorId: "author", ownerId: "assignee", reviewerId: "reviewer", createdAt: Date(), updatedAt: Date())
    }

    private func can(_ field: WorkField, _ actor: String, _ kind: RoleKind = .individual, holder: String? = nil,
                     item i: WorkItem? = nil) -> Bool {
        WorkPolicy.canEdit(field, item: i ?? item(), actor: actor, actorKind: kind, leaseHolderId: holder)
    }

    @Test func ownerAndSystemEditEveryField() {
        for f in WorkField.allCases {
            #expect(can(f, "owner")); #expect(can(f, "system"))
        }
    }

    @Test func specFieldsAreForAuthorReviewerAndManagers() {
        #expect(can(.spec, "author")); #expect(can(.spec, "reviewer"))
        #expect(can(.spec, "boss", .manager)); #expect(can(.spec, "boss", .executive))
        #expect(!can(.spec, "stranger")); #expect(!can(.spec, "architect", .architect))
        #expect(!can(.spec, "assignee")); #expect(!can(.spec, "assignee", .manager), "a manager who is the assignee is still the assignee")
        #expect(WorkPolicy.denial(.spec, item: item(), actor: "stranger", actorKind: .individual, leaseHolderId: nil)
                == "only the item's author, reviewer, a manager or the owner can change its spec")
        #expect(WorkPolicy.denial(.spec, item: item(), actor: "assignee", actorKind: .individual, leaseHolderId: nil)
                == "the assignee cannot change an item's spec, acceptance criteria or check")
    }

    @Test func assigneeCannotEditCheckEvenIfAuthor() {
        var i = item(check: CheckSpec(command: "make test"))
        i.authorId = "assignee"
        #expect(!can(.spec, "assignee", item: i))
        #expect(WorkPolicy.denial(.spec, item: i, actor: "assignee", actorKind: .individual, leaseHolderId: nil)
                == "the assignee cannot change an item's spec, acceptance criteria or check")
    }

    @Test func assigningIsForManagersAndTheOwner() {
        #expect(can(.assignee, "boss", .manager)); #expect(can(.assignee, "boss", .executive))
        #expect(!can(.assignee, "author")); #expect(!can(.assignee, "assignee")); #expect(!can(.assignee, "reviewer"))
    }

    @Test func notesBranchAndStatusAreForAssigneeHolderAndManagers() {
        for f in [WorkField.notes, .linkedBranch, .status] {
            #expect(can(f, "assignee")); #expect(can(f, "holder", holder: "holder"))
            #expect(can(f, "boss", .manager)); #expect(can(f, "boss", .executive))
            #expect(!can(f, "author")); #expect(!can(f, "reviewer")); #expect(!can(f, "stranger"))
            #expect(!can(f, "holder"), "holder only counts when it holds the lease")
        }
    }

    @Test func intensityIsForManagersAtMostThoroughAndOwnerForUltra() {
        #expect(can(.intensity, "boss", .manager)); #expect(!can(.intensity, "assignee"))
        #expect(WorkPolicy.intensityDenial(.thorough, actor: "boss", actorKind: .manager) == nil)
        #expect(WorkPolicy.intensityDenial(.ultra, actor: "boss", actorKind: .executive) == "only the owner can set ultra intensity")
        #expect(WorkPolicy.intensityDenial(.ultra, actor: "owner", actorKind: .executive) == nil)
        #expect(WorkPolicy.intensityDenial(.thorough, actor: "assignee", actorKind: .individual) != nil)
    }

    private func status(_ from: WorkItemStatus, _ to: WorkItemStatus, actor: String = "assignee", _ kind: RoleKind = .individual,
                        assignee: Bool = true, lease: Bool = false, reason: String? = nil) -> WorkError? {
        WorkPolicy.statusDenial(from: from, to: to, actor: actor, actorKind: kind, isHolderOrAssignee: assignee, hasLease: lease,
                                blockedReason: reason)
    }

    @Test func statusTable() {
        #expect(status(.backlog, .ready) == nil); #expect(status(.ready, .backlog) == nil)
        for from in [WorkItemStatus.backlog, .ready, .inProgress, .inReview] {
            #expect(status(from, .blocked, reason: "waiting on api") == nil)
            #expect(status(from, .blocked) == .invalid("a blocked item needs a reason"))
            #expect(status(from, .blocked, reason: "  ") == .invalid("a blocked item needs a reason"))
        }
        #expect(status(.blocked, .ready) == nil)
        #expect(status(.blocked, .inProgress, lease: true) == nil)
        #expect(status(.blocked, .inProgress, lease: false) != nil)
        #expect(status(.inProgress, .ready) == nil)
        // Not in the table.
        #expect(status(.ready, .inProgress) == .invalid("illegal status change ready → inProgress"))
        #expect(status(.backlog, .inProgress) == .invalid("illegal status change backlog → inProgress"))
        #expect(status(.inProgress, .backlog) == .invalid("illegal status change inProgress → backlog"))
        #expect(status(.inReview, .ready) == .invalid("illegal status change inReview → ready"))
        #expect(status(.done, .blocked, reason: "x") == .invalid("illegal status change done → blocked"))
    }

    @Test func engineStatusesRefused() {
        for to in [WorkItemStatus.inReview, .done] {
            for actor in ["assignee", "owner", "system"] {
                #expect(status(.inProgress, to, actor: actor) == .invalid("status \(to.rawValue) is set by the engine"))
            }
            #expect(status(.inProgress, to, actor: "boss", .manager) == .invalid("status \(to.rawValue) is set by the engine"))
        }
    }

    @Test func reopenIsForManagersAndTheOwner() {
        #expect(status(.done, .ready, actor: "assignee") != nil)
        #expect(status(.done, .ready, actor: "boss", .manager, assignee: false) == nil)
        #expect(status(.done, .ready, actor: "boss", .executive, assignee: false) == nil)
        #expect(status(.done, .ready, actor: "owner", assignee: false) == nil)
        #expect(status(.done, .ready, actor: "system", assignee: false) == nil)
    }

    @Test func statusNeedsAssigneeHolderOrManager() {
        #expect(status(.ready, .backlog, actor: "stranger", assignee: false) != nil)
        #expect(status(.ready, .backlog, actor: "boss", .manager, assignee: false) == nil)
        #expect(status(.ready, .backlog, actor: "owner", assignee: false) == nil)
        #expect(WorkPolicy.canSetStatus(from: .ready, to: .backlog, actor: "stranger", actorKind: .individual,
                                        isHolderOrAssignee: false, hasLease: false, blockedReason: nil) == false)
    }

    @Test func checkSpecRules() throws {
        try CheckSpec(command: "make test").validate()
        #expect(throws: WorkError.self) { try CheckSpec(command: "   ").validate() }
        #expect(throws: WorkError.self) { try CheckSpec(command: String(repeating: "x", count: 2001)).validate() }
        try CheckSpec(command: String(repeating: "x", count: 2000)).validate()
        #expect(throws: WorkError.self) { try CheckSpec(command: "x", timeoutSeconds: 0).validate() }
        #expect(throws: WorkError.self) { try CheckSpec(command: "x", timeoutSeconds: 3601).validate() }
        try CheckSpec(command: "x", timeoutSeconds: 3600).validate()
        #expect(throws: WorkError.self) { try CheckSpec(command: "x", timeoutSeconds: 7200, maxTimeout: 9000).validate() }
        for bad in ["", "/etc/passwd", "../x", "a/../b", ".."] {
            #expect(throws: WorkError.self) { try CheckSpec(command: "x", paths: [bad]).validate() }
        }
        try CheckSpec(command: "x", paths: ["Sources/App", "Tests/**"]).validate()
        #expect(throws: WorkError.self) { try CheckSpec(command: "x", paths: Array(repeating: "a", count: 51)).validate() }
        try CheckSpec(command: "x", paths: Array(repeating: "a", count: 50)).validate()
    }

    @Test func riskTagsAreDerived() {
        var i = item()
        #expect(WorkPolicy.riskTags(i).isEmpty)
        i.checkSpec = CheckSpec(command: "x", paths: ["Package.swift", ".github/workflows/ci.yml", "db/migrations/001.sql"])
        #expect(WorkPolicy.riskTags(i) == ["hotPath", "sensitivePath", "migration"])
        i.checkSpec = CheckSpec(command: "x", paths: ["Sources/App/Feature.swift"])
        i.reviewFlags = ["modified-test"]; i.title = "Fix XSS in the comment box"
        #expect(WorkPolicy.riskTags(i) == ["flagged", "securityLabel"])
    }

    @Test func notifyTableWakesOnlyActionableEvents() {
        typealias W = WakePolicy
        #expect(W.noticeWakes(kind: .verificationPassed, recipientRole: .reviewer))
        #expect(!W.noticeWakes(kind: .verificationPassed, recipientRole: .owner))
        #expect(!W.noticeWakes(kind: .verificationPassed, recipientRole: .author))
        for k in [WorkEventKind.changesRequested, .verificationFailed, .mergeConflict, .mergeFailed, .humanTaskDone, .humanTaskDeclined] {
            #expect(W.noticeWakes(kind: k, recipientRole: .owner)); #expect(W.noticeWakes(kind: k, recipientRole: .holder))
            #expect(!W.noticeWakes(kind: k, recipientRole: .reviewer)); #expect(!W.noticeWakes(kind: k, recipientRole: .author))
        }
        #expect(W.noticeWakes(kind: .dependencyDone, recipientRole: .waiter))
        #expect(!W.noticeWakes(kind: .dependencyDone, recipientRole: .owner))
        #expect(W.noticeWakes(kind: .commented, recipientRole: .mentioned)); #expect(!W.noticeWakes(kind: .commented, recipientRole: .owner))
        let waking: Set<WorkEventKind> = [.verificationPassed, .changesRequested, .verificationFailed, .mergeConflict, .mergeFailed, .dependencyDone, .commented,
                                          .humanTaskDone, .humanTaskDeclined]
        let roles: [NoticeRecipientRole] = [.owner, .reviewer, .author, .holder, .waiter, .mentioned, .other]
        for k in WorkEventKind.allCases where !waking.contains(k) {
            for r in roles { #expect(!W.noticeWakes(kind: k, recipientRole: r), "\(k) must never wake (\(r))") }
        }
        #expect(!W.noticeWakes(kind: .leaseClaimed, recipientRole: .owner)); #expect(!W.noticeWakes(kind: .merged, recipientRole: .owner))
    }

    @Test func eventKindsAndProgressSet() {
        #expect(WorkEventKind.progress == [.created, .statusChanged, .edited, .checkEdited, .assigned, .dependencyAdded, .leaseClaimed,
                                           .submitted, .reviewApproved, .changesRequested, .handoffWritten])
        for k in ["planWritten", "planTurnWrote", "modeEscalated", "specConfirmed"] { #expect(WorkEventKind(rawValue: k) != nil) }
        #expect(WorkItemStatus.allCases.map(\.title) == ["Backlog", "Ready", "In progress", "In review", "Done", "Blocked"])
        #expect(EffortTier.allCases.map(\.label) == ["S", "M", "L"])
    }
}
