import Testing
import Foundation
import GRDB
@testable import BrahmaCore
@testable import BrahmaAppModel

/// C6 fix round 3, controller Rulings C6-3 (I-1) and C6-4: agent mode binds `mint` whatever its arguments, and every public owner
/// entry point the final wave hasn't tokenised yet refuses in an agent process before any lookup (`ProcessRole.refuseInAgentProcess`).
/// Agent mode is simulated for the test's own task (`simulatingAgentProcess`), so the process-wide mode of the test process is never
/// touched.
@MainActor @Suite(.scratch) struct AgentModeGuardTests {
    nonisolated static let entryPoints = ["ownerDecide", "ownerAnswer", "ownerRescind", "acknowledge", "vouchFile(companyId)", "vouchFile(alertAskId)",
                                          "vouchResource", "purgeResource", "setResourceScope", "approveAccess", "provideSecret",
                                          "declineFileRequest", "answerFileRequest"]

    @Test func mintRefusesInAgentModeWhateverTheArguments() throws {
        try OwnerPrincipal.simulatingAgentProcess {
            #expect(OwnerPrincipal.processRole == .agent)
            #expect(throws: OwnerPrincipalError.self) { try OwnerPrincipal.mint() }
            // I-1: the seam can't lift agent mode.
            #expect(throws: OwnerPrincipalError.self) { try OwnerPrincipal.mint(role: .owner, environment: [:], ancestors: [1], runningTurnPids: []) }
            #expect(throws: OwnerPrincipalError.self) { try OwnerPrincipal.mint(role: .unknown, environment: [:], ancestors: [1], runningTurnPids: []) }
            #expect(throws: WorkError.self) { try ProcessRole.refuseInAgentProcess() }
        }
        // An owner surface: both work.
        _ = try OwnerPrincipal.mint()
        try ProcessRole.refuseInAgentProcess()
        // The seam still simulates an agent role for a test of the refusal itself.
        #expect(throws: OwnerPrincipalError.self) { try OwnerPrincipal.mint(role: .agent, environment: [:], ancestors: [1], runningTurnPids: []) }
    }

    /// Round 4, N-1: the test override can only force agent mode, never lift it. A process whose stored role is `.agent` is an
    /// agent's whatever the simulation says (`effectiveRole` is what `processRole`, `mint` and the guard read); a nested simulation
    /// stays agent; and the override is a private `Bool` nothing outside `OwnerPrincipal.swift` names, so no code can bind it to
    /// `.owner` (or to anything but agent mode).
    @Test func overrideNeverLiftsAgentMode() throws {
        for simulated in [false, true] {
            #expect(OwnerPrincipal.effectiveRole(stored: .agent, simulatedAgent: simulated) == .agent, "stored agent, simulated \(simulated)")
            for stored in [ProcessRole.unknown, .owner] {
                #expect(OwnerPrincipal.effectiveRole(stored: stored, simulatedAgent: simulated) == (simulated ? .agent : stored), "\(stored), \(simulated)")
            }
        }
        try OwnerPrincipal.simulatingAgentProcess {
            try OwnerPrincipal.simulatingAgentProcess { #expect(OwnerPrincipal.processRole == .agent) }
            #expect(OwnerPrincipal.processRole == .agent)
            #expect(throws: OwnerPrincipalError.self) { try OwnerPrincipal.mint() }
            for role: ProcessRole? in [.owner, .unknown, nil] {
                #expect(throws: OwnerPrincipalError.self) { try OwnerPrincipal.mint(role: role, environment: [:], ancestors: [], runningTurnPids: []) }
            }
            #expect(throws: WorkError.self) { try ProcessRole.refuseInAgentProcess() }
        }
        // Test-scoped: no source file but `OwnerPrincipal.swift` names the override, and that file binds it only to `true`.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appending(path: "Sources")
        let walker = try #require(FileManager.default.enumerator(atPath: sources.path))
        var owner = ""
        for case let rel as String in walker where rel.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appending(path: rel), encoding: .utf8)
            if rel.hasSuffix("Collab/OwnerPrincipal.swift") { owner = text; continue }
            for token in ["simulatedAgent", "simulatingAgentProcess", "roleOverride"] { #expect(!text.contains(token), "\(rel) names \(token)") }
        }
        #expect(!owner.contains("roleOverride"))
        #expect(owner.contains("@TaskLocal private static var simulatedAgent = false"))
        #expect(owner.components(separatedBy: "$simulatedAgent.withValue(").count == 2)
        #expect(owner.contains("$simulatedAgent.withValue(true, operation: body)"))
    }

    @Test(arguments: entryPoints) func ownerEntryPointsRefuseInAgentMode(_ api: String) throws {
        let w = try RefWorld()
        let s = w.store, cId = w.company.id, paths = w.paths, now = w.now
        let vault = ContentVault(paths: paths)
        func call() throws {
            switch api {
            case "ownerDecide": _ = try s.ownerDecide(askId: "nope", approve: true, now: now)
            case "ownerAnswer": _ = try s.ownerAnswer(askId: "nope", text: "x", now: now)
            case "ownerRescind": _ = try s.ownerRescind(askId: "nope", now: now)
            case "acknowledge": _ = try s.acknowledge(askId: "nope", now: now)
            case "vouchFile(companyId)": _ = try s.vouchFile(companyId: cId, fileId: "nope", sha256: "00", now: now)
            case "vouchFile(alertAskId)": _ = try s.vouchFile(alertAskId: "nope", now: now)
            case "vouchResource": _ = try s.vouchResource(companyId: cId, number: 999, contentVault: vault, paths: paths, now: now)
            case "purgeResource": _ = try s.purgeResource(companyId: cId, number: 999, backups: [], contentVault: vault, paths: paths, now: now)
            case "setResourceScope": try s.setResourceScope(companyId: cId, number: 999, scope: .company, futureHolders: false, contentVault: vault, paths: paths)
            case "approveAccess": _ = try s.approveAccess(askId: "nope", scope: .once, duration: .turn, now: now)
            case "provideSecret": _ = try s.provideSecret(askId: "nope", value: "v", isTest: true, vault: MemoryVault(), now: now)
            case "declineFileRequest": _ = try s.declineFileRequest(companyId: cId, askId: "nope", note: "", now: now)
            case "answerFileRequest":
                _ = try s.answerFileRequest(companyId: cId, askId: "nope", plan: DropPlan(), contentVault: vault, secretVault: MemoryVault(),
                                            knownValues: [], paths: paths, now: now)
            default: Issue.record("unknown entry point \(api)")
            }
        }
        // Agent mode: the generic refusal, before any lookup (the ids are bogus on purpose: a lookup would say so instead).
        try OwnerPrincipal.simulatingAgentProcess {
            do {
                try call()
                Issue.record("\(api) ran in agent mode")
            } catch let e as WorkError {
                #expect(e.message == Store.refUnavailable, "\(api): \(e.message)")
            } catch {
                Issue.record("\(api) failed in agent mode with \(error), not the generic refusal")
            }
        }
        // Owner mode: the guard is silent; the call fails on its bogus id (never with the generic refusal) or works.
        do { try call() } catch let e as WorkError { #expect(e.message != Store.refUnavailable, "\(api)") } catch {}
    }
}
