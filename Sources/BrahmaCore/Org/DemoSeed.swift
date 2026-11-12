import Foundation

/// Demo companies (Plan L Task 13). `live` is the goal-to-URL demo: `brahma company create <name> --demo live` and Task 15's
/// live test both start from it. It uses the real engine paths only — `createCompany`, `hire`, `setHosting`, the engine's
/// `hosting-account` filing (requester `system`, PR-28) and an owner post to #general — and never contacts a hosting provider.
public enum DemoSeed {
    public static let liveAutonomy: AutonomyPreset = .important

    /// The default goal when the caller gives none.
    public static func liveGoal(name: String) -> String {
        "A one-page waitlist site for \(name): a headline, three benefits and an email field that thanks the visitor (no backend yet)."
    }

    /// The owner's kickoff in #general.
    public static func liveKickoff(goal: String) -> String {
        "@ceo @cto Goal: \(goal). ceo: write docs/brief.md (problem, audience, the page's sections) with cto adding a short architecture "
        + "section, and propose it as kind prd. cto: meanwhile create the walking-skeleton items for @eng-1 and ask @devops-1 to set the "
        + "preview, smoke check and deploy config. When main is green, @devops-1 proposes the deploy."
    }

    /// The four hires, in order: handle, role, model (haiku for the engineer, sonnet for the rest; never opus).
    public static let liveHires: [(name: String, role: String, model: String)] = [
        ("ceo", "ceo-cpo", "sonnet"), ("cto", "cto-architect", "sonnet"), ("eng-1", "engineer", "haiku"), ("devops-1", "devops", "sonnet"),
    ]

    /// Creates the company (software pack, autonomy `important`), hires `ceo`, `cto`, `eng-1` and `devops-1` (eng and devops
    /// report to the cto, the cto to the ceo), creates the hosting row (default provider, project = the slug), files the
    /// `hosting-account` task from the engine and posts the kickoff as the owner. Returns the company and the hosting task.
    /// The pre-commit hook and the built-in extensions are written as `company create` does; a failure there is reported
    /// through `log` and the company stands.
    @discardableResult
    public static func live(store: Store, paths: BrahmaPaths, name: String, goal: String?, now: Date = Store.now(),
                            log: (String) -> Void = { _ in }) throws -> (Company, Ask) {
        let goal = goal?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? goal! : liveGoal(name: name)
        let company = try store.createCompany(name: name, goal: goal, workspacesRoot: paths.workspaces, packId: "software")
        do {
            let layout = SandboxLayout(paths: paths, company: company, agentHandle: "engine")
            try CompanyHooks.install(layout: layout, git: GitWorkspace(root: layout.workspace, exportHome: paths.home))
        } catch { log("could not install the pre-commit hook: \(error)") }
        do { try BuiltinExtensions.materialize(workspace: URL(fileURLWithPath: company.workspacePath, isDirectory: true)) } catch {
            log("could not write the built-in extensions: \(error)")
        }
        try store.setAutonomy(companyId: company.id, liveAutonomy)
        var managers: [String: String] = [:]
        for hire in liveHires {
            let manager: String? = switch hire.name {
            case "ceo": nil
            case "cto": managers["ceo"]
            default: managers["cto"]
            }
            let agent = try store.hire(companyId: company.id, name: hire.name, role: hire.role, model: hire.model, managerId: manager)
            managers[hire.name] = agent.id
        }
        try store.setHosting(companyId: company.id, by: .owner, project: company.slug, now: now)
        let at = max(now, company.createdAt)
        let task = try store.fileTemplateTask(companyId: company.id, requesterId: "system", template: .hostingAccount, now: at)
        _ = try MessageRouter(store: store).post(companyId: company.id, channel: "general", from: .owner, text: liveKickoff(goal: goal), now: at)
        return (company, task)
    }
}
