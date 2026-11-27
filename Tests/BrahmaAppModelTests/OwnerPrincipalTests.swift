import Testing
import Foundation
import GRDB
@testable import BrahmaCore
@testable import BrahmaAppModel

/// C6 fix round 2, controller Ruling C6-2(b): every owner-only BrahmaCore API takes an `OwnerPrincipal` that only an owner surface
/// can establish; a turn's process (BRAHMA_AGENT_ID set, or inside a running turn's process tree) gets none, and a call without one
/// is refused with the generic text.
@MainActor @Suite(.scratch) struct OwnerPrincipalTests {
    nonisolated static let apis = ["renderRef", "ownerShare", "ownerThreadReply", "openShowRequests", "recordOwnerRead", "message", "agentUsageShareToday",
                       "agentActivity", "leasedItemKey", "viewOriginal"]

    @Test func agentProcessesCannotMintAnOwner() throws {
        // Ruling C6-3: an agent process (`brahma mcp`, a turn's entry point) can mint nothing, whatever its environment says.
        #expect(throws: OwnerPrincipalError.self) { try OwnerPrincipal.mint(role: .agent, environment: [:], ancestors: [1], runningTurnPids: []) }
        // A turn's environment or process tree refuses too.
        #expect(throws: OwnerPrincipalError.self) { try OwnerPrincipal.mint(role: .owner, environment: ["BRAHMA_AGENT_ID": "a1"], ancestors: [], runningTurnPids: []) }
        #expect(throws: OwnerPrincipalError.self) { try OwnerPrincipal.mint(role: .owner, environment: ["BRAHMA_AGENT_ID": "concierge"], ancestors: [], runningTurnPids: []) }
        #expect(throws: OwnerPrincipalError.self) { try OwnerPrincipal.mint(role: .unknown, environment: [:], ancestors: [4242, 1], runningTurnPids: [4242]) }
        // The owner's own shell and the app mint one; this test process is an owner surface.
        _ = try OwnerPrincipal.mint(role: .owner, environment: [:], ancestors: [1], runningTurnPids: [])
        _ = try OwnerPrincipal.mint()
        #expect(OwnerPrincipal.processRole != .agent)
        // A server entry point asserts the agent role; an unknown or owner role refuses it.
        #expect(throws: OwnerPrincipalError.self) { try OwnerPrincipal.requireAgentProcess() }
    }

