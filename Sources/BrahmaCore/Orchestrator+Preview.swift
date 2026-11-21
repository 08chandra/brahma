import Foundation

extension Orchestrator {
    /// The tick's "preview" step (PR-6): when no pass is in flight, one `PreviewRunner.reconcile` runs as a tracked detached
    /// task (part of `isIdle`; its starts are the runner's own tracked tasks, and the processes they leave running count in
    /// the safety cap through `previewRunner.activeChildren`). Nothing starts under an engine hold. All git and file work of a
    /// pass runs inside the shared `Blocking` (the runner holds this engine's).
    ///
    /// Plan 4a Task 7, the "demos" step: when a sprint in `review` has no demo yet (`DemoRunner.pending`), the pass is its
    /// sprint-review demo instead (`PreviewRunner.demo(sprint:)`, which reconciles first), one sprint per pass and never on two
    /// passes in a row (`lastPreviewTickWasDemo`), so a demo that cannot complete never starves the reconcile pass. Nothing
    /// while the owner's stop holds: `held` covers it here, and the runner reads the stop again before it runs or writes.
    func previewTick(held: Bool) {
        guard !held, previewTask == nil else { return }
        let (runner, clock, store) = (previewRunner, self.clock, self.store)
        if !lastPreviewTickWasDemo, let sprint = ((try? DemoRunner.pending(store: store)) ?? []).first {
            lastPreviewTickWasDemo = true
            previewTask = Task.detached { [self] in
                await asEngine { _ = await runner.demo(sprint: sprint) }
                await previewEnded()
            }
            return
        }
        lastPreviewTickWasDemo = false
        previewTask = Task.detached { [self] in
            await asEngine { await runner.reconcile(now: clock()) }
            await previewEnded()
        }
    }

    func previewEnded() { previewTask = nil }

    /// The default preview dependencies: the platform sandbox (Seatbelt on macOS, else fail closed) with the checks' baseline
    /// (`checkBaseline`), the real probes and a fresh process table; Full companies' previews use `UnsandboxedPreviewRunner`.
    static func defaultPreviewDependencies(store: Store, paths: BrahmaPaths) -> PreviewDependencies {
        let baseline: @Sendable () -> SandboxBaseline = { checkBaseline(store: store, paths: paths) }
        return .live(sandbox: SandboxRunners.platformDefault(baseline: baseline, proxies: EgressProxyPool(), onStraggler: { report in
            let pids = (report.killed + report.survivors).map(String.init).joined(separator: ", ")
            FileHandle.standardError.write(Data("brahma orchestrator: a preview left processes outside its group (pid \(pids))\n".utf8))
        }))
    }
}
