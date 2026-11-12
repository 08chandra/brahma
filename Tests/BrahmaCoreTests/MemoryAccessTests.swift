import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan ML Task 1: the two-stage access engine (`MemoryAccess.level`) and the reader context it reads (`ReaderContext.load`).
@Suite(.scratch) struct MemoryAccessTests {
    /// One company on a pack with a CFO and a merged CEO & CFO seat:
    /// ceo ← cto ← mgr-1 ← {eng-1, eng-2} (team payments); cto ← mgr-2 ← eng-7 (team web); ceo ← cfo; chief (ceo-cfo).
    struct Org {
        let store: Store, company: Company
        let ceo: Agent, cto: Agent, cfo: Agent, chief: Agent, mgr1: Agent, mgr2: Agent, eng1: Agent, eng2: Agent, eng7: Agent

        init() throws {
            var pack = try #require(PackCatalog.builtin.pack("software"))
            let ceoTemplate = try #require(pack.role("ceo"))
            var cfoTemplate = ceoTemplate
            cfoTemplate.id = "cfo"; cfoTemplate.title = "CFO"; cfoTemplate.handlePrefix = "cfo"
            var merged = ceoTemplate
            merged.id = "ceo-cfo"; merged.title = "CEO & CFO"; merged.covers = ["ceo", "cfo"]
            pack.roles += [cfoTemplate, merged]
            let s = try Store.inMemory(catalog: PackCatalog(packs: [pack]))
            let c = try s.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
            func hire(_ n: String, _ role: String, _ manager: Agent? = nil, team: String? = nil) throws -> Agent {
                try s.hire(companyId: c.id, name: n, role: role, model: "sonnet", managerId: manager?.id, team: team)
            }
            store = s; company = c
            ceo = try hire("ceo", "ceo")
            cto = try hire("cto", "cto", ceo)
            cfo = try hire("cfo", "cfo", ceo)
            chief = try hire("chief", "ceo-cfo")
            mgr1 = try hire("mgr-1", "manager", cto)
            mgr2 = try hire("mgr-2", "manager", cto)
            eng1 = try hire("eng-1", "engineer", mgr1, team: "payments")
            eng2 = try hire("eng-2", "engineer", mgr1, team: "payments")
            eng7 = try hire("eng-7", "engineer", mgr2, team: "web")
        }

        func ctx(_ reader: Reader) throws -> ReaderContext {
            try ReaderContext.load(store: store, companyId: company.id, reader: reader)
        }

        func level(_ a: Agent?, _ access: AccessClass, sensitivity: Sensitivity = .normal, readerSet: Set<String>? = nil,
                   restrictions: [Restriction] = [], futureHolders: Bool = false) throws -> AccessLevel {
            MemoryAccess.level(try ctx(a.map { .agent($0.id) } ?? .owner), access: access, sensitivity: sensitivity,
                               readerSet: readerSet, restrictions: restrictions, futureHolders: futureHolders)
        }
    }

    // MARK: The matrix (pure contexts)

    private enum Who: CaseIterable { case owner, concierge, member, nonMember, managerAbove, report }

    private func context(_ who: Who) -> ReaderContext {
        switch who {
        case .owner: ReaderContext(reader: .owner, companyId: "c")
        case .concierge: ReaderContext(reader: .concierge, companyId: "c")
        case .member:
            ReaderContext(reader: .agent("m"), companyId: "c", agentId: "m", team: "payments", roles: ["engineer"],
                          channelIds: ["c1", "d1"], itemIds: ["i1"], heldItemIds: ["i1"], reportIds: ["r"], teamsBelow: ["payments"])
        case .nonMember:
            ReaderContext(reader: .agent("x"), companyId: "c", agentId: "x", team: "web", roles: ["designer"])
        case .managerAbove:
            ReaderContext(reader: .agent("boss"), companyId: "c", agentId: "boss", roles: ["manager"], itemIds: ["i1"],
                          reportIds: ["m", "r"], teamsBelow: ["payments"])
        case .report:
            ReaderContext(reader: .agent("r"), companyId: "c", agentId: "r", team: "payments", roles: ["engineer"])
        }
    }

    /// The level at `normal` sensitivity, written out by hand.
    private func normal(_ who: Who, _ access: AccessClass) -> AccessLevel {
        switch (who, access) {
        case (.owner, _), (.concierge, _): .full
        case (_, .ownerOnly): .none
        case (_, .company): .full
        case (.member, .team), (.managerAbove, .team), (.report, .team): .full
        case (.member, .role), (.report, .role): .full
        case (.member, .item), (.managerAbove, .item): .full
        case (.member, .agent): .full
        case (.managerAbove, .agent): .summary
        case (.member, .channel), (.member, .dm): .full
        default: .none
        }
    }

