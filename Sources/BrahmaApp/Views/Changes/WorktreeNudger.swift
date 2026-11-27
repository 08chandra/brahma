import Foundation
import BrahmaCore

/// The worktree a `WorktreeNudger` watches: the company, the item key the engine listed as a leased worktree in place, and its
/// path (`GitWorkspace.worktreePath`, path arithmetic only).
struct NudgeTarget: Equatable, Sendable {
    let companyId: String
    let key: String
    let path: String
}

#if canImport(CoreServices)
import CoreServices

/// Plan C Task C7c: an FSEvents stream on the shown item's worktree that asks the engine for an early recompute
/// (`LiveChanges.nudge`) once file events settle for `ChangesLimits.nudgeDebounce` (300 ms). It only nudges: no file is opened or
/// read in the app process, and no git runs here — the engine's loop does the work off the main actor and keeps its pinned rate
/// limit (one recompute per 2 s per item and compare). Without it the engine's poll alone keeps the view live.
final class WorktreeNudger: @unchecked Sendable {
    private let queue = DispatchQueue(label: "brahma.worktree-nudger")
    private let fire: @Sendable () -> Void
    /// Touched only on `queue`.
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    init?(path: String, fire: @escaping @Sendable () -> Void) {
        self.fire = fire
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<WorktreeNudger>.fromOpaque(info).takeUnretainedValue().changed()
        }
        guard let made = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [path] as CFArray,
                                             FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05,
                                             FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return nil }
        queue.sync {
            stream = made
            FSEventStreamSetDispatchQueue(made, queue)
            FSEventStreamStart(made)
        }
    }

    deinit { stop() }

    /// Stops the stream; no callback or nudge runs after it returns.
    func stop() {
        queue.sync {
            pending?.cancel()
            pending = nil
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// On `queue`: a file event restarts the debounce; the nudge goes when events have been quiet for the debounce.
    private func changed() {
        guard stream != nil else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [fire] in fire() }
        pending = work
        let debounce = ChangesLimits.nudgeDebounce.components
        let ms = Int(debounce.seconds) * 1000 + Int(debounce.attoseconds / 1_000_000_000_000_000)
        queue.asyncAfter(deadline: .now() + .milliseconds(ms), execute: work)
    }

    /// Watches `target` until the calling task is cancelled (the view went away or the target changed).
    static func watch(_ target: NudgeTarget, live: LiveChanges) async {
        let (companyId, key) = (target.companyId, target.key)
        guard let nudger = WorktreeNudger(path: target.path, fire: { Task { await live.nudge(companyId: companyId, key: key) } }) else { return }
        defer { nudger.stop() }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
    }
}
#else
/// Without FSEvents the engine's 2 s poll alone keeps the view live.
enum WorktreeNudger {
    static func watch(_ target: NudgeTarget, live: LiveChanges) async {}
}
#endif