    /// No MCP tool handler names the principal: the owner-only APIs are unreachable from a tool at compile time, and nothing in the
    /// handlers mints or passes one.
    @Test func noToolHandlerReferencesTheOwnerPrincipal() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let mcp = root.appending(path: "Sources/BrahmaCore/MCP")
        let files = try FileManager.default.contentsOfDirectory(atPath: mcp.path).filter { $0.hasSuffix(".swift") }
        #expect(files.contains("CompanyTools.swift") && files.contains("CollabTools.swift"))
        // Round 3: an implicit `.mint(` and every one of the 12 tokenised APIs, however the call is spelled.
        let apis = ["renderRef(", "ownerShare(", "ownerThreadReply(", "openShowRequests(", "recordOwnerRead(", ".message(companyId", "agentUsageShareToday(",
                    "agentActivity(", "leasedItemKey(", "viewOriginal(", ".purge(companyId", "vouchItem(",
                    // C6b: the owner's inline review.
                    "addDiffComment(", "requestHunkRevert(", "resolveDiffComment(",
                    // Final wave B1 (C6-4, its addition, FR I-2, C7b m-7, Rulings 23 and 28): every other owner API.
                    "ownerDecide(", "ownerAnswer(", "ownerRescind(", "ownerReplan(", ".acknowledge(", "vouchFile(", "vouchResource(",
                    "purgeResource(", "setResourceScope(", "approveAccess(", "provideSecret(", "declineFileRequest(",
                    "answerFileRequest(", "kbVouch(", "vouchRestoredCommits(", "exportRef(", "sendFileAsk(", "ownerDrop(",
                    "createShowRequest(", "cancelShowRequest(", "clearTaintedCommits(", "addResources(", "addLink(", "setPreset(",
                    "clearTaintHolds(", "ExtensionLibrary.approve(", "ExtensionLibrary.remove(", "ExtensionLibrary.rollback(",
                    "AccessPresets.evaluate(", "DecisionAuthority", "PolicyPrincipal", ".preset(",
                    // Fix round 1 (and re-review I-1).
                    "setAutonomy(", "trustImport(", "clearCompanyLabTaint(", "clearLabTaint(", "clearMachineLabTaint(", "acceptMainCommit(",
                    "adoptMain(", "adoptMainAsEngine(", "completeHumanTask(", "declineHumanTask(", "clearCompanyMark(", "clearMachineMark(",
                    "RepoImport.trust("]
        for f in files {
            let text = try String(contentsOf: mcp.appending(path: f), encoding: .utf8)
            #expect(!text.contains("OwnerPrincipal"), "\(f) references OwnerPrincipal")
            #expect(!text.contains(".mint("), "\(f) mints a principal")
            for api in apis { #expect(!text.contains(api), "\(f) calls \(api)") }
        }
        // The server entry and both hook processes mark themselves agent processes before they open a Store.
        let server = try String(contentsOf: root.appending(path: "Sources/brahma/MCPCommand.swift"), encoding: .utf8)
        #expect(server.contains("OwnerPrincipal.enterAgentProcess()"))
        #expect(server.range(of: "enterAgentProcess()")!.lowerBound < server.range(of: "try Store(path: db")!.lowerBound)
        let hooks = try String(contentsOf: root.appending(path: "Sources/brahma/HookCommand.swift"), encoding: .utf8)
        #expect(hooks.components(separatedBy: "OwnerPrincipal.enterAgentProcess()").count == 3, "both hook commands enter agent mode")
        #expect(hooks.range(of: "enterAgentProcess()")!.lowerBound < hooks.range(of: "PreToolHook.Context(")!.lowerBound)
        #expect(hooks.range(of: "enterAgentProcess()", options: .backwards)!.lowerBound < hooks.range(of: "PostToolHook.handle(")!.lowerBound)
    }

