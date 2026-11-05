import Foundation
import GRDB

/// Human tasks (Plan L Task 9): `humanTask` asks the owner does by hand (an account, a domain, test keys, a launch post),
/// with engine-written links, steps and paste-back fields. Always the owner's (filed `viaOwner`, never routed to an internal
/// approver nor decided by a preset); answered only by `completeHumanTask` (secrets to the vault) or `declineHumanTask`, never
/// by `ownerDecide`. A linked item is blocked on the task (5-lite's `blockedAskId`/`blockedAskBy`, PR-30) and restored when it
/// settles.
extension Store {
    /// What `request_human_task` answers.
    public static func requestedHumanTaskText(_ ask: Ask) -> String {
        "Requested \(ask.ref) (\(ask.title)). The owner will do it; you'll get a notice when it's done."
    }

    public static func alreadyRequestedText(_ ask: Ask) -> String { "Already requested as \(ask.ref)." }

    /// The requester's @system DM when the owner did the task: refs only.
    public static func humanTaskDoneDM(_ ask: Ask, itemKey: String?) -> String {
        itemKey.map { "\(ask.ref) is done (\($0)). See the Inbox." } ?? "\(ask.ref) is done. See the Inbox."
    }

    static func humanTaskConflict(_ ask: Ask) -> WorkError {
        .conflict("\(ask.ref) is a human task; mark it done or decline it")
    }

    // MARK: Filing

    /// An agent's `request_human_task`: a template (`args` for its arguments) or a custom task (`title`, `steps`, `links`,
    /// `fields`, which must be url fields). Every piece of agent text is redacted before the task is built. The requester
    /// must be an active agent of the company and `itemId` an item of it (`forbidden("not in your company")`). Deduped on a
    /// pending human task of the company with the same template (custom: the same title), inside the write that files it;
    /// `AskQuota` applies in that write (`propose`). An item the requester holds or is assigned is blocked on the task.
    @discardableResult
    public func requestHumanTask(companyId: String, by agentId: String, template: HumanTaskTemplate?, args: [String: String] = [:],
                                 title: String? = nil, steps: [String] = [], links: [HumanTaskLink] = [], fields: [HumanTaskField] = [],
                                 itemId: String? = nil, reason: String?, now: Date = Store.now()) throws -> (ask: Ask, deduped: Bool) {
        let args = try args.mapValues { try redact($0) }
        let title = try redact(title)
        let steps = try steps.map { try redact($0) }
        let links = try links.map { HumanTaskLink(title: try redact($0.title), url: try redact($0.url)) }
        let fields = try fields.map { f -> HumanTaskField in var f = f; f.label = try redact(f.label); return f }
        let reason = try redact(reason)
        if template != nil, title != nil || !steps.isEmpty || !links.isEmpty || !fields.isEmpty {
            throw WorkError.invalid("a template task takes only args, item and reason")
        }
        let custom: HumanTask? = try template == nil
            ? HumanTasks.custom(title: title ?? "", steps: steps, links: links, fields: fields) : nil
        return try writer.write { db in
            // No reason (a tainted session's call): the template's own.
            let why = try reason ?? template.map {
                HumanTasks.defaultReason($0, provider: try HostingSettings.fetchOne(db, key: companyId)?.provider ?? .default)
            } ?? custom?.title ?? ""
            return try fileHumanTask(db, companyId: companyId, requester: .agent(agentId), build: { company, hosting in
                if let custom { return custom }
                return try HumanTasks.render(template!, company: company, hosting: hosting, args: args)
            }, reason: why, itemId: itemId, now: now)
        }
    }

    /// The engine files a template task (`requesterId` "system", PR-28: no quota is charged; or an agent's id), deduped on a
    /// pending human task of the same template inside the write that files it. `reason` defaults to the template's.
    @discardableResult
    public func fileTemplateTask(companyId: String, requesterId: String, template: HumanTaskTemplate, args: [String: String] = [:],
                                 itemId: String? = nil, reason: String? = nil, now: Date = Store.now()) throws -> Ask {
        let sender: Sender = requesterId == "system" ? .system : .agent(requesterId)
        return try writer.write { db in
            try fileHumanTask(db, companyId: companyId, requester: sender, build: { company, hosting in
                try HumanTasks.render(template, company: company, hosting: hosting, args: args)
            }, reason: reason ?? HumanTasks.defaultReason(template, provider: try HostingSettings.fetchOne(db, key: companyId)?.provider ?? .default),
               itemId: itemId, now: now).ask
        }
    }

