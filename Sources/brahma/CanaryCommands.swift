import ArgumentParser
import Foundation
import BrahmaCore

/// The sandbox canary's owner-written probe file (`<data home>/canary/probes.txt`) and a run of the canary now. Every probe
/// is expected to be DENIED; the canary passes only when every one is, in both layers.
struct CanaryGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "canary", abstract: "Write and run the sandbox canary's probe lines (owner only).",
        subcommands: [Edit.self, RunNow.self])

    struct Edit: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Edit the canary probe file in $EDITOR (default vi). When missing it is created holding only header comments.")

        func run() throws {
            try requireOwnerShell()
            let (_, paths) = try openStore()
            let created: (url: URL, created: Bool)
            do { created = try CanaryProbes.ensureTemplate(paths: paths) } catch { throw fail("\(error)") }
            if created.created { print(safe("created \(created.url.path) (header comments only; no probe lines)")) }
            // Checked before the editor opens it: never hand an editor a link or a file that is not the owner's own.
            if case .failure(let error) = CanaryProbes.load(paths: paths), case .refused = error { throw fail(error.description) }
            let editor = ProcessInfo.processInfo.environment["EDITOR"].flatMap { $0.isEmpty ? nil : $0 } ?? "vi"
            // As git runs an editor: the owner's $EDITOR through the shell, the file as its one argument (never spliced).
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "\(editor) \"$1\"", "brahma-canary-edit", created.url.path]
            do { try process.run() } catch { throw fail("can't start the editor '\(editor)': \(error)") }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw fail("the editor exited with status \(process.terminationStatus)") }
            // Checked again after the edit: an editor may have replaced the file (another mode, a link).
            switch CanaryProbes.load(paths: paths) {
            case .success(let file):
                print(safe("\(file.probes.count) probe line(s) (\(file.helpers.count) marked # helper); sha256 \(file.sha256.prefix(12)). "
                           + "Run `brahma canary run` to check them; sandboxed companies stay blocked until it passes."))
            case .failure(.noProbes(let path)):
                print(safe("no probe lines in \(path) yet; sandboxed companies stay blocked until you add some and the canary passes"))
            case .failure(let error):
                throw fail(error.description)
            }
        }
    }

    struct RunNow: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run the sandbox canary now for the turn shape(s) your sandboxed companies use: model-free, then one small haiku turn each (uses a little of your plan). Records each pass.")

        func run() async throws {
            try requireOwnerShell()
            signal(SIGPIPE, SIG_IGN)
            let (store, paths) = try openStore()
            let hook = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let claude = ExtLint.claudePath() ?? "claude"
            let canary = SandboxCanary(environment: .owner, sandbox: Orchestrator.ownerSandboxRunner(store: store, paths: paths),
                                       hookExecutable: hook, baseline: Orchestrator.ownerSandboxBaseline(store: store, paths: paths))
            // The shapes the engine asks for: each running sandboxed company's standard work turn (its network), else the
            // default one. Companies whose turns compile to the same shape share one run.
            var specs: [(name: String, spec: SandboxCanary.TurnSpec)] = []
            var seen = Set<String>()
            for company in (try? store.companies()) ?? [] where company.status == .running && company.permissionProfile == .sandboxed {
                let spec = SandboxCanary.TurnSpec(company: company)
                // Tied to `ClaudeSettings.shape()`, which keeps only an array's first element and turns every string into "s":
                // of a company's network, only whether the Bash domain list is empty and the local-binding flag change the
                // compiled shape (the WebFetch domains join `permissions.allow` after "Bash", so they never do; listed anyway).
                // `canaryRunShapeKeyMatchesShape` checks this against the compiled shapes.
                let shapeKey = SandboxCanary.TurnSpec.shapeKey(spec)
                if seen.insert(shapeKey).inserted { specs.append((company.name, spec)) }
            }
            if specs.isEmpty { specs = [("the default sandboxed company", .standard)] }
            let version = await BrahmaCore.Doctor.cliVersion(claudePath: claude)
            var passed: [SandboxCanaryKey] = []
            var failed = 0
            for (index, entry) in specs.enumerated() {
                if specs.count > 1 { print(safe("== the work turn shape of \(entry.name) (\(index + 1) of \(specs.count))")) }
                // The canary verifies its own key (this CLI build, the probe file, the turn's shape, this macOS); that key is recorded.
                let asked = SandboxCanaryKey(fingerprint: "", shape: SandboxCanary.anyShape, osVersion: "")
                let run = await canary.run(paths: paths, claudePath: claude, runner: ClaudeProcessRunner(claudePath: claude), key: asked,
                                           spec: entry.spec)
                for line in CanaryReport.lines(run, redact: { store.redactedForDisplay($0) }) { print(safe(line)) }
                if var key = run.verified, run.passes(key) {
                    key.cliVersion = version
                    passed.append(key)
                    // M2: this command cannot see which keys the engine is still failing, so it never answers the
                    // sandbox-check alert itself; the engine does, once its waiting agents' keys have all passed.
                    do { try store.recordCanary(key, detail: run.detail, resolveAlert: false) } catch {
                        throw fail("could not record the pass: \(error)")
                    }
                } else {
                    failed += 1
                }
            }
            let file = try? CanaryProbes.load(paths: paths).get()
            let probes = file.map { "probe file sha256 \($0.sha256.prefix(12)), \($0.blocking.count) probe(s)" } ?? "probe file"
            guard failed == 0 else {
                throw fail("the sandbox canary did not pass for \(failed) of \(specs.count) shape(s); sandboxed companies stay blocked")
            }
            print(safe("sandbox canary passed; recorded \(passed.count) shape(s) for this CLI build and \(probes)"))
        }
    }
}
