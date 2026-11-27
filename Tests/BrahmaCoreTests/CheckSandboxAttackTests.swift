import Testing
import Foundation
@testable import BrahmaCore
@testable import BrahmaSafety

/// Attack suite (c), Ruling A1 (Plan S Task S7): **a postinstall script in a check cannot read `~/.claude`, the Keychain
/// files, the data home or the beacon.** A dependency's install hook runs inside the company's check; it is agent-supplied
/// code with the owner's uid. Run as a real check (the engine's route, `Orchestrator.checkRoute`, deciding the factory's
/// `.check` policy, and the real `SeatbeltRunner`), it must read nothing of the owner's Claude configuration, the login
/// Keychain, the engine's data home, or a beacon token planted in the owner's home, and must not even list those places;
/// the Keychain CLI is refused too. A positive control (its own committed file) shows the script ran.
@Suite(.scratch, .serialized, .enabled(if: Toolchain.seatbeltAvailable, "no /usr/bin/sandbox-exec"))
struct CheckSandboxAttackTests {
    final class PathsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: BrahmaPaths?
        var paths: BrahmaPaths? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    @Test(.timeLimit(.minutes(6)))
    func postinstallCannotReadClaudeKeychainDataHomeOrBeacon() async throws {
        let store = try Store.inMemory()
        let box = PathsBox()
        // The engine's own check baseline (`defaultCheckRunner`): the owner's home, the protected paths, the data home, every
        // workspace. Both the route's decision and the runner's start use it.
        let baseline: @Sendable () -> SandboxBaseline = {
            guard let paths = box.paths else {
                var b = SandboxBaseline.owner(); b.problem = "the test's data home is not set yet"; return b
            }
            return Orchestrator.checkBaseline(store: store, paths: paths)
        }
        let runner = SandboxedCheckRunner(sandbox: SeatbeltRunner(baseline: baseline, proxies: EgressProxyPool()),
                                          route: Orchestrator.checkRoute(store: store, baseline: baseline))
        let world = try World(store: store, checkRunner: runner)
        box.paths = world.paths

        // What the hook goes after. The beacon: a token planted in the owner's real home, outside every place a check names.
        let ownerHome = FileManager.default.homeDirectoryForCurrentUser.resolvedForSandbox   // raw-temp-api: read-only, the home the policy denies
        let beaconToken = "BRAHMA-BEACON-" + UUID().uuidString
        let beacon = try Scratch.homeDir().resolvedForSandbox.appending(path: "beacon.txt")
        try Data(beaconToken.utf8).write(to: beacon)
        let dataToken = "BRAHMA-DATAHOME-" + UUID().uuidString
        try FileManager.default.createDirectory(at: world.paths.home, withIntermediateDirectories: true)
        let dataFile = world.paths.home.resolvedForSandbox.appending(path: "beacon-data.txt")
        try Data(dataToken.utf8).write(to: dataFile)
        // Every target the owner can read outside the sandbox (the positive control for each denial); a missing one proves
        // nothing and is left out.
        let reads = [ownerHome.appending(path: ".claude.json"), ownerHome.appending(path: ".claude/settings.json"),
                     ownerHome.appending(path: ".claude/.credentials.json"), ownerHome.appending(path: "Library/Keychains/login.keychain-db"),
                     dataFile, beacon].filter { FileManager.default.isReadableFile(atPath: $0.path) }
        let lists = [ownerHome.appending(path: ".claude"), ownerHome.appending(path: "Library/Keychains"), world.paths.home.resolvedForSandbox]
            .filter { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) != nil }
        #expect(reads.contains(beacon) && reads.contains(dataFile) && lists.contains(world.paths.home.resolvedForSandbox))
        func q(_ url: URL) -> String { "'" + url.path + "'" }
        let control = "CONTROL-" + UUID().uuidString
        let hook = (["#!/bin/sh", "# A dependency's postinstall: it reads what it can and says so.", "cat ./control.txt"]
            + reads.map { "if cat \(q($0)) 2>/dev/null; then echo \"LEAK read \($0.lastPathComponent)\"; fi" }
            + lists.map { "if ls \(q($0)) >/dev/null 2>&1; then echo \"LEAK list \($0.lastPathComponent)\"; fi" }
            + ["if /usr/bin/security list-keychains >/dev/null 2>&1; then echo 'LEAK security'; fi",
               "if cp \(q(beacon)) ./stolen 2>/dev/null; then echo 'LEAK copy beacon'; fi",
               "echo HOOK-DONE"]).joined(separator: "\n") + "\n"

        // A Workspace-profile company: its checks run sandboxed. The item's check is the hook.
        let company = try world.company("Acme")
        let mgr = try world.hire(company, "mgr", role: "manager")
        let eng = try store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet", managerId: mgr.id)
        let item = try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "Add a dependency", checkSpec: CheckSpec(command: "/bin/sh postinstall.sh", paths: ["postinstall.sh"]),
            status: .ready), now: world.clock.now)
        let tools = CompanyTools(store: store, companyId: company.id, agentId: eng.id)
        _ = try tools.call(name: "claim_lease", arguments: ["key": .string(item.key)])
        let root = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let worktree = store.gitWorkspace(root: root, companyId: company.id).worktreePath(key: item.key)
        try hook.write(to: worktree.appending(path: "postinstall.sh"), atomically: true, encoding: .utf8)
        try control.write(to: worktree.appending(path: "control.txt"), atomically: true, encoding: .utf8)
        _ = try tools.call(name: "submit_for_review", arguments: ["key": .string(item.key), "summary": .string("added it")])
        await world.orchestrator.tick()
        try await world.orchestrator.waitUntilIdle(timeout: .seconds(300))

        let run = try #require(try store.latestVerification(itemId: item.id))
        let tail = run.outputTail ?? ""
        #expect(tail.contains(control) && tail.contains("HOOK-DONE"), "the hook did not run to its end: \(tail)")
        #expect(!tail.contains("LEAK"), "the hook reached a protected place:\n\(tail)")
        #expect(!tail.contains(beaconToken) && !tail.contains(dataToken), "a planted token reached the check's output")
        #expect(run.status == .passed, "\(run.status): \(tail)")
        #expect(!FileManager.default.fileExists(atPath: worktree.appending(path: "stolen").path))
    }
}
