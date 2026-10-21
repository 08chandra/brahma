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
        await Task.detached { try? await Task.sleep(for: .seconds(60)) }.value
    }
}
