import Foundation
import BrahmaCore
import BrahmaAppModel
import BrahmaKeychain

/// Any Keychain call in this process crashes instead of prompting the owner (see the BrahmaCoreTests twin).
let keychainTrapArmed: Bool = {
    if ProcessInfo.processInfo.environment["BRAHMA_LIVE_KEYCHAIN"] == "1" { return false }
    KeychainAccessLog.forbid()
    return true
}()

/// A directory for this test case under the process root (`TestScratch.swift`), removed when the case ends.
func tempDir() throws -> URL {
    _ = keychainTrapArmed
    return try Scratch.dir()
}

func makeHome() throws -> (Store, BrahmaPaths) {
    let home = try tempDir()
    // Beside the data home, not inside it: a workspace inside the data home can never be sandboxed (5-lite).
    let paths = BrahmaPaths(home: home, workspaces: try tempDir().appending(path: "workspaces", directoryHint: .isDirectory))
    try FileManager.default.createDirectory(at: paths.workspaces, withIntermediateDirectories: true)
    return (try Store(path: paths.database.path), paths)
}

/// Acme: ceo ready, cto sleeping, eng blocked on the owner. Plus an empty company "Globex".
@discardableResult
func seedAcme(_ s: Store, _ p: BrahmaPaths) throws -> (Company, ceo: Agent, cto: Agent, eng: Agent) {
    var acme = try s.createCompany(name: "Acme", goal: "Build", workspacesRoot: p.workspaces)
    // 3a's app tests run on the Workspace profile (5-lite's sandboxed default has its own tests in BrahmaCoreTests).
    try s.updateSandbox(companyId: acme.id, SandboxPatch(profile: .workspace), userHome: try tempDir())
    acme = try s.company(id: acme.id) ?? acme
    let ceo = try s.hire(companyId: acme.id, name: "ceo", role: "ceo", model: "sonnet")
    let cto = try s.hire(companyId: acme.id, name: "cto", role: "cto", model: "sonnet")
    let eng = try s.hire(companyId: acme.id, name: "eng", role: "engineer", model: "sonnet")
    let ceoReady = try s.transition(agentId: ceo.id, to: .ready)
    let engBlocked = try s.transition(agentId: eng.id, to: .blocked, blocker: .owner(reason: "key"))
    _ = try s.createCompany(name: "Globex", goal: "Other", workspacesRoot: p.workspaces)
    return (acme, ceoReady, cto, engBlocked)
}

extension AppModel {
    /// The test `AppModel`: its secret store is a `MemoryVault` (no test touches the Keychain).
    convenience init(store: Store, paths: BrahmaPaths, clock: @escaping @Sendable () -> Date = { .now }) {
        self.init(store: store, paths: paths, secretVault: MemoryVault(), clock: clock)
        // Plan C: renders read no archive or PDF (nothing is spawned), and navigation state never touches the real defaults.
        refArchives = { _, _, _ in UnavailableArchiveReader() }
        navDefaults = UserDefaults(suiteName: "brahma.tests.appmodel.\(UUID().uuidString)") ?? .standard
    }
}

@MainActor
func eventually(timeout: Duration = .seconds(60), _ cond: () throws -> Bool) async throws {
    let deadline = AwakeTime.now + timeout
    while AwakeTime.now < deadline {
        if try cond() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    struct Timeout: Error {}
    if try !cond() { throw Timeout() }
}

/// Stub `TurnRunning` for engine tests: either completes every turn at once or hangs until cancelled.
final class StubRunner: TurnRunning, @unchecked Sendable {
    enum Mode { case succeed, hangUntilCancelled }

    private let mode: Mode
    private let childrenNeverExit: Bool
    private let lock = NSLock()
    private var _requestCount = 0

    init(mode: Mode, childrenNeverExit: Bool = false) {
        self.mode = mode
        self.childrenNeverExit = childrenNeverExit
    }

    var requestCount: Int { lock.withLock { _requestCount } }

    /// Nothing of an earlier turn is ever left over here (the protocol's default fails closed).
    func waitForTurnProcesses(agentId: String, records: URL) async throws -> TurnLeftovers { TurnLeftovers() }

    func run(_ request: TurnRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.withLock { _requestCount += 1 }
        let sid = request.agent.sessionId
        let mode = self.mode
        return AsyncThrowingStream { continuation in
            switch mode {
            case .succeed:
                continuation.yield(.initialized(sessionId: sid, model: "stub"))
                continuation.yield(.result(TurnResult(isError: false, subtype: "success", text: "ok", costUSD: 0,
                                                      apiErrorStatus: nil, sessionId: sid)))
                continuation.finish()
            case .hangUntilCancelled:
                break  // yields nothing; the stream ends when the consumer is cancelled
            }
        }
    }

    func waitForChildren() async {
        guard childrenNeverExit else { return }
        await Task.detached { try? await Task.sleep(for: .seconds(60)) }.value  // scope-escape: a sleep, no scratch dirs
    }
}
