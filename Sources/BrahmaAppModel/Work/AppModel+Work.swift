import Foundation
import BrahmaCore

public enum ModeBreakdown {
    /// "This week by mode: Quick 3% · Standard 41% · Deep 38% · Plan 4% · Ultra 14%": each mode's share of the week's spend.
    public static func line(_ costByMode: [String: Double]) -> String? {
        let total = costByMode.values.reduce(0, +)
        guard total > 0 else { return nil }
        let parts = WorkMode.allCases.compactMap { mode -> String? in
            guard let cost = costByMode[mode.rawValue], cost > 0 else { return nil }
            return "\(mode.title) \(Int((cost / total * 100).rounded()))%"
        }
        return parts.isEmpty ? nil : "This week by mode: " + parts.joined(separator: " · ")
    }
}

extension AppModel {
    // MARK: Reads

    public var work: WorkSnapshot { snapshot.work }

    /// Asks waiting for the owner in the selected company.
    public var inboxCount: Int { work.inbox.count }

    public var backlogRows: [ItemRow] {
        ItemRows.backlog(items: work.items, handles: handles, runs: work.latestRuns, sprints: work.openSprints,
                         includeDone: showDoneItems)
    }

    public var boardColumns: [BoardColumn] {
        BoardColumns.make(items: work.items, handles: handles, runs: work.latestRuns, sprints: work.openSprints, sprintId: boardSprintId)
    }

    public var inboxRows: [InboxRow] { InboxRows.make(work, handles: handles) }

    /// One line per open sprint (pending approval, active or in review).
    public var sprintLines: [String] { work.openSprints.map { SprintText.line($0, items: work.items) } }

    public var sprintLine: String? { sprintLines.first }

    /// "7D on pace" / "7D ahead by 12%".
    public var paceLine: String? { UsageText.pace(work.pace) }

    /// Why nothing is running; nil while anything runs.
    public var stallLine: String? { work.stall.running == 0 ? work.stall.reasons.first : nil }

    public var holdBanner: String? { work.hold.map(HoldText.banner) }

    public var canRetryEngine: Bool { work.hold.map(HoldText.canRetry) ?? false }

    public var autonomy: AutonomyPreset { selectedCompany?.company.autonomy ?? .important }

    public var pack: IndustryPack? { selectedCompany.flatMap { store.catalog.pack($0.company.packId) } }

    /// The plan-tier confirmation alert, when the CLI reports another plan than the configured one.
    public var planMismatchAlert: String? { work.planMismatch }

    public var modeBreakdownLine: String? { ModeBreakdown.line(work.costByMode) }

    public func item(key: String) -> WorkItem? {
        let k = key.uppercased()
        return work.items.first { $0.key == k }
    }

    public var selectedItem: WorkItem? { selectedItemKey.flatMap(item(key:)) }

    /// The ask's document, rendered safely, or nil when the ask names none.
    public func document(for row: InboxRow) -> Result<AttributedString, SafeMarkdownError>? {
        guard let path = row.documentPath else { return nil }
        return SafeMarkdown.load(documentPath: path, workspace: work.workspace)
    }

    /// The org the new-company form would create, with the seat budget of the owner's plan tier.
    public func orgPreview(_ form: CompanyForm) -> OrgPreview? {
        form.preview(catalog: store.catalog, seatBudget: store.seatBudget())
    }

    // MARK: Items

    @discardableResult
    public func createItem(_ form: ItemForm) async -> WorkItem? {
        if let message = form.validate(knownHandles: Set(snapshot.agents.map(\.name))) { errorMessage = message; return nil }
        guard let companyId = selectedCompanyId else { errorMessage = "Select a company first"; return nil }
        let item = await ownerWrite("create the item") { store in
            var draft = WorkItemDraft(type: WorkItemType(form.type.trimmingCharacters(in: .whitespaces)), title: form.trimmedTitle,
                                      description: form.description, acceptanceCriteria: form.acceptanceCriteria,
                                      checkSpec: form.checkSpec, priority: form.priority, tier: form.tier,
                                      status: form.startReady ? .ready : .backlog, intensity: form.intensity,
                                      touchPaths: form.touchPathList)
            draft.ownerId = try Self.agentId(store, companyId, form.assignee)
            draft.reviewerId = try Self.agentId(store, companyId, form.reviewer)
            if let key = Self.key(form.parentKey) {
                guard let parent = try store.workItem(companyId: companyId, key: key) else { throw WorkError.notFound("no item \(key)") }
                draft.parentId = parent.id
            }
            return try store.createWorkItem(companyId: companyId, by: .owner, draft: draft)
        }
        if let item { selectedItemKey = item.key }
        return item
    }