    /// Final wave B1 (controller Ruling C6-4 addition): a `PolicyPrincipal` is minted only by the engine's preset evaluator
    /// (`AccessPresets.evaluate`, from an owner-configured preset row), and only `requestAccess` hands one to `ownerDecide(db:)`.
    /// The `db:` owner overloads take a `DecisionAuthority` (no free-string `decidedBy`) or the owner principal.
    @Test func policyPrincipalIsMintedOnlyByThePresetEvaluator() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appending(path: "Sources")
        let walker = try #require(FileManager.default.enumerator(atPath: sources.path))
        var minted: [String] = [], presetAuthority: [String] = [], decidedBy: [String] = []
        for case let rel as String in walker where rel.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appending(path: rel), encoding: .utf8)
            if text.contains("PolicyPrincipal(presetId:") { minted.append(rel) }
            if text.contains("by: .preset(") { presetAuthority.append(rel) }
            if text.contains("decidedBy: decision.approvedBy") || text.contains("decidedBy: String = \"owner\"") { decidedBy.append(rel) }
        }
        #expect(minted == ["BrahmaCore/Access/Grants.swift"], "\(minted)")
        #expect(presetAuthority == ["BrahmaCore/Store/Store+Grants.swift"], "\(presetAuthority)")
        #expect(decidedBy.isEmpty, "\(decidedBy)")
        let grants = try String(contentsOf: sources.appending(path: "BrahmaCore/Access/Grants.swift"), encoding: .utf8)
        #expect(grants.contains("fileprivate init(presetId: String, askId: String)"))
        #expect(grants.components(separatedBy: "PolicyPrincipal(presetId:").count == 2, "minted in one place")
    }

    @Test(arguments: apis) func ownerAPIsRequireThePrincipal(_ api: String) async throws {
        let w = try RefWorld()
        let owner = try w.owner()
        try w.seedResource(number: 1, name: "a.md", bytes: Data("hello\n".utf8), provenance: "owner")
        let dm = try MessageRouter(store: w.store).sendDM(companyId: w.company.id, from: .agent(w.eng1.id), to: "owner", text: "hi", now: w.now)
        let (s, cId, paths, ref) = (w.store, w.company.id, w.paths, try w.ref("src/a.ts"))
        // With a principal the API works; the store's guard refuses a missing one with the generic text, so no caller without an owner
        // surface (an MCP tool, a turn) can act as the owner.
        func refused(_ body: () throws -> Void) -> Bool {
            do { try body(); return false } catch let e as WorkError { return e.message == Store.refUnavailable } catch { return false }
        }
        #expect(refused { _ = try s.requireOwner(nil) })
        switch api {
        case "renderRef":
            _ = try s.renderRef(companyId: cId, ref: ref, knownValues: [], paths: paths, archives: UnavailableArchiveReader(), via: nil, owner: owner)
        case "ownerShare":
            _ = try s.ownerShare(companyId: cId, refs: ["src/a.ts"], to: "@eng-1", note: "look", replyTo: nil, knownValues: [], paths: paths, owner: owner)
        case "ownerThreadReply":
            _ = try s.ownerThreadReply(companyId: cId, rootId: dm.id, text: "thanks", owner: owner)
        case "openShowRequests":
            _ = try s.openShowRequests(companyId: cId, owner: owner)
        case "recordOwnerRead":
            try s.recordOwnerRead(companyId: cId, ref: ref, via: "tab", tainted: false, owner: owner)
        case "message":
            #expect(try s.message(companyId: cId, id: dm.id, owner: owner)?.id == dm.id)
        case "agentUsageShareToday":
            _ = try s.agentUsageShareToday(agentId: w.eng1.id, now: w.now, owner: owner)
        case "agentActivity":
            _ = try s.agentActivity(companyId: cId, agentId: w.eng1.id, limit: 5, owner: owner)
        case "leasedItemKey":
            _ = try s.leasedItemKey(companyId: cId, agentId: w.eng1.id, owner: owner)
        case "viewOriginal":
            _ = try s.viewOriginal(companyId: cId, ref: try w.ref("F-1"), knownValues: [], paths: paths, owner: owner)
        default:
            Issue.record("unknown api \(api)")
        }
        // The app refuses every owner action without a principal, before any Store call.
        let app = await w.app()
        app.owner = nil
        let before = try w.count("message")
        #expect(await app.share(refs: [ref], to: "@eng-1", note: nil) == false)
        #expect(app.errorMessage == Store.refUnavailable)
        #expect(try w.count("message") == before)
        app.errorMessage = nil
        await app.openRef(ref, origin: .owner)
        #expect(app.previewNav.opened == nil && app.errorMessage == Store.refUnavailable)
    }

    @Test func ownerOnlyAPIsHaveNoTool() {
        let tools = Set(CompanyToolNames.all + CompanyToolNames.concierge)
        for name in ["purge", "view_original", "viewOriginal", "purge_ref", "export", "export_ref", "renderRef", "render_ref", "ownerShare", "owner_share",
                     "ownerThreadReply", "owner_thread_reply", "openShowRequests", "open_show_requests", "recordOwnerRead", "record_owner_read",
                     "requireOwner", "establish_owner", "addDiffComment", "add_diff_comment", "requestHunkRevert", "request_hunk_revert",
                     "resolveDiffComment", "resolve_diff_comment"] {
            #expect(!tools.contains(name), "\(name)")
        }
    }
}
