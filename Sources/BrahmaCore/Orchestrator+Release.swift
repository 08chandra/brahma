import Foundation

extension Orchestrator {
    /// The tick's "main smoke" step (Plan L Task 5, PR-6), per company:
    /// - when the company has a smoke check and its engine-accepted `main` (`company.mainCommit`, PR-22) has no `merge` run,
    ///   one is queued (a newer queued run supersedes older queued ones, `Store.queueSmoke`);
    /// - the newest queued run is executed as a tracked detached task (`smokeTasks`, counted in `otherChildren`), one at a
    ///   time per company: it holds the company's `smokeSlots` slot, which a release's own smoke shares (PR-36). All git and
    ///   file work of a run happens inside this engine's `Blocking`.
    /// Nothing starts under an engine hold or in a paused company (queued runs wait).
    func smokeTick(now: Date, held: Bool, companies: [Company]) {
        // L-5lite: skip while engineStopped (EmergencyStopObserver, PR-35 part 5s).
        for company in companies {
            attempt { try self.store.queueMergeSmokeIfNeeded(companyId: company.id, now: now) }
            guard !held, company.status == .running, smokeTasks[company.id] == nil,
                  let next = try? self.store.nextQueuedSmoke(companyId: company.id) else { continue }
            let (engineStore, checks, slots, blocking, clock) = (self.store, smokeChecks, smokeSlots, self.blocking, self.clock)
            let companyId = company.id
            smokeTasks[companyId] = Task.detached { [self] in
                await asEngine {
                    await slots.withSlot(companyId) {
                        do { _ = try await engineStore.executeSmoke(runId: next.id, checks: checks, blocking: blocking, clock: clock) } catch {
                            self.log("the smoke run \(next.id) of \(companyId) could not be recorded: \(error)")
                        }
                    }
                }
                await smokeEnded(companyId: companyId)
            }
        }
    }

    func smokeEnded(companyId: String) { smokeTasks[companyId] = nil }

    /// The default smoke runners: the platform sandbox (Seatbelt on macOS, else fail closed) with the checks' baseline
    /// (`checkBaseline`), and the plain group runner for a Full company's smokes (as its checks run, PR-5).
    static func defaultSmokeChecks(store: Store, paths: BrahmaPaths, environment: [String: String]) -> SmokeChecks {
        let baseline: @Sendable () -> SandboxBaseline = { checkBaseline(store: store, paths: paths) }
        let sandbox = SandboxRunners.platformDefault(baseline: baseline, proxies: EgressProxyPool(), onStraggler: { report in
            let pids = (report.killed + report.survivors).map(String.init).joined(separator: ", ")
            FileHandle.standardError.write(Data("brahma orchestrator: a main smoke left processes outside its group (pid \(pids))\n".utf8))
        })
        return SmokeChecks(sandbox: sandbox, unsandboxed: UnsandboxedPreviewRunner(), paths: paths, environment: environment)
    }
}
