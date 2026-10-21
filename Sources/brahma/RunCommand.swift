import ArgumentParser
import Dispatch
import Foundation
import BrahmaCore

extension PermissionProfile: ExpressibleByArgument {}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the orchestrator in the foreground until Ctrl-C.",
        discussion: "WARNING: --profile full gives agents access to your whole Mac, not just their workspace.")

    @Option(help: "Maximum concurrent turns across all companies.") var hardCap: Int = 16
    @Option(help: "workspace (default) or full.") var profile: PermissionProfile = .workspace

    func validate() throws {
        guard hardCap >= 1 else { throw ValidationError("--hard-cap must be at least 1") }
    }

    func run() async throws {
        // A child or MCP pipe closing under us must surface as EPIPE, not kill the orchestrator.
        signal(SIGPIPE, SIG_IGN)
        let (store, paths) = try openStore()
        let lock: OrchestratorLock
        do {
            lock = try OrchestratorLock.acquire(paths: paths)
        } catch OrchestratorLockError.alreadyRunning {
            throw fail("another Brahma engine (the Brahma app or 'brahma run') is already using \(paths.home.path)")
        }
        defer { withExtendedLifetime(lock) {} }
        var config = SchedulerConfig()
        config.hardCap = hardCap
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let orchestrator = Orchestrator(
            store: store, runner: ClaudeProcessRunner(), paths: paths, config: config,
            mcpExecutable: executable, profile: profile)
        try await orchestrator.start()
        // Read before the engine starts, so the first tick's events are printed too.
        let printer = EventPrinter(store: store, startAfter: try store.maxEventId())

        // Handle SIGINT/SIGTERM ourselves so in-flight turns are killed and recorded before we exit.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let engine = Task { await orchestrator.runForever() }
        let sources = [SIGINT, SIGTERM].map { sig in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { engine.cancel() }
            source.resume()
            return source
        }

        print("brahma running (hard cap \(hardCap), profile \(profile.rawValue)); Ctrl-C to stop")
        let printing = Task {
            while !Task.isCancelled {
                printer.drain()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        await engine.value
        printing.cancel()
        await printing.value
        printer.drain()
        sources.forEach { $0.cancel() }
        print("stopped")
    }
}

/// Prints new activity events as `HH:mm:ss [company-slug] text`.
final class EventPrinter: @unchecked Sendable {
    private let store: Store
    private var lastId: Int64
    private var slugs: [String: String] = [:]
    private let lock = NSLock()

    init(store: Store, startAfter: Int64) {
        self.store = store
        self.lastId = startAfter
    }

    func drain() {
        lock.lock(); defer { lock.unlock() }
        while let events = try? store.events(afterId: lastId, limit: 200), !events.isEmpty {
            for e in events {
                if slugs[e.companyId] == nil { slugs[e.companyId] = (try? store.company(id: e.companyId))?.slug ?? "?" }
                print(safe("\(clock(e.createdAt, seconds: true)) [\(slugs[e.companyId] ?? "?")] \(e.text)"))
                lastId = e.id ?? lastId
            }
            fflush(stdout)
        }
    }
}