    @Test func accessMatrix() throws {
        let classes: [AccessClass] = [.company, .team("payments"), .role("engineer"), .item("i1"), .agent("m"), .channel("c1"),
                                      .dm("d1"), .ownerOnly]
        for who in Who.allCases {
            let ctx = context(who)
            for access in classes {
                for sensitivity in [Sensitivity.normal, .internal, .restricted, .hrPerf, .secret] {
                    let expected: AccessLevel
                    switch who {
                    case .owner: expected = .full
                    case .concierge: expected = sensitivity == .secret ? .none : .full
                    default:
                        switch sensitivity {
                        case .normal, .internal: expected = normal(who, access)
                        // No one in these contexts is an executive: a restricted doc with no restriction caps them all.
                        case .restricted, .hrPerf, .secret: expected = .none
                        }
                    }
                    let got = MemoryAccess.level(ctx, access: access, sensitivity: sensitivity, readerSet: nil, restrictions: [],
                                                 futureHolders: false)
                    #expect(got == expected, "\(who) × \(access.label) × \(sensitivity)")
                }
            }
        }
        // company + restricted (no explicit restriction = ["@executive"]): an engineer none, the CEO full.
        let eng = context(.member)
        let ceo = ReaderContext(reader: .agent("ceo"), companyId: "c", agentId: "ceo", roles: ["ceo"], isExecutive: true)
        #expect(MemoryAccess.level(eng, access: .company, sensitivity: .restricted, readerSet: nil, restrictions: [["@executive"]],
                                   futureHolders: false) == .none)
        #expect(MemoryAccess.level(ceo, access: .company, sensitivity: .restricted, readerSet: nil, restrictions: [["@executive"]],
                                   futureHolders: false) == .full)
        #expect(MemoryAccess.level(ceo, access: .company, sensitivity: .restricted, readerSet: nil, restrictions: [],
                                   futureHolders: false) == .full)
        // A cap never raises: a CEO with no base access to an item stays at none.
        #expect(MemoryAccess.level(ceo, access: .item("i1"), sensitivity: .restricted, readerSet: nil, restrictions: [],
                                   futureHolders: false) == .none)
        // A restriction caps a summary too.
        #expect(MemoryAccess.level(context(.managerAbove), access: .agent("m"), sensitivity: .normal, readerSet: nil,
                                   restrictions: [["cfo"]], futureHolders: false) == .none)
    }

    @Test func restrictionsAreAndCaps() throws {
        func ctx(_ roles: Set<String>) -> ReaderContext {
            ReaderContext(reader: .agent("a"), companyId: "c", agentId: "a", roles: roles, isExecutive: true)
        }
        let both: [Restriction] = [["cfo"], ["cto"]]
        func level(_ c: ReaderContext) -> AccessLevel {
            MemoryAccess.level(c, access: .company, sensitivity: .normal, readerSet: nil, restrictions: both, futureHolders: false)
        }
        #expect(level(ctx(["cfo"])) == .none)
        #expect(level(ctx(["cto"])) == .none)
        #expect(level(ctx(["ceo-cfo-cto", "cfo", "cto"])) == .full)
        // An element any of whose roles the reader holds is satisfied; "@executive" matches an executive.
        #expect(MemoryAccess.level(ctx(["cto"]), access: .company, sensitivity: .normal, readerSet: nil,
                                   restrictions: [["cfo", "cto"], ["@executive"]], futureHolders: false) == .full)
        let nonExec = ReaderContext(reader: .agent("a"), companyId: "c", agentId: "a", roles: ["cto"])
        #expect(MemoryAccess.level(nonExec, access: .company, sensitivity: .normal, readerSet: nil,
                                   restrictions: [["cfo", "cto"], ["@executive"]], futureHolders: false) == .none)
    }

    // MARK: Contexts loaded from the store

    @Test func dmOnlyParticipants() throws {
        let o = try Org()
        let dm = try o.store.writer.write { db in
            try Store.insertChannel(db, companyId: o.company.id, name: "dm:eng-1:eng-2", kind: .dm,
                                    members: [o.eng1.id, o.eng2.id], now: Store.now())
        }
        #expect(try o.level(o.eng1, .dm(dm.id)) == .full)
        #expect(try o.level(o.eng2, .dm(dm.id)) == .full)
        #expect(try o.level(o.mgr1, .dm(dm.id)) == .none)
        #expect(try o.level(o.ceo, .dm(dm.id)) == .none)
        #expect(try o.level(nil, .dm(dm.id)) == .full)
    }

    @Test func channelMembersOnly() throws {
        let o = try Org()
        let channel = try o.store.createChannel(companyId: o.company.id, name: "payments-chat", members: [o.eng1.id])
        #expect(try o.level(o.eng1, .channel(channel.id)) == .full)
        #expect(try o.level(o.eng2, .channel(channel.id)) == .none)
        #expect(try o.level(o.mgr1, .channel(channel.id)) == .none)
        // Without a fixed reader set, a channel's docs follow its membership.
        try o.store.addMember(channelId: channel.id, member: o.eng2.id)
        #expect(try o.level(o.eng2, .channel(channel.id)) == .full)
        // Every agent is in #general.
        let general = try #require(try o.store.channel(companyId: o.company.id, name: "general"))
        #expect(try o.level(o.eng7, .channel(general.id)) == .full)
    }

    @Test func teamIncludesManagersAbove() throws {
        let o = try Org()
        #expect(try o.level(o.eng1, .team("payments")) == .full)
        #expect(try o.level(o.mgr1, .team("payments")) == .full)
        #expect(try o.level(o.cto, .team("payments")) == .full)
        #expect(try o.level(o.eng7, .team("payments")) == .none)
        #expect(try o.level(o.mgr2, .team("payments")) == .none)
        #expect(try o.ctx(.agent(o.cto.id)).teamsBelow == ["payments", "web"])
    }

    @Test func privateAgentMemoryFullForSelfSummaryForManagerChain() throws {
        let o = try Org()
        #expect(try o.level(o.eng1, .agent(o.eng1.id)) == .full)
        #expect(try o.level(o.mgr1, .agent(o.eng1.id)) == .summary)
        #expect(try o.level(o.cto, .agent(o.eng1.id)) == .summary)
        #expect(try o.level(o.ceo, .agent(o.eng1.id)) == .summary)
        #expect(try o.level(o.eng2, .agent(o.eng1.id)) == .none)
        #expect(try o.level(o.mgr2, .agent(o.eng1.id)) == .none)
        #expect(try o.level(nil, .agent(o.eng1.id)) == .full)
        #expect(try o.ctx(.agent(o.cto.id)).reportIds == Set([o.mgr1, o.mgr2, o.eng1, o.eng2, o.eng7].map(\.id)))
    }

    @Test func restrictedNeedsRole() throws {
        let o = try Org()
        #expect(try o.level(o.cfo, .company, restrictions: [["cfo"]]) == .full)
        #expect(try o.level(o.ceo, .company, restrictions: [["cfo"]]) == .none)
        #expect(try o.level(o.chief, .company, restrictions: [["cfo"]]) == .full)
        #expect(try o.ctx(.agent(o.chief.id)).roles == ["ceo-cfo", "ceo", "cfo"])
        // `restricted` with no restriction is executives only.
        #expect(try o.level(o.ceo, .company, sensitivity: .restricted) == .full)
        #expect(try o.level(o.mgr1, .company, sensitivity: .restricted) == .none)
        // An acting CEO counts as an executive and covers `ceo`.
        try o.store.writer.write { db in
            try db.execute(sql: "UPDATE agent SET actingRole = 'ceo' WHERE id = ?", arguments: [o.mgr1.id])
        }
        #expect(try o.level(o.mgr1, .company, sensitivity: .restricted) == .full)
        #expect(try o.level(o.mgr1, .company, restrictions: [["ceo"]]) == .full)
        #expect(try o.ctx(.agent(o.mgr1.id)).isExecutive)
    }

    @Test func hrPerfAndSecretOwnerOnly() throws {
        let o = try Org()
        for sensitivity in [Sensitivity.hrPerf, .secret] {
            for a in [o.ceo, o.cfo, o.chief, o.mgr1, o.eng1] {
                #expect(try o.level(a, .company, sensitivity: sensitivity) == .none)
                #expect(try o.level(a, .agent(a.id), sensitivity: sensitivity) == .none)
            }
            #expect(try o.level(nil, .company, sensitivity: sensitivity) == .full)
        }
        let concierge = try o.ctx(.concierge)
        #expect(MemoryAccess.level(concierge, access: .company, sensitivity: .hrPerf, readerSet: nil, restrictions: [],
                                   futureHolders: false) == .full)
        #expect(MemoryAccess.level(concierge, access: .company, sensitivity: .secret, readerSet: nil, restrictions: [],
                                   futureHolders: false) == .none)
        #expect(MemoryAccess.level(concierge, access: .ownerOnly, sensitivity: .normal, readerSet: nil, restrictions: [],
                                   futureHolders: false) == .full)
        #expect(Sensitivity.normal < .internal && Sensitivity.internal < .restricted && Sensitivity.restricted < .hrPerf
                && Sensitivity.hrPerf < .secret)
        #expect(Sensitivity.hrPerf.rawValue == "hr-perf")
    }

    @Test func fixedReaderSetExcludesLaterJoinerAndManagers() throws {
        let o = try Org()
        let channel = try o.store.createChannel(companyId: o.company.id, name: "launch", members: [o.eng1.id, o.eng2.id])
        let set: Set<String> = [o.eng1.id, o.eng2.id]
        #expect(try o.level(o.eng1, .channel(channel.id), readerSet: set) == .full)
        #expect(try o.level(o.eng2, .channel(channel.id), readerSet: set) == .full)
        try o.store.addMember(channelId: channel.id, member: o.eng7.id)
        #expect(try o.level(o.eng7, .channel(channel.id)) == .full)                 // the channel, yes
        #expect(try o.level(o.eng7, .channel(channel.id), readerSet: set) == .none) // the drop made before joining, no
        #expect(try o.level(o.mgr1, .channel(channel.id), readerSet: set) == .none)
        #expect(try o.level(o.ceo, .channel(channel.id), readerSet: set) == .none)
        #expect(try o.level(nil, .channel(channel.id), readerSet: set) == .full)
        // A reader set does not get past the caps either.
        #expect(try o.level(o.eng1, .channel(channel.id), readerSet: set, restrictions: [["cfo"]]) == .none)
        #expect(try o.level(o.eng1, .channel(channel.id), sensitivity: .hrPerf, readerSet: set) == .none)
    }

    @Test func futureHoldersFollowItem() throws {
        let o = try Org()
        let item = try o.store.createWorkItem(companyId: o.company.id, by: .owner,
                                              draft: WorkItemDraft(type: .task, title: "Retry payments", ownerId: o.eng1.id))
        let set: Set<String> = [o.eng1.id]
        #expect(try o.level(o.eng1, .item(item.id), readerSet: set, futureHolders: true) == .full)
        #expect(try o.level(o.eng2, .item(item.id), readerSet: set, futureHolders: true) == .none)
        try o.store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET ownerId = ? WHERE id = ?", arguments: [o.eng2.id, item.id])
        }
        #expect(try o.ctx(.agent(o.eng2.id)).heldItemIds == [item.id])
        #expect(try o.level(o.eng2, .item(item.id), readerSet: set, futureHolders: true) == .full)
        #expect(try o.level(o.eng2, .item(item.id), readerSet: set, futureHolders: false) == .none)
        #expect(try o.level(o.eng1, .item(item.id), readerSet: set, futureHolders: true) == .full)   // a named reader stays one
        // The manager sees the item (owned by a report) but is not a holder: the reader set keeps it out.
        #expect(try o.level(o.mgr1, .item(item.id)) == .full)
        #expect(try o.level(o.mgr1, .item(item.id), readerSet: set, futureHolders: true) == .none)
    }

    @Test func crossCompanyReaderSeesNothing() throws {
        let o = try Org()
        let other = try o.store.createCompany(name: "Other", goal: "g", workspacesRoot: try tempDir())
        let stranger = try o.store.hire(companyId: other.id, name: "eng-1", role: "engineer", model: "sonnet")
        #expect(throws: WorkError.forbidden("not in your company")) {
            try ReaderContext.load(store: o.store, companyId: o.company.id, reader: .agent(stranger.id))
        }
        #expect(throws: WorkError.forbidden("not in your company")) {
            try ReaderContext.load(store: o.store, companyId: o.company.id, reader: .agent("no-such-agent"))
        }
        // A context's sets hold only its own company's ids.
        let ctx = try ReaderContext.load(store: o.store, companyId: other.id, reader: .agent(stranger.id))
        #expect(ctx.reportIds.isEmpty)
        #expect(ctx.channelIds == [try #require(try o.store.channel(companyId: other.id, name: "general")).id])
    }
}