    private func fileHumanTask(_ db: Database, companyId: String, requester sender: Sender,
                               build: (Company, HostingSettings?) throws -> HumanTask, reason: String, itemId: String?,
                               now: Date) throws -> (ask: Ask, deduped: Bool) {
        let company = try requireCompany(db, companyId)
        let requesterId: String
        switch sender {
        case .system: requesterId = "system"
        case .agent(let id):
            guard let agent = try Agent.fetchOne(db, key: id), agent.companyId == companyId else {
                throw WorkError.forbidden("not in your company")
            }
            guard agent.state != .killed else { throw WorkError.forbidden("this agent is not active in the company") }
            requesterId = id
        case .owner: throw WorkError.invalid("the owner does not file asks")
        }
        var item: WorkItem?
        if let itemId {
            guard let found = try WorkItem.fetchOne(db, key: itemId) else { throw WorkError.notFound("no such work item") }
            guard found.companyId == companyId else { throw WorkError.forbidden("not in your company") }
            item = found
        }
        let task = try build(company, try HostingSettings.fetchOne(db, key: companyId))
        // Dedupe inside this write (Task 6 minor): the same template, or a custom task of the same title.
        let open = try Ask.filter(Column("companyId") == companyId && Column("kind") == AskKind.humanTask
                                  && [AskStatus.pendingInternal.rawValue, AskStatus.pendingOwner.rawValue].contains(Column("status")))
            .order(Column("number")).fetchAll(db)
        let same = open.first { ask in
            guard let existing = HumanTask.from(ask) else { return false }
            if let t = task.template { return existing.template == t }
            return existing.template == nil && existing.title.lowercased() == task.title.lowercased()
        }
        let ask: Ask
        if let same {
            ask = same
        } else {
            let reasonText = Store.flat(reason, max: Store.maxAskField)
            ask = try propose(db: db, companyId: companyId, by: sender, kind: .humanTask, risk: .low, category: nil, title: task.title,
                              summary: reasonText.isEmpty ? task.title : reasonText, payload: AskPayload(details: try task.json()),
                              document: nil, itemId: item?.id, subjectId: nil, supersedes: nil, requestId: nil, decisionClass: .taste,
                              viaOwner: true, now: now)
        }
        if let item { try blockOnHumanTask(db, item: item, ask: ask, requesterId: requesterId, now: now) }
        return (ask, same != nil)
    }

    /// Blocks `item` on the task when the requester holds it or is its assignee (the engine may block any item of the
    /// company), and the item is in backlog, ready or in progress. The lease stays; the status to restore is recorded.
    private func blockOnHumanTask(_ db: Database, item: WorkItem, ask: Ask, requesterId: String, now: Date) throws {
        guard [.backlog, .ready, .inProgress].contains(item.status) else { return }
        if requesterId != "system" {
            let holder = try Self.leaseHolderId(db: db, itemId: item.id)
            guard holder == requesterId || item.ownerId == requesterId else { return }
        }
        var item = item
        let from = item.status
        item.statusBeforeBlock = from
        item.status = .blocked
        item.blockedReason = String("waiting on \(ask.ref) (human task: \(ask.title))".prefix(500))
        item.blockedSinceActive = try Self.activeNow(db: db, companyId: item.companyId)
        item.blockedAskId = ask.id
        item.blockedAskBy = requesterId
        item.updatedAt = now
        try item.update(db)
        try recordItemEvent(db: db, item: item, actor: requesterId, kind: .statusChanged,
                            text: "\(from.title) → \(WorkItemStatus.blocked.title): waiting on \(ask.ref) (human task)", now: now)
    }

    // MARK: The owner's answer

