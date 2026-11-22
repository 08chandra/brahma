import Foundation

extension Orchestrator {
    /// Plan C Task C4c: the owner lane (design §2.3). At most `ConciergeCaps.laneSize` concierge runs at a time, outside every
    /// company's mode concurrency; a run starts only when nothing holds admission (`held`: the owner's stop, an engine hold,
    /// secrets not loaded), the request's company has its five-hour gate open and is not past its weekly reserve, and the Mac has
    /// room (`OwnerLane.tryAdmit`: the safety cap and memory pressure). The stored values are read from the engine's vault before
    /// the run; a vault that can't give them expires the request (fail closed).
    func conciergeTick(cfg: SchedulerConfig, decisions: [String: UsageDecision], paceStrict: Set<String>, held: Bool,
                       pressure: MemoryPressure) {
        guard !held, conciergeTasks.count < ownerLane.capacity else { return }
        guard let request = try? store.nextConciergeRequest(), conciergeTasks[request.id] == nil else { return }
        let usage: UsageDecision = paceStrict.contains(request.companyId)
            ? .closed(until: clock().addingTimeInterval(Self.usageRetry)) : decisions[request.companyId] ?? .open
        let children = runningCount() + otherChildren + previewChildren + conciergeTasks.count
        guard ownerLane.tryAdmit(request.id, store: store, usage: usage, pressure: pressure, children: children,
                                 safetyCap: cfg.safetyCap) else { return }
        let (store, runner, paths, mcp, env, vault, records, lane, blocking, clock) =
            (self.store, self.runner, self.paths, self.mcpExecutable, self.mcpEnvironment, self.vault, self.turnRecordDirectory,
             self.ownerLane, self.blocking, self.clock)
        conciergeTasks[request.id] = Task.detached { [self] in
            defer { lane.finish(request.id) }
            let known: [(name: String, value: String)]? = await blocking.run {
                try? store.allKnownSecretValues(companyId: request.companyId, vault: vault)
            }
            if let known {
                let outcome = await ConciergeRun.perform(store: store, runner: runner, paths: paths, request: request, mcpExecutable: mcp,
                                                         mcpEnvironment: env, knownValues: known, turnRecordDirectory: records,
                                                         blocking: blocking, clock: clock)
                if case .expired(let why) = outcome { log("concierge request \(request.number) of \(request.companyId) expired: \(why)") }
            } else {
                attempt {
                    try store.writer.write { db in
                        try Store.expireShowRequest(db: db, request, reason: "the stored secrets could not be read to check the answer",
                                                    now: clock())
                    }
                }
            }
            await conciergeDone(request.id)
        }
    }

    func conciergeDone(_ requestId: String) { conciergeTasks[requestId] = nil }
}
