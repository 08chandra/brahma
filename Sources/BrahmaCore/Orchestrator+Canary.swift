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
    /// The fingerprint is a `stat`, cached this many awake seconds (the probe file's digest too).
    public var fingerprintCacheSeconds: Double = 5
    /// The owner's canary probe file's digest (`CanaryProbes.digest`): part of every canary key, so an edit needs a new pass.
    public var probesDigest: @Sendable (BrahmaPaths) -> String = { CanaryProbes.digest(paths: $0) }

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
    /// Whether the running CLI build passed Task 10's `V-1` hook gate. Without a canary gate (no CLI to fingerprint) or a
    /// fingerprint, it has not (fail closed: fan-out turns are pre-tainted).
    func postToolGateVerified() -> Bool {
        guard let gate = sandboxCanary, let fp = try? cliFingerprint(gate: gate) else { return false }
        return (try? store.hookGatePassed(TaintPolicy.postToolGate, fingerprint: fp.key)) ?? false
    }

    static func canaryTaskName(_ key: SandboxCanaryKey) -> String { canaryTaskPrefix + key.text }

    /// The running CLI's fingerprint (a `stat`, cached for 5 s of awake time).
    func cliFingerprint(gate: SandboxCanaryGate) throws -> CLIFingerprint {
        let now = AwakeTime.uptime()
        if let cached = fingerprintCache, now - cached.at < gate.fingerprintCacheSeconds { return cached.value }
        let fp = try gate.fingerprint(gate.claudePath)
        fingerprintCache = (fp, now)
        return fp
    }

    /// The canary key of a sandboxed turn of this shape: the CLI build and the owner's probe file
    /// (`CanaryProbes.keyFingerprint`, both cached for 5 s of awake time), the shape, this macOS. A missing or invalid probe
    /// file has a digest no canary row ever carries, so the turn stays blocked (fail closed).
    func canaryKey(gate: SandboxCanaryGate, shape: String) throws -> SandboxCanaryKey {
        let fp = try cliFingerprint(gate: gate)
        let now = AwakeTime.uptime()
        let digest: String
        if let cached = probesDigestCache, now - cached.at < gate.fingerprintCacheSeconds {
            digest = cached.value
        } else {
            digest = gate.probesDigest(paths)
            probesDigestCache = (digest, now)
        }
        return SandboxCanaryKey(fingerprint: CanaryProbes.keyFingerprint(cli: fp.key, probes: digest), shape: shape,
                                osVersion: gate.osVersion(), cliVersion: (try? store.latestProbe())?.cliVersion)
    }

    /// Before a sandboxed turn launches (before anything of it is consumed or created): its key must have passed the canary.
    /// Otherwise the agent waits (`canaryWaiting`, filtered out before `Scheduler.select`), a canary run is scheduled for the
    /// key with `settings`, the wait is logged once per key, and `SandboxNotVerified` is thrown. A CLI that cannot be
    /// fingerprinted fails the turn (`SandboxRefusal`), never launches it. `launch`: the turn's fan-out shape (Task 14u,
    /// `CanaryShape.launch`), which has a key of its own.
    nonisolated func requireSandboxVerified(gate: SandboxCanaryGate, settings: ClaudeSettings, agent: Agent, company: Company,
                                            launch: String? = nil) async throws {
        let key: SandboxCanaryKey
        do { key = try await canaryKey(gate: gate, shape: CanaryShape.key(settings, launch: launch)) } catch {
            throw SandboxRefusal(reason: "\(error)")
        }
        if try store.sandboxVerified(key) { return }
        await waitForCanary(key, settings: settings, agent: agent, company: company)
        throw SandboxNotVerified(key: key)
    }

    private func waitForCanary(_ key: SandboxCanaryKey, settings: ClaudeSettings, agent: Agent, company: Company) {
        canaryWaiting[agent.id] = key
        if canarySettings[key.text] == nil { canarySettings[key.text] = settings }
        if canaryLogged.insert(key.text).inserted {
            let text = "sandbox not verified (claude \(key.cliVersion ?? "?"), new settings shape or macOS update); checking"
            attempt {
                try store.appendEvent(ActivityEvent(companyId: company.id, agentId: agent.id, turnId: nil, kind: .usage,
                                                    text: text, createdAt: clock()))
            }
        }
        scheduleCanary(key)
    }

    /// Each tick, before `Scheduler.select` (I1): drops waits whose agent no longer runs sandboxed, frees the agents of a key in
    /// back-off that passed meanwhile (`brahma canary run` records passes outside the engine: one query per such key), starts
    /// the next due canary, and returns the agents still waiting, which get no slot. Otherwise from memory only.
    func canaryTick(ready: [Agent], companies: [String: Company]) -> Set<String> {
        guard !canaryWaiting.isEmpty else { return [] }
        for a in ready where canaryWaiting[a.id] != nil {
            if let c = companies[a.companyId], turnProfile(agent: a, company: c) != .sandboxed { canaryWaiting[a.id] = nil }
        }
        var freed = false
        for key in Set(canaryWaiting.values) where canaryFailedAt[key.text] != nil {
            guard (try? store.sandboxVerified(key)) == true else { continue }
            canaryWaiting = canaryWaiting.filter { $0.value != key }
            canaryFailedAt[key.text] = nil
            canaryFailures[key.text] = nil
            freed = true
            log("sandbox canary pass found for a waiting key (recorded outside the engine); its agents start")
        }
        pruneCanaryFailures()
        // The pinned alert is answered once no key that agents still wait on is failing (M2).
        if freed, canaryFailedAt.isEmpty {
            let now = clock()
            attempt { try store.resolveSandboxCheckAlert(now: now) }
        }
        for key in Set(canaryWaiting.values).sorted(by: { $0.text < $1.text }) { scheduleCanary(key) }
        return Set(canaryWaiting.keys)
    }

    /// Forgets the failure state (time and count) of every key no agent waits on any more, so a stale failing key never holds
    /// back answering the sandbox-check alert and a key asked for again starts its back-off over.
    func pruneCanaryFailures() {
        let live = Set(canaryWaiting.values.map(\.text))
        canaryFailedAt = canaryFailedAt.filter { live.contains($0.key) }
        canaryFailures = canaryFailures.filter { live.contains($0.key) }
    }

    /// Whether `agent` still waits for a canary (the backstop in `launch`): until its key passed, or its company no longer runs
    /// it sandboxed.
    func canaryHeld(_ agent: Agent) -> Bool {
        guard let key = canaryWaiting[agent.id] else { return false }
        let stillSandboxed = (try? store.company(id: agent.companyId)).flatMap { $0 }.map { turnProfile(agent: agent, company: $0) == .sandboxed } ?? false
        if !stillSandboxed || (try? store.sandboxVerified(key)) == true {
            canaryWaiting[agent.id] = nil
            pruneCanaryFailures()
            return false
        }
        return true
    }

    /// One canary run at a time engine-wide (M5), detached; a key that did not pass is retried after `retryAfter`; the other
    /// keys wait for later ticks. Nothing starts while the owner's stop holds (final review M1): the canary runs `claude`;
    /// waiting agents stay waiting and their canary runs after the resume.
    func scheduleCanary(_ key: SandboxCanaryKey) {
        guard let gate = sandboxCanary, !engineStoppedNow else { return }
        guard !healthTasks.keys.contains(where: { $0.hasPrefix(Self.canaryTaskPrefix) }) else { return }
        if let failed = canaryFailedAt[key.text],
           AwakeTime.uptime() - failed < Self.canaryRetryDelay(retryAfter: gate.retryAfter, failures: canaryFailures[key.text] ?? 1) { return }
        let paths = self.paths, settings = canarySettings[key.text]
        healthTasks[Self.canaryTaskName(key)] = Task.detached { [self] in
            let run = await gate.canary.run(paths: paths, claudePath: gate.claudePath, runner: gate.runner, key: key, settings: settings)
            // Cut short by the owner's stop (`enforceStop` cancels it): neither a pass nor a failure, it runs again after the resume.
            if Task.isCancelled { await canaryStopped(key) } else { await canaryFinished(key, run: run) }
        }
    }

    func canaryStopped(_ key: SandboxCanaryKey) {
        healthTasks[Self.canaryTaskName(key)] = nil
        log("sandbox canary cut short by the owner's stop; it runs again after the resume")
    }

    /// The owner's stop (final review M1): every running canary is cancelled.
    func cancelCanaries() {
        for (name, task) in healthTasks where name.hasPrefix(Self.canaryTaskPrefix) { task.cancel() }
    }

    static let canaryTaskPrefix = "sandbox-canary:"

    /// The awake time before a key that failed `failures` runs in a row is tried again: `retryAfter`, doubling with each
    /// failure, at most 6 hours (or `retryAfter` itself when that is longer).
    nonisolated static func canaryRetryDelay(retryAfter: TimeInterval, failures: Int) -> TimeInterval {
        let doubled = retryAfter * pow(2, Double(max(0, min(failures - 1, 16))))
        return min(doubled, max(retryAfter, 6 * 3600))
    }

    /// A pass (every item, for exactly this key: `CanaryRun.passes`) is recorded and frees the agents waiting for it; the
    /// sandbox-check alert is answered only when no other key is failing (M2). Anything else raises the pinned sandbox-check
    /// alert once while it is open, and the key is retried later.
    func canaryFinished(_ key: SandboxCanaryKey, run: CanaryRun) {
        healthTasks[Self.canaryTaskName(key)] = nil
        let now = clock()
        if run.passes(key) {
            canaryFailedAt[key.text] = nil
            canaryFailures[key.text] = nil
            canarySettings[key.text] = nil
            canaryWaiting = canaryWaiting.filter { $0.value != key }
            pruneCanaryFailures()
            // M2: answered only when no key that agents still wait on is failing.
            let resolve = canaryFailedAt.isEmpty
            attempt {
                try store.recordCanary(key, detail: run.detail, now: now, resolveAlert: resolve)
            }
            log("sandbox canary passed (claude \(key.cliVersion ?? "?"))")
            return
        }
        canaryFailedAt[key.text] = AwakeTime.uptime()
        canaryFailures[key.text, default: 0] += 1
        // The CLI build or macOS changed under the wait: this key can never be verified again, so its agents go back to the
        // gate, which asks for the current key.
        if let verified = run.verified, verified.fingerprint != key.fingerprint || verified.osVersion != key.osVersion {
            canaryWaiting = canaryWaiting.filter { $0.value != key }
            canarySettings[key.text] = nil
            pruneCanaryFailures()
        }
        var bad = run.items.filter { $0.status != .pass }.map { "\($0.name): \($0.detail)" }
        if run.verified != key, !run.items.isEmpty { bad.append("canary shape differs from the turn's (nothing recorded)") }
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
