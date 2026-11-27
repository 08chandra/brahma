import Foundation

public enum RoleCards {
    public static let maxChars = 6000

    public static func path(paths: BrahmaPaths, companyId: String, handle: String) -> URL {
        paths.companyDir(companyId).appending(path: "roles/\(handle).md")
    }

    /// Front matter (id, pack, title, kind, models, tools, skills, connectors) followed by the prompt body.
    /// Playbooks are not rendered into the card file.
    public static func render(template t: RoleTemplate, company: Company, pack: IndustryPack? = nil) -> String {
        let pack = pack ?? PackCatalog.builtin.packs.first { $0.role(t.id) == t }
        let groups: [(String, [String])] = [("base", CompanyToolNames.base), ("work", CompanyToolNames.work),
                                            ("lead", CompanyToolNames.lead), ("executive", CompanyToolNames.executive)]
        let toolGroups = groups.filter { _, names in names.allSatisfy(t.companyTools.contains) }.map(\.0)
        func list(_ xs: [String]) -> String { "[" + xs.joined(separator: ", ") + "]" }
        let models = ["low", "balanced", "max"].map { "\($0): \(t.models[$0] ?? "sonnet")" }.joined(separator: ", ")
        var lines = ["---", "id: \(t.id)"]
        if let pack { lines.append("pack: \(pack.id)@\(pack.version)") }
        lines += ["title: \(t.title)", "kind: \(t.kind.rawValue)", "models: {\(models)}", "tools: \(list(toolGroups))",
                  "skills: \(list(t.skills))", "connectors: \(list(t.connectors))"]
        lines += ["---", "", "# \(t.title) at \(company.name)", "", t.prompt]
        return lines.joined(separator: "\n")
    }

    /// Returns the agent's role card, materializing it from the template when missing. The file is the
    /// owner's to edit and always wins afterwards. Truncated to `maxChars`.
    public static func load(paths: BrahmaPaths, agent: Agent, company: Company, template: RoleTemplate) throws -> String {
        let file = path(paths: paths, companyId: company.id, handle: agent.name)
        let text: String
        if FileManager.default.fileExists(atPath: file.path) {
            text = try String(contentsOf: file, encoding: .utf8)
        } else {
            text = render(template: template, company: company)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        return String(text.prefix(maxChars))
    }
}
