import Foundation

public enum RoleKind: String, Codable, Sendable { case executive, architect, manager, individual }

public enum CompanyToolNames {
    public static let base = ["post_message", "send_dm", "read_channel", "list_channels", "list_agents", "create_channel", "set_blocked"]
    public static let work = ["list_work", "show_work_item", "create_work_item", "update_work_item", "link_dependency",
                              "comment_work_item", "claim_lease", "release_lease", "submit_for_review", "write_handoff",
                              "propose_decision", "request_from_owner", "escalate_decision"]
    public static let lead = ["plan_sprint", "close_sprint", "confirm_spec"]
    public static let executive = ["decide"]
    /// Review turns only, regardless of role.
    public static let review = ["show_work_item", "comment_work_item", "review"]
    public static var all: [String] { base + work + lead + executive + ["review"] }
}

public struct RoleTemplate: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var kind: RoleKind
    public var handlePrefix: String
    public var prompt: String
    public var companyTools: [String]
    /// low/balanced/max -> opus|sonnet|haiku
    public var models: [String: String]
    public var roleWeight: Int
    public var covers: [String]
    public var skills: [String] = []
    public var connectors: [String] = []
    /// item-type id -> playbook text (<= `maxPlaybook` chars).
    public var playbooks: [String: String] = [:]

    public static let maxPrompt = 5000
    public static let maxPlaybook = 2500

    public init(id: String, title: String, kind: RoleKind, handlePrefix: String, prompt: String, companyTools: [String],
                models: [String: String], roleWeight: Int, covers: [String] = [], skills: [String] = [],
                connectors: [String] = [], playbooks: [String: String] = [:]) {
        self.id = id; self.title = title; self.kind = kind; self.handlePrefix = handlePrefix; self.prompt = prompt
        self.companyTools = companyTools; self.models = models; self.roleWeight = roleWeight; self.covers = covers
        self.skills = skills; self.connectors = connectors; self.playbooks = playbooks
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, kind, handlePrefix, prompt, companyTools, models, roleWeight, covers, skills, connectors, playbooks
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        kind = try c.decode(RoleKind.self, forKey: .kind)
        handlePrefix = try c.decode(String.self, forKey: .handlePrefix)
        prompt = try c.decode(String.self, forKey: .prompt)
        companyTools = try c.decode([String].self, forKey: .companyTools)
        models = try c.decode([String: String].self, forKey: .models)
        roleWeight = try c.decode(Int.self, forKey: .roleWeight)
        covers = try c.decodeIfPresent([String].self, forKey: .covers) ?? []
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        connectors = try c.decodeIfPresent([String].self, forKey: .connectors) ?? []
        playbooks = try c.decodeIfPresent([String: String].self, forKey: .playbooks) ?? [:]
    }

    /// Fallback for a role id no pack defines: individual contributor, base+work tools, sonnet, weight 0.
    public static func generic(_ roleId: String) -> RoleTemplate {
        let cleaned = String(roleId.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(16))
        let prefix = cleaned.first?.isLetter == true ? cleaned : "r" + cleaned
        let title = roleId.prefix(1).uppercased() + roleId.dropFirst()
        let prompt = """
        ## Mission
        You are a \(title) on this team. Do the work items assigned to you well and keep the team informed.

        ## Responsibilities
        - Claim work with claim_lease, do it, and hand it over with submit_for_review.
        - Write a hand-off (write_handoff) when you stop. Use set_blocked when you cannot proceed.

        ## Escalation
        Use propose_decision for choices outside your remit and request_from_owner for anything the owner must decide.

        ## Output template
        Summary of what changed, evidence, open questions.
        STATUS: DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT
        """
        return RoleTemplate(id: roleId, title: title, kind: .individual, handlePrefix: prefix.isEmpty ? "agent" : prefix,
                            prompt: prompt, companyTools: CompanyToolNames.base + CompanyToolNames.work,
                            models: ["low": "sonnet", "balanced": "sonnet", "max": "sonnet"], roleWeight: 0)
    }
}

