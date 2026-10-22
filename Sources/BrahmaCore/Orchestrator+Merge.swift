import Foundation

extension Orchestrator {
    /// Seconds before a company whose merge could not run (the checkout is not on `main`, git failed) is tried again.
    static let mergeRetry: TimeInterval = 60

    /// Once per tick, after the checks: starts the merge of each company's oldest approved item, one per company, into slots the
    /// safety cap has free. Nothing starts under a hold, critical memory pressure or for a paused company.
    func startMerges(now: Date, config: SchedulerConfig, held: Bool, pressure: MemoryPressure, companies: [Company]) {
        guard !held, pressure != .critical else { return }
        mergeBackoff = mergeBackoff.filter { $0.value > now }
        for company in companies where company.status == .running && mergeTasks[company.id] == nil && mergeBackoff[company.id] == nil {
            let slots = Scheduler.freeSlots(config: config, running: runningCount(), otherChildren: otherChildren,
                                            pressure: pressure, held: held)
            guard slots > 0 else { return }
            guard let item = try? store.nextPendingMerge(companyId: company.id) else { continue }
            mergeTasks[company.id] = Task.detached { [self] in
                await performMerge(company: company, item: item)
                await mergeEnded(companyId: company.id)
            }
        }
    }

    func mergeEnded(companyId: String) { mergeTasks[companyId] = nil }

    func holdMerges(companyId: String, until: Date) { mergeBackoff[companyId] = until }

    /// The git work for one approved item, then its recording (`finishMerge`), all off the actor. A merge that could not run
    /// is not tried again for `mergeRetry` seconds; its item stays `pending`.
    nonisolated func performMerge(company: Company, item: WorkItem) async {
        do {
            guard let result = try store.performMerge(item: item, company: company, now: clock()) else {
                await holdMerges(companyId: company.id, until: clock().addingTimeInterval(Self.mergeRetry))
                return
            }
            try store.finishMerge(itemId: item.id, result: result, now: clock())
        } catch {
            log("could not merge \(item.key): \(error)")
            await holdMerges(companyId: company.id, until: clock().addingTimeInterval(Self.mergeRetry))
        }
    }
}
