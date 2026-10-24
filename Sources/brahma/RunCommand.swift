import ArgumentParser
import Dispatch
import Foundation
import BrahmaCore
import BrahmaKeychain

extension PermissionProfile: ExpressibleByArgument {}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the orchestrator in the foreground until Ctrl-C.",
        discussion: "Each turn runs under its company's profile for the agent's role ('brahma company profile'; sandboxed "
            + "unless you changed it). --profile is a ceiling: it can narrow those profiles, never widen them.")

    @Option(help: "Maximum concurrent turns across all companies.") var hardCap: Int = 16
    @Option(help: "A ceiling on every turn's profile: sandboxed, workspace or full (default: each company's own profile).")
    var profile: PermissionProfile?

    @Flag(name: .customLong("skip-doctor"), help: .hidden) var skipDoctor = false

    func validate() throws {
        guard hardCap >= 1 else { throw ValidationError("--hard-cap must be at least 1") }
    }

    func run() async throws {
        try requireOwnerShell()
        // A child or MCP pipe closing under us must surface as EPIPE, not kill the orchestrator.
        signal(SIGPIPE, SIG_IGN)
        // Before anything opens (and migrates) the database: a damaged one is restored from a snapshot, not run on.
        let database = BrahmaPaths.fromEnvironment().database
        if FileManager.default.fileExists(atPath: database.path) {
            let rows = BackupService.integrity(of: database)
            if rows != ["ok"] { throw fail("database check failed (\(rows.first ?? "unknown")). See: brahma restore --list") }
        }
        let (store, paths) = try openStore(lazySecrets: false)
        if !skipDoctor {
            let report = await BrahmaCore.Doctor.ensure(store: store, claudePath: "claude", runner: ClaudeProcessRunner())
            if !report.ok {
                for item in report.items where item.status == .fail {
                    FileHandle.standardError.write(Data(safe("FAIL  \(item.name)  \(item.detail)\n").utf8))
                }
                throw fail("Run 'brahma doctor' for details.")
            }
        }
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
            mcpExecutable: executable, profile: profile, vault: try cliSecretVault(interactive: false))
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

        let tier = store.planTier()
        print("brahma running (plan \(tier.rawValue), up to \(min(hardCap, tier.hardCap)) concurrent turns, "
              + "profile \(profile.map { "at most \($0.rawValue)" } ?? "per company")); Ctrl-C to stop")
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
    /// Notices already printed by this process. Printing never marks anything: delivery belongs to the app.
    private var lastNoticeId: Int64 = 0
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
        drainNotices()
    }

    /// Prints each undelivered owner notice once, as `notice: [company] title: body`.
    private func drainNotices() {
        guard let notices = try? store.undeliveredNotices() else { return }
        for n in notices where (n.id ?? 0) > lastNoticeId {
            if let companyId = n.companyId, slugs[companyId] == nil { slugs[companyId] = (try? store.company(id: companyId))?.slug ?? "?" }
            let slug = n.companyId.flatMap { slugs[$0] } ?? "all"
            print(safe("notice: [\(slug)] \(n.title): \(n.body)"))
            lastNoticeId = n.id ?? lastNoticeId
        }
        fflush(stdout)
    }
}