public struct ItemTypeDef: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var container: Bool
    public var claimable: Bool
    public var requiresCheck: Bool
    public var checkTemplate: String? = nil
    public var deliverableTemplate: String? = nil

    public init(id: String, title: String, container: Bool, claimable: Bool, requiresCheck: Bool,
                checkTemplate: String? = nil, deliverableTemplate: String? = nil) {
        self.id = id; self.title = title; self.container = container; self.claimable = claimable
        self.requiresCheck = requiresCheck; self.checkTemplate = checkTemplate; self.deliverableTemplate = deliverableTemplate
    }

    private enum CodingKeys: String, CodingKey { case id, title, container, claimable, requiresCheck, checkTemplate, deliverableTemplate }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        container = try c.decode(Bool.self, forKey: .container)
        claimable = try c.decode(Bool.self, forKey: .claimable)
        requiresCheck = try c.decode(Bool.self, forKey: .requiresCheck)
        checkTemplate = try c.decodeIfPresent(String.self, forKey: .checkTemplate)
        deliverableTemplate = try c.decodeIfPresent(String.self, forKey: .deliverableTemplate)
    }
}

public struct RoleRatio: Codable, Equatable, Sendable {
    public var role: String
    public var teamsPer: Int
    public var minAgents: Int
    public var reportsTo: String
    public init(role: String, teamsPer: Int, minAgents: Int, reportsTo: String) {
        self.role = role; self.teamsPer = teamsPer; self.minAgents = minAgents; self.reportsTo = reportsTo
    }
}

public struct OrgShape: Codable, Equatable, Sendable {
    public var executives: [String]
    public var mergedExecutives: [String]
    public var mergedBelow: Int
    public var teamLead: String
    public var teamMember: String
    public var teamSupport: String?
    public var membersPerTeamMax: Int
    public var ratios: [RoleRatio]
    public var director: String
    public var smallTeamName: String
    public init(executives: [String], mergedExecutives: [String], mergedBelow: Int, teamLead: String, teamMember: String,
                teamSupport: String?, membersPerTeamMax: Int, ratios: [RoleRatio], director: String, smallTeamName: String) {
        self.executives = executives; self.mergedExecutives = mergedExecutives; self.mergedBelow = mergedBelow
        self.teamLead = teamLead; self.teamMember = teamMember; self.teamSupport = teamSupport
        self.membersPerTeamMax = membersPerTeamMax; self.ratios = ratios; self.director = director
        self.smallTeamName = smallTeamName
    }
}

public enum PackError: Error, Equatable { case invalid(pack: String, reason: String) }

public struct IndustryPack: Codable, Equatable, Sendable {
    public var id: String
    public var version: Int
    public var title: String
    public var roles: [RoleTemplate]
    public var itemTypes: [ItemTypeDef]
    public var org: OrgShape
    public var defaultCadence: String
    public var askApprovers: [String: [String]]
    /// Additions only: a pack can add reserved categories, never remove built-in ones.
    public var reservedCategories: [String]
    public var connectors: [String] = []
    /// Roles staffed only when work calls for them: `OrgGenerator.staff` always leaves their seats vacant.
    public var triggerRoles: [String] = []

    public static let defaultTriggerRoles = ["qa", "designer", "security"]

    public init(id: String, version: Int, title: String, roles: [RoleTemplate], itemTypes: [ItemTypeDef], org: OrgShape,
                defaultCadence: String, askApprovers: [String: [String]], reservedCategories: [String],
                connectors: [String] = [], triggerRoles: [String] = []) {
        self.id = id; self.version = version; self.title = title; self.roles = roles; self.itemTypes = itemTypes
        self.org = org; self.defaultCadence = defaultCadence; self.askApprovers = askApprovers
        self.reservedCategories = reservedCategories; self.connectors = connectors; self.triggerRoles = triggerRoles
    }

    private enum CodingKeys: String, CodingKey {
        case id, version, title, roles, itemTypes, org, defaultCadence, askApprovers, reservedCategories, connectors, triggerRoles
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        version = try c.decode(Int.self, forKey: .version)
        title = try c.decode(String.self, forKey: .title)
        roles = try c.decode([RoleTemplate].self, forKey: .roles)
        itemTypes = try c.decode([ItemTypeDef].self, forKey: .itemTypes)
        org = try c.decode(OrgShape.self, forKey: .org)
        defaultCadence = try c.decode(String.self, forKey: .defaultCadence)
        askApprovers = try c.decode([String: [String]].self, forKey: .askApprovers)
        reservedCategories = try c.decode([String].self, forKey: .reservedCategories)
        connectors = try c.decodeIfPresent([String].self, forKey: .connectors) ?? []
        // Absent: the standard trigger roles, limited to those this pack defines.
        let known = Set(roles.map(\.id))
        triggerRoles = try c.decodeIfPresent([String].self, forKey: .triggerRoles)
            ?? Self.defaultTriggerRoles.filter { known.contains($0) }
    }

