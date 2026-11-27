import Foundation

extension Orchestrator {
    /// The measure recorder (Plan X6a Task 5, ruling R5), once per tick and last, after dispatch: it sees this tick's usage
    /// decisions, the turns running after this tick's launches, and exactly the seconds the company clock accrued this tick.
    /// It only adds to its own counters (company-active seconds are the clock's, written when they accrue); a failure is logged and
    /// the engine goes on (dispatch has already run, and the next tick records again). A tick it could not record is missing from
    /// the idle counters, never filled in.
    func measureTick(companies: [Company], decisions: [String: UsageDecision], paceClosed: Set<String>, paceStrict: Set<String>,
                     activeDelta: [String: TimeInterval], ownerReserve: Double, now: Date) {
        let tick = MeasureRecorder.Tick(decisions: decisions, paceClosed: paceClosed, paceStrict: paceStrict,
                                        runningByCompany: runningByCompany, activeDelta: activeDelta, ownerReserve: ownerReserve)
        var failure: String? = nil
        do {
            try MeasureRecorder.record(store: store, companies: companies, tick: tick, now: now)
        } catch {
            failure = "\(error)"
        }
        // Logged on the first failure, when the error changes, and once on recovery: never a line per tick.
        if let line = measureFailures.note(failure) { log(line) }
    }
}
