import Foundation
import BrahmaCore

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "brahma-appmodel-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeHome() throws -> (Store, BrahmaPaths) {
    let home = try tempDir()
    let paths = BrahmaPaths(home: home, workspaces: home.appending(path: "workspaces", directoryHint: .isDirectory))
    try FileManager.default.createDirectory(at: paths.workspaces, withIntermediateDirectories: true)
    return (try Store(path: paths.database.path), paths)
}

/// Acme: ceo ready, cto sleeping, eng blocked on the owner. Plus an empty company "Globex".
@discardableResult
func seedAcme(_ s: Store, _ p: BrahmaPaths) throws -> (Company, ceo: Agent, cto: Agent, eng: Agent) {
    let acme = try s.createCompany(name: "Acme", goal: "Build", workspacesRoot: p.workspaces)
    let ceo = try s.hire(companyId: acme.id, name: "ceo", role: "ceo", model: "m")
    let cto = try s.hire(companyId: acme.id, name: "cto", role: "cto", model: "m")
    let eng = try s.hire(companyId: acme.id, name: "eng", role: "engineer", model: "m")
    let ceoReady = try s.transition(agentId: ceo.id, to: .ready)
    let engBlocked = try s.transition(agentId: eng.id, to: .blocked, blocker: .owner(reason: "key"))
    _ = try s.createCompany(name: "Globex", goal: "Other", workspacesRoot: p.workspaces)
    return (acme, ceoReady, cto, engBlocked)
}

@MainActor
func eventually(timeout: Duration = .seconds(3), _ cond: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try cond() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    struct Timeout: Error {}
    if try !cond() { throw Timeout() }
}