    public func role(_ id: String) -> RoleTemplate? { roles.first { $0.id == id } }
    public func itemType(_ id: String) -> ItemTypeDef? { itemTypes.first { $0.id == id } }
    public func rolesCovering(_ id: String) -> [String] {
        roles.filter { $0.id == id || $0.covers.contains(id) }.map(\.id)
    }

    public func validate() throws {
        func fail(_ reason: String) -> PackError { .invalid(pack: id, reason: reason) }
        let roleIds = roles.map(\.id)
        if Set(roleIds).count != roleIds.count { throw fail("duplicate role id") }
        let typeIds = itemTypes.map(\.id)
        if Set(typeIds).count != typeIds.count { throw fail("duplicate item type id") }
        let known = Set(roleIds)
        let tools = Set(CompanyToolNames.all)
        let prefix = try! NSRegularExpression(pattern: "^[a-z][a-z0-9-]{0,15}$")
        let category = try! NSRegularExpression(pattern: "^[a-z][a-z0-9-]{0,31}$")
        func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
            r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        for r in roles {
            for mode in ["low", "balanced", "max"] {
                guard let m = r.models[mode], ["opus", "sonnet", "haiku"].contains(m) else {
                    throw fail("role \(r.id): bad or missing model for \(mode)")
                }
            }
            if let t = r.companyTools.first(where: { !tools.contains($0) }) { throw fail("role \(r.id): unknown tool \(t)") }
            if !matches(prefix, r.handlePrefix) { throw fail("role \(r.id): bad handlePrefix") }
            if let c = r.covers.first(where: { !known.contains($0) && !(org.executives + [org.teamLead, org.teamMember, org.director]).contains($0) }) {
                throw fail("role \(r.id): unknown covered role \(c)")
            }
            if r.prompt.count > RoleTemplate.maxPrompt { throw fail("role \(r.id): prompt too long") }
            for (key, text) in r.playbooks {
                if !typeIds.contains(key) { throw fail("role \(r.id): playbook for unknown item type \(key)") }
                if text.count > RoleTemplate.maxPlaybook { throw fail("role \(r.id): playbook \(key) too long") }
            }
        }
        var orgRoles = org.executives + org.mergedExecutives + [org.teamLead, org.teamMember, org.director]
        if let s = org.teamSupport { orgRoles.append(s) }
        for r in org.ratios { orgRoles.append(r.role); orgRoles.append(r.reportsTo) }
        if let u = orgRoles.first(where: { !known.contains($0) }) { throw fail("org references unknown role \(u)") }
        for (kind, approvers) in askApprovers {
            if let u = approvers.first(where: { !known.contains($0) }) { throw fail("askApprovers[\(kind)] unknown role \(u)") }
        }
        if let t = triggerRoles.first(where: { !known.contains($0) }) { throw fail("unknown trigger role \(t)") }
        if !["sprint", "milestone"].contains(defaultCadence) { throw fail("bad cadence \(defaultCadence)") }
        if let c = reservedCategories.first(where: { !matches(category, $0) }) { throw fail("bad reserved category \(c)") }
    }
}

public struct PackCatalog: Sendable {
    public static let builtin = PackCatalog(packs: [SoftwarePack.pack])

    public private(set) var packs: [IndustryPack]

    public init(packs: [IndustryPack]) { self.packs = packs }

    /// Reads `*.json` packs from `directory`. The higher version wins for the same id. An invalid file throws, naming the file.
    public static func load(directory: URL, base: PackCatalog = .builtin) throws -> PackCatalog {
        var result = base.packs
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return PackCatalog(packs: result)
        }
        for name in names.sorted() where name.hasSuffix(".json") {
            let file = directory.appending(path: name)
            let pack: IndustryPack
            do {
                pack = try JSONDecoder().decode(IndustryPack.self, from: Data(contentsOf: file))
                try pack.validate()
            } catch let e as PackError {
                if case .invalid(_, let reason) = e { throw PackError.invalid(pack: name, reason: reason) }
                throw e
            } catch {
                throw PackError.invalid(pack: name, reason: "\(error)")
            }
            if let i = result.firstIndex(where: { $0.id == pack.id }) {
                if pack.version > result[i].version { result[i] = pack }
            } else {
                result.append(pack)
            }
        }
        return PackCatalog(packs: result)
    }

    public func pack(_ id: String) -> IndustryPack? { packs.first { $0.id == id } }

    public func template(role: String, pack packId: String) -> RoleTemplate {
        pack(packId)?.role(role) ?? .generic(role)
    }

    public func roleWeight(_ role: String) -> Int {
        for p in packs.sorted(by: { $0.id < $1.id }) { if let r = p.role(role) { return r.roleWeight } }
        return 0
    }
}