    /// The owner did the task: every field's value is trimmed and checked (required, prefix, pattern, https for url fields;
    /// a live Stripe key is refused), secrets go to the vault (`secretEngine` engine-held, `secretTest` a test key) and are
    /// recorded only as `"<NAME>": "saved"`; text and url values are the ask's answer (JSON, redacted). The template's effect
    /// (`hosting-account` → the account ID, `domain` → the custom domain), the answer and the item restore are one write;
    /// the vault is written last in it, and put back if the write fails. Owner only: the CLI's `task done` (owner shell) and
    /// the app call it; no agent path does.
    @discardableResult
    public func completeHumanTask(companyId: String, askId: String, values raw: [String: String], vault: any SecretVault,
                                  now: Date = Store.now()) throws -> Ask {
        guard let seen = try ask(id: askId), seen.companyId == companyId else { throw WorkError.notFound("no such ask") }
        guard seen.kind == .humanTask, let task = HumanTask.from(seen) else { throw WorkError.invalid("\(seen.ref) is not a human task") }
        guard seen.status.isPending else { throw WorkError.conflict("\(seen.ref) is already \(seen.status.rawValue)") }
        let values = try Self.checkedValues(task, raw)
        let secrets = task.fields.filter { $0.isSecret && values[$0.name] != nil }
        for f in secrets {
            do { try validateSecret(companyId: companyId, name: f.name, value: values[f.name]!, isTest: f.kind == .secretTest) }
            catch let e as SecretError { throw WorkError.invalid(e.message) }
            // Read once outside the write: a vault that prompts does so here, not while the database write is held.
            _ = try vault.value(companyId: companyId, name: f.name)
        }
        var answer: [String: String] = [:]
        for f in task.fields { if let v = values[f.name] { answer[f.name] = f.isSecret ? "saved" : v } }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let answerJSON = try redact(String(decoding: try encoder.encode(answer), as: UTF8.self))

        var priors: [(name: String, value: String?)] = []
        do {
            return try writer.write { db in
                guard var ask = try Ask.fetchOne(db, key: askId), ask.status.isPending else {
                    throw WorkError.conflict("\(seen.ref) is already \((try Ask.fetchOne(db, key: askId))?.status.rawValue ?? "gone")")
                }
                for f in secrets { try upsertSecretMeta(db, companyId: companyId, name: f.name, isTest: f.kind == .secretTest, now: now) }
                try applyTemplateEffects(db, task: task, values: values, companyId: companyId, now: now)
                ask.ownerAnswer = answerJSON
                ask.ownerDecidedAt = now
                try settle(db, ask: &ask, status: .answered, decidedBy: "owner", tellRequesterToo: false, now: now)
                // An @system DM carries refs only (no agent title, no owner-entered value): the answer stays on the ask.
                let key = try ask.itemId.flatMap { try WorkItem.fetchOne(db, key: $0)?.key }
                try tellRequester(db, ask, text: Self.humanTaskDoneDM(ask, itemKey: key), now: now)
                // The vault last: only the completion that won the pending -> answered transition writes it.
                for f in secrets {
                    priors.append((f.name, try vault.value(companyId: companyId, name: f.name)))
                    try vault.set(companyId: companyId, name: f.name, value: values[f.name]!)
                }
                return ask
            }
        } catch {
            for p in priors.reversed() {
                if let v = p.value { try? vault.set(companyId: companyId, name: p.name, value: v) }
                else { try? vault.delete(companyId: companyId, name: p.name) }
            }
            throw error
        }
    }

    /// The owner declines the task: `rejected` with the note; the linked item is restored and told (`humanTaskDeclined`).
    @discardableResult
    public func declineHumanTask(companyId: String, askId: String, note: String, now: Date = Store.now()) throws -> Ask {
        try writer.write { db in
            guard var ask = try Ask.fetchOne(db, key: askId), ask.companyId == companyId else { throw WorkError.notFound("no such ask") }
            guard ask.kind == .humanTask else { throw WorkError.invalid("\(ask.ref) is not a human task") }
            guard ask.status.isPending else { throw WorkError.conflict("\(ask.ref) is already \(ask.status.rawValue)") }
            ask.ownerNote = Store.flat(try redact(note), max: Store.maxAskField)
            ask.ownerDecidedAt = now
            try settle(db, ask: &ask, status: .rejected, decidedBy: "owner", now: now)
            return ask
        }
    }