    @discardableResult
    public func updateItem(key: String, _ form: ItemForm) async -> WorkItem? {
        if let message = form.validate(knownHandles: Set(snapshot.agents.map(\.name))) { errorMessage = message; return nil }
        guard let companyId = selectedCompanyId else { errorMessage = "Select a company first"; return nil }
        return await ownerWrite("save the item") { store in
            guard let current = try store.workItem(companyId: companyId, key: key) else { throw WorkError.notFound("no item \(key)") }
            // Only what changed goes in, so an untouched check keeps its revision.
            var patch = WorkItemPatch()
            if form.type != current.type.rawValue { patch.type = WorkItemType(form.type) }
            if form.trimmedTitle != current.title { patch.title = form.trimmedTitle }
            if form.description != current.description { patch.description = form.description }
            if form.acceptanceCriteria != current.acceptanceCriteria { patch.acceptanceCriteria = form.acceptanceCriteria }
            let newCheck = form.checkSpec
            if newCheck?.command != current.checkSpec?.command || newCheck?.timeoutSeconds != current.checkSpec?.timeoutSeconds {
                patch.checkSpec = .some(newCheck.map { spec in
                    var s = current.checkSpec ?? spec
                    s.command = spec.command; s.timeoutSeconds = spec.timeoutSeconds
                    return s
                })
            }
            if form.priority != current.priority { patch.priority = form.priority }
            if form.tier != current.tier { patch.tier = form.tier }
            if form.intensity != current.intensity { patch.intensity = form.intensity }
            if form.touchPathList != current.touchPaths { patch.touchPaths = form.touchPathList }
            let owner = try Self.agentId(store, companyId, form.assignee)
            if owner != current.ownerId { patch.ownerId = .some(owner) }
            let reviewer = try Self.agentId(store, companyId, form.reviewer)
            if reviewer != current.reviewerId { patch.reviewerId = .some(reviewer) }
            return try store.updateWorkItem(id: current.id, by: .owner, patch: patch)
        }
    }

    /// The owner can move an item between Backlog, Ready and Blocked; In review and Done are written only by the engine.
    @discardableResult
    public func moveItem(key: String, to status: WorkItemStatus, reason: String = "blocked by the owner") async -> WorkItem? {
        guard let companyId = selectedCompanyId else { return nil }
        return await ownerWrite("move the item") { store in
            guard let item = try store.workItem(companyId: companyId, key: key) else { throw WorkError.notFound("no item \(key)") }
            return try store.updateWorkItem(id: item.id, by: .owner,
                                            patch: WorkItemPatch(status: status, blockedReason: status == .blocked ? reason : nil))
        }
    }

    @discardableResult
    public func setPriority(key: String, _ priority: Int) async -> WorkItem? {
        guard let companyId = selectedCompanyId else { return nil }
        return await ownerWrite("set the priority") { store in
            guard let item = try store.workItem(companyId: companyId, key: key) else { throw WorkError.notFound("no item \(key)") }
            return try store.updateWorkItem(id: item.id, by: .owner, patch: WorkItemPatch(priority: priority))
        }
    }

    @discardableResult
    public func setIntensity(key: String, _ intensity: WorkIntensity) async -> WorkItem? {
        guard let companyId = selectedCompanyId else { return nil }
        return await ownerWrite("set the intensity") { store in
            guard let item = try store.workItem(companyId: companyId, key: key) else { throw WorkError.notFound("no item \(key)") }
            return try store.updateWorkItem(id: item.id, by: .owner, patch: WorkItemPatch(intensity: intensity))
        }
    }

    // MARK: Inbox (owner decisions: only these Store paths)

