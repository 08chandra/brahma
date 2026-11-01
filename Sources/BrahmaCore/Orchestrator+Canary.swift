import Foundation
import GRDB

/// The per-launch sandbox gate's parts (Task 3): the canary to run, the runner and CLI it checks, and how it reads the machine.
public struct SandboxCanaryGate: Sendable {
    public var canary: any SandboxCanaryRunning
    public var runner: any TurnRunning
    public var claudePath: String
    /// Awake seconds before a key whose canary did not pass is tried again.
    public var retryAfter: TimeInterval
    public var fingerprint: @Sendable (String) throws -> CLIFingerprint
    public var osVersion: @Sendable () -> String
    /// The fingerprint is a `stat`, cached this many awake seconds.
    public var fingerprintCacheSeconds: Double = 5

    public init(canary: any SandboxCanaryRunning, runner: any TurnRunning, claudePath: String, retryAfter: TimeInterval = 600,
                fingerprint: @escaping @Sendable (String) throws -> CLIFingerprint = { try CLIFingerprint.of(claudePath: $0) },
                osVersion: @escaping @Sendable () -> String = { ProcessInfo.processInfo.operatingSystemVersionString }) {
        self.canary = canary; self.runner = runner; self.claudePath = claudePath; self.retryAfter = retryAfter
        self.fingerprint = fingerprint; self.osVersion = osVersion
    }
}

/// A sandboxed turn that did not start because no canary passed for its key: nothing ran, the agent is ready again.
struct SandboxNotVerified: Error, CustomStringConvertible {
    var key: SandboxCanaryKey
    var description: String { "sandbox not verified" }
}

extension Orchestrator {
    static func canaryTaskName(_ key: SandboxCanaryKey) -> String { "sandbox-canary:\(key.text)" }

    /// The canary key of a sandboxed turn of this shape (the fingerprint cached for 5 s of awake time).
    func canaryKey(gate: SandboxCanaryGate, shape: String) throws -> SandboxCanaryKey {
        let now = AwakeTime.uptime()
        let fp: CLIFingerprint
        if let cached = fingerprintCache, now - cached.at < gate.fingerprintCacheSeconds {
            fp = cached.value
        } else {
            fp = try gate.fingerprint(gate.claudePath)
            fingerprintCache = (fp, now)
        }
        return SandboxCanaryKey(fingerprint: fp.key, shape: shape, osVersion: gate.osVersion(),
                                cliVersion: (try? store.latestProbe())?.cliVersion)
    }

    /// Before a sandboxed turn launches: its key must have passed the canary. Otherwise the agent waits (`canaryHeld`), one
    /// canary run is scheduled for the key, the wait is logged once per key, and `SandboxNotVerified` is thrown.
    nonisolated func requireSandboxVerified(gate: SandboxCanaryGate, shape: String, agent: Agent, company: Company) async throws {
        let key: SandboxCanaryKey
        do { key = try await canaryKey(gate: gate, shape: shape) } catch {
            throw SandboxRefusal(reason: "\(error)")
        }
        if try store.sandboxVerified(key) { return }
        await waitForCanary(key, agent: agent, company: company)
        throw SandboxNotVerified(key: key)
    }

    private func waitForCanary(_ key: SandboxCanaryKey, agent: Agent, company: Company) {
        canaryWaiting[agent.id] = key
        if canaryLogged.insert(key.text).inserted {
            let text = "sandbox not verified (claude \(key.cliVersion ?? "?"), new settings shape or macOS update); checking"
            attempt {
                try store.appendEvent(ActivityEvent(companyId: company.id, agentId: agent.id, turnId: nil, kind: .usage,
                                                    text: text, createdAt: clock()))
            }
        }
        scheduleCanary(key)
    }

    /// Whether `agent` still waits for a canary: until its key passed, or its company no longer runs it sandboxed.
    func canaryHeld(_ agent: Agent) -> Bool {
        guard let key = canaryWaiting[agent.id] else { return false }
        let stillSandboxed = (try? store.company(id: agent.companyId)).flatMap { $0 }.map { turnProfile(agent: agent, company: $0) == .sandboxed } ?? false
        if !stillSandboxed || (try? store.sandboxVerified(key)) == true {
            canaryWaiting[agent.id] = nil
            return false
        }
        scheduleCanary(key)
        return true
    }

    /// One canary run per key at a time, detached; a key that did not pass is retried after `retryAfter`.
    func scheduleCanary(_ key: SandboxCanaryKey) {
        guard let gate = sandboxCanary else { return }
        let name = Self.canaryTaskName(key)
        guard healthTasks[name] == nil else { return }
        if let failed = canaryFailedAt[key.text], AwakeTime.uptime() - failed < gate.retryAfter { return }
        let paths = self.paths
        healthTasks[name] = Task.detached { [self] in
            let items = await gate.canary.run(paths: paths, claudePath: gate.claudePath, runner: gate.runner, shape: key.shape)
            await canaryFinished(key, items: items)
        }
    }

    /// A pass (every item) is recorded and answers the alert; anything else raises the pinned sandbox-check alert once while
    /// it is open, and the key is retried later.
    func canaryFinished(_ key: SandboxCanaryKey, items: [DoctorItem]) {
        healthTasks[Self.canaryTaskName(key)] = nil
        let now = clock()
        if !items.isEmpty, items.allSatisfy({ $0.status == .pass }) {
            canaryFailedAt[key.text] = nil
            attempt { try store.recordCanary(key, detail: items.map { "\($0.name): \($0.detail)" }.joined(separator: "; "), now: now) }
            log("sandbox canary passed (claude \(key.cliVersion ?? "?"))")
            return
        }
        canaryFailedAt[key.text] = AwakeTime.uptime()
        let bad = items.filter { $0.status != .pass }.map { "\($0.name): \($0.detail)" }
        let detail = bad.isEmpty ? "the canary reported nothing" : bad.joined(separator: "; ")
        log("sandbox canary did not pass: \(detail)")
        attempt {
            try store.writer.write { db in
                let open = try Ask.filter(Column("kind") == AskKind.engineAlert && Column("status") == AskStatus.pendingOwner.rawValue
                                          && Column("subjectId") == EngineAlerts.askSubject(reason: EngineAlerts.sandboxCheckReason)).fetchCount(db)
                guard open == 0 else { return }
                try EngineAlerts.raise(store: store, db: db,
                                       text: "Sandbox check failed: \(Store.flat(detail, max: 600)). Agents in sandboxed companies are paused; run brahma doctor.",
                                       now: now, reason: EngineAlerts.sandboxCheckReason)
            }
        }
    }
}
