import Foundation
import GRDB
import BrahmaCore
@testable import BrahmaAppModel

/// A loaded app model over one company "Acme" with a small team, for the work and Inbox tests.
@MainActor
struct WorkWorld {
    let model: AppModel
    let store: Store
    let paths: BrahmaPaths
    let company: Company
    let ceo: Agent, cto: Agent, eng: Agent, eng2: Agent

    static func make(autonomy: AutonomyPreset = .important) async throws -> WorkWorld {
        let (store, paths) = try makeHome()
        let company = try store.createCompany(name: "Acme", goal: "Build", workspacesRoot: paths.workspaces)
        func hire(_ n: String, _ role: String) throws -> Agent { try store.hire(companyId: company.id, name: n, role: role, model: "sonnet") }
        let ceo = try hire("ceo", "ceo"), cto = try hire("cto", "cto")
        let eng = try hire("eng-1", "engineer"), eng2 = try hire("eng-2", "engineer")
        try store.setAutonomy(companyId: company.id, autonomy, owner: .test)
        let model = AppModel(store: store, paths: paths)
        await model.load()
        return WorkWorld(model: model, store: store, paths: paths, company: company, ceo: ceo, cto: cto, eng: eng, eng2: eng2)
    }

    @discardableResult
    func item(_ title: String, type: WorkItemType = .task, priority: Int = 2, parent: WorkItem? = nil,
              status: WorkItemStatus = .backlog) throws -> WorkItem {
        try store.createWorkItem(companyId: company.id, by: .owner,
                                 draft: WorkItemDraft(type: type, title: title, priority: priority, parentId: parent?.id, status: status))
    }

    /// An ask that goes straight to the owner: the engine files it (`viaOwner`).
    @discardableResult
    func ask(_ kind: AskKind = .other, title: String = "Pick a name", category: String? = "general", risk: AskRisk? = .high,
             payload: AskPayload? = nil, by: Agent? = nil) throws -> Ask {
        try store.propose(companyId: company.id, by: .agent((by ?? eng).id), kind: kind, risk: risk, category: category, title: title,
                          summary: "why", payload: payload, viaOwner: true, quotaExempt: .devHook)
    }

    func setStatus(_ item: WorkItem, _ status: WorkItemStatus) throws {
        try store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET status = ? WHERE id = ?", arguments: [status.rawValue, item.id])
        }
    }

    func refresh() async { await model.tick(forceSnapshot: true) }

    func writeDoc(_ relative: String, _ text: String) throws {
        let url = URL(fileURLWithPath: company.workspacePath).appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