    @discardableResult
    public func decide(askId: String, approve: Bool, note: String = "", acknowledgeChange: Bool = false) async -> Ask? {
        await ownerWrite(approve ? "approve" : "reject") { store in
            try store.ownerDecide(askId: askId, approve: approve, note: note, acknowledgeChange: acknowledgeChange)
        }
    }

    @discardableResult
    public func answer(askId: String, text: String) async -> Ask? {
        await ownerWrite("send the answer") { store in try store.ownerAnswer(askId: askId, text: text) }
    }

    /// Acknowledges an FYI or an engine alert.
    @discardableResult
    public func acknowledge(askId: String) async -> Ask? {
        await ownerWrite("acknowledge") { store in try store.acknowledge(askId: askId) }
    }

    @discardableResult
    public func rescind(askId: String, note: String = "") async -> Ask? {
        await ownerWrite("take it back") { store in try store.ownerRescind(askId: askId, note: note) }
    }

    /// Sends a decision back with a new direction.
    @discardableResult
    public func replan(askId: String, text: String) async -> Ask? {
        await ownerWrite("send it back") { store in try store.ownerReplan(askId: askId, text: text) }
    }

    // MARK: Company

    public func setAutonomy(_ preset: AutonomyPreset) async {
        guard let companyId = selectedCompanyId else { return }
        // Only the autonomy column is written, so a setting changed elsewhere since the last snapshot is not overwritten.
        await ownerWrite("change autonomy") { store in try store.setAutonomy(companyId: companyId, preset) }
    }

    public func setManager(agentId: String, managerId: String?) async {
        await ownerWrite("change the reporting line") { store in try store.setManager(agentId: agentId, managerId: managerId) }
    }

    /// Runs the doctor again; a pass ends an account or CLI hold. A failure leaves the hold and says why.
    public func retryEngine() async {
        guard let engine else { errorMessage = "Brahma's engine isn't running in this window."; return }
        guard let report = await engine.recheck() else {
            errorMessage = "Brahma can't find Claude Code. Install it, then relaunch Brahma."
            return
        }
        guard report.ok else {
            let bad = report.items.first { $0.status == .fail }
            errorMessage = "Claude Code check failed: \(bad?.detail ?? "unknown"). Run brahma doctor in Terminal for details."
            return
        }
        let store = self.store
        await ownerWrite("resume the engine") { _ in
            try store.saveProbe(report)
            try store.clearHoldAfterDoctor(now: Date())
        }
    }

    // MARK: Notifications

    /// Asks waiting for the owner that no banner was shown for yet, in every company.
    public func dueNotifications() async -> [InboxNotification] {
        let store = self.store
        let names = Dictionary(snapshot.companies.map { ($0.id, $0.company.name) }, uniquingKeysWith: { a, _ in a })
        do {
            let asks = try await Task.detached { try store.unnotifiedOwnerAsks() }.value
            return InboxNotifications.due(asks).map { InboxNotifications.content(for: $0, companyName: names[$0.companyId] ?? "Brahma") }
        } catch {
            report(error)
            return []
        }
    }

    public func markNotified(_ askIds: [String]) async {
        guard !askIds.isEmpty else { return }
        let store = self.store
        do { try await Task.detached { try store.markAskNotified(ids: askIds) }.value } catch { report(error) }
    }

    // MARK: Internals

    /// Runs one owner write off the main actor, then refreshes. A refused write puts its reason in `errorMessage`.
    @discardableResult
    private func ownerWrite<T: Sendable>(_ what: String, _ body: @escaping @Sendable (Store) throws -> T) async -> T? {
        let store = self.store
        do {
            let value = try await Task.detached { try body(store) }.value
            await tick(forceSnapshot: true)
            return value
        } catch let e as WorkError {
            errorMessage = e.message
        } catch let e as OrgError {
            errorMessage = OrgErrorText.message(e)
        } catch {
            errorMessage = "Couldn't \(what): \(error)"
        }
        return nil
    }

    nonisolated private static func key(_ raw: String) -> String? {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return k.isEmpty ? nil : k
    }

    nonisolated private static func agentId(_ store: Store, _ companyId: String, _ raw: String) throws -> String? {
        guard let handle = ItemForm.handle(raw) else { return nil }
        guard let agent = try store.agent(companyId: companyId, name: handle) else { throw WorkError.notFound("no agent @\(handle)") }
        return agent.id
    }
}