    /// The values to save, trimmed, by field name (empty optional fields left out). Throws the first rule broken.
    static func checkedValues(_ task: HumanTask, _ raw: [String: String]) throws -> [String: String] {
        let names = Set(task.fields.map(\.name))
        if let unknown = raw.keys.sorted().first(where: { !names.contains($0) }) {
            throw WorkError.invalid("\(Store.flat(unknown, max: 64)) is not a field of this task")
        }
        var out: [String: String] = [:]
        for f in task.fields {
            let v = (raw[f.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty {
                if f.required { throw WorkError.invalid("\(f.label) is required") }
                continue
            }
            if v.hasPrefix("sk_live_") || v.hasPrefix("rk_live_") { throw WorkError.invalid(HumanTaskPolicy.liveStripeMessage) }
            if let prefix = f.prefix, !v.hasPrefix(prefix) { throw WorkError.invalid("\(f.label) must start with \(prefix)") }
            // One line, no spaces or control characters inside a key, an ID or a URL.
            if v.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) {
                throw WorkError.invalid("\(f.label) doesn't look right")
            }
            if let pattern = f.pattern, !HumanTasks.matches(v, pattern: pattern) { throw WorkError.invalid("\(f.label) doesn't look right") }
            if f.kind == .url, !HumanTasks.isValidLink(v) { throw WorkError.invalid("\(f.label) must start with https://") }
            if f.kind == .text, v.count > 2048 { throw WorkError.invalid("\(f.label) doesn't look right") }
            out[f.name] = v
        }
        // A key pasted into a field that is shown to agents is refused.
        for f in task.fields where !f.isSecret {
            guard let v = out[f.name] else { continue }
            for s in task.fields where s.isSecret {
                if let secret = out[s.name], v.contains(secret) {
                    throw WorkError.invalid("\(f.label) holds the \(s.label); paste it only in its own field")
                }
            }
        }
        return out
    }

    /// `hosting-account` sets the account ID, `domain` the custom domain (the row is created as `setHosting` would).
    private func applyTemplateEffects(_ db: Database, task: HumanTask, values: [String: String], companyId: String, now: Date) throws {
        guard let template = task.template else { return }
        let update: (inout HostingSettings) throws -> Void
        switch template {
        case .hostingAccount:
            guard let id = values["account_id"] else { return }
            guard HostingSettings.isValidAccountId(id) else { throw WorkError.invalid(HostingSettings.accountIdMessage) }
            update = { $0.accountId = id }
        case .domain:
            guard let d = values["domain"] else { return }
            guard HumanTasks.isHostname(d) else { throw WorkError.invalid(HumanTaskPolicy.domainMessage) }
            update = { $0.customDomain = d }
        case .stripeTestKeys, .launchPost:
            return
        }
        let company = try requireCompany(db, companyId)
        var s = try HostingSettings.fetchOne(db, key: companyId) ?? HostingSettings(companyId: companyId, project: company.slug, updatedAt: now)
        try update(&s)
        s.updatedAt = now
        try s.validate()
        try s.save(db)
    }

    /// When a human task reaches a final status (`applyAskEffects`): every item still blocked on it goes back to the status it
    /// had (`inProgress` only while its lease exists, else `ready`), and its assignee and holder are told — `humanTaskDone`
    /// when it was done, `humanTaskDeclined` otherwise (with the owner's note).
    func applyHumanTaskEffects(_ db: Database, ask: Ask, now: Date) throws {
        guard ask.kind == .humanTask, !ask.status.isPending else { return }
        let items = try WorkItem.filter(Column("companyId") == ask.companyId && Column("blockedAskId") == ask.id
                                        && Column("status") == WorkItemStatus.blocked.rawValue).fetchAll(db)
        for var item in items {
            let holder = try Self.leaseHolderId(db: db, itemId: item.id)
            // A live lease means in progress (a claim always is); otherwise the recorded backlog or ready, else ready.
            let to: WorkItemStatus
            if holder != nil { to = .inProgress }
            else if let before = item.statusBeforeBlock, before == .backlog || before == .ready { to = before }
            else { to = .ready }
            item.status = to
            item.blockedReason = nil; item.blockedSinceActive = nil; item.blockedAskId = nil; item.blockedAskBy = nil
            item.statusBeforeBlock = nil
            if to == .inProgress { item.everStarted = true }
            item.updatedAt = now
            try item.update(db)
            let kind: WorkEventKind
            var text: String
            switch ask.status {
            case .answered:
                kind = .humanTaskDone; text = "\(ask.ref) done by the owner: \(ask.title)"
            case .rejected:
                kind = .humanTaskDeclined; text = "\(ask.ref) declined by the owner: \(ask.title)"
                if let note = ask.ownerNote, !note.isEmpty { text += " — \(note)" }
            default:
                kind = .humanTaskDeclined; text = "\(ask.ref) closed (\(ask.status.rawValue)): \(ask.title)"
            }
            try recordItemEvent(db: db, item: item, actor: ask.decidedBy == "owner" ? "owner" : "system", kind: kind,
                                text: text, alsoNotify: holder.map { [$0] } ?? [], alsoNotifyRole: .holder,
                                now: now)
        }
    }
}

/// Task 6's hook, real (PR-28): the engine files the `hosting-account` template task (requester `system`, no agent quota),
/// deduped on a pending one inside the write that files it.
public struct EngineHumanTaskFiling: HumanTaskFiling {
    public init() {}

    public func fileHostingAccount(store: Store, companyId: String, provider: HostingProviderID, now: Date) throws -> Ask {
        try store.fileTemplateTask(companyId: companyId, requesterId: "system", template: .hostingAccount,
                                   reason: HumanTasks.defaultReason(.hostingAccount, provider: provider), now: now)
    }
}
