import Foundation
@testable import BrahmaCore

/// A hosting provider for tests. Its CLI is `fake` (`cli` `fake@1`, installed by the fake `npm` of `FakeHostingAdapter.tools`
/// as a hard link of the shared FakeTools script, never a new executable): `fake deploy <R-n>` copies the upload into
/// `$FAKE_HOST_ROOT/<R-n>` and prints `https://fake-<r-n>.local` on stdout; `fake inspect <url>` prints `project <name>`.
/// Its fixed environment (in the plan, and so in the hash) carries what a test asks of it: echo the token, exit with a
/// code, print a URL on stderr, sleep (or wait for a file, `FAKE_WAIT_FOR`) before deploying. `smokeBase` is `server`. Never contacts anything. Injected through
/// the adapter lookup (PR-25), never a shared registry.
struct FakeHostingAdapter: HostingAdapter {
    var id: HostingProviderID = .cloudflarePages
    var tokenSecret = "FAKE_HOST_TOKEN"
    var cli = "fake@1"
    var toolNetwork: [String] = []
    var network: [String] = []
    var providerConfigNames: [String] = []
    /// What the smoke probes (a fake HTTP probe answers it).
    var server: URL?
    /// Where `fake deploy` copies the upload.
    var hostRoot: URL?
    /// `fake deploy` prints the token's value (the redaction test).
    var echoToken = false
    var exitCode: Int?
    /// Printed on stderr after the deploy URL (stdout-only parsing).
    var stderrLine: String?
    /// Seconds `fake deploy` sleeps before it copies anything (the stop test).
    var sleepSeconds: Int?
    /// A file `fake deploy` waits for before it prints or copies anything (a test acts while the step runs, by event).
    var waitFor: String?
    /// Plans carry a verify step (`fake inspect <deploy URL>`), as Vercel's do.
    var verify = false
    /// The project `fake inspect` reports (nil: the configured one).
    var inspectProject: String?
    /// What the plan stages (nil: the output folder); `["."]` stages the whole export, as Vercel's plans do.
    var stageFrom: [String]?
    /// Added to the rollback plan's environment only (Task 8: a rollback that fails, waits or echoes while the deploy did not).
    var rollbackEnv: [String: String] = [:]
    /// What `fake project ls` lists (Task 15: the provider probe's leftover check).
    var projects: [String] = []
    /// `smokeBase` as Vercel's (final-review I6b): the owner's production URL, else the deploy URL it is given, else nil.
    var smokesDeployURL = false

    static let installIsNoOp = false

    func validate(_ s: HostingSettings) throws { try HostingAdapters.validateForDeploy(s) }

    func env(_ i: DeployInput) -> [String: String] {
        var e = ["FAKE_HOST_ROOT": hostRoot?.path ?? "/nonexistent", "FAKE_ACCOUNT": i.settings.accountId ?? "",
                 "FAKE_INSPECT_PROJECT": inspectProject ?? i.settings.project]
        if echoToken { e["FAKE_ECHO"] = tokenSecret }
        if let exitCode { e["FAKE_EXIT"] = String(exitCode) }
        if let stderrLine { e["FAKE_STDERR"] = stderrLine }
        if let sleepSeconds { e["FAKE_SLEEP"] = String(sleepSeconds) }
        if let waitFor { e["FAKE_WAIT_FOR"] = waitFor }
        if !projects.isEmpty { e["FAKE_PROJECTS"] = projects.joined(separator: " ") }
        return e
    }

    func step(_ i: DeployInput) -> DeployStep {
        DeployStep(label: "deploy", argv: [i.bin("fake"), "deploy", i.releaseDir.lastPathComponent])
    }

    func deployPlan(_ i: DeployInput) throws -> DeployPlan {
        try validate(i.settings)
        return try DeployPlan(steps: [step(i)], stageFrom: stageFrom ?? [i.settings.outputDir ?? ""], cwdPath: i.inRelease("upload"),
                              network: network, tokenSecret: tokenSecret, env: env(i), build: i.settings.build,
                              outputDir: i.settings.outputDir,
                              verify: verify ? [i.bin("fake"), "inspect", DeployPlan.deployURLPlaceholder] : nil)
    }

    /// `fake deploy rollback-R-<n>` from the restored release's upload (else the placeholder), so what it deploys lands in its
    /// own host folder. With `verify` and a previous deploy URL, `fake inspect <that URL>` runs first (as Vercel's rollback).
    func rollbackPlan(_ i: DeployInput) throws -> DeployPlan {
        try validate(i.settings)
        var steps = [DeployStep(label: "deploy", argv: [i.bin("fake"), "deploy", "rollback-\(i.releaseDir.lastPathComponent)"])]
        if verify, let previous = i.previousDeployURL {
            steps.insert(DeployStep(label: DeployStep.verifyLabel, argv: [i.bin("fake"), "inspect", previous]), at: 0)
        }
        return try DeployPlan(steps: steps, stageFrom: [], cwdPath: (i.previousUpload ?? i.placeholderDir).path,
                              network: network, tokenSecret: tokenSecret, env: env(i).merging(rollbackEnv) { _, new in new },
                              build: i.settings.build, outputDir: i.settings.outputDir)
    }

    func deployURL(fromOutput: String, settings: HostingSettings) -> URL? {
        fromOutput.split(whereSeparator: \.isNewline).last { $0.hasPrefix("https://fake-") }.flatMap { URL(string: String($0)) }
    }

    func smokeBase(_ s: HostingSettings, deployURL: URL?) -> URL? {
        guard smokesDeployURL else { return server }
        return s.productionURL.flatMap { URL(string: $0) } ?? deployURL
    }

    func verifiesDeployment(output: String, settings: HostingSettings) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { $0 == "project \(settings.project)" }
    }

    /// The fake provider CLI.
    static let cliScript = """
        cmd="$1"; shift
        case "$cmd" in
        deploy)
          n="$1"
          if [ -n "$FAKE_SLEEP" ]; then sleep "$FAKE_SLEEP"; fi
          if [ -n "$FAKE_WAIT_FOR" ]; then while [ ! -e "$FAKE_WAIT_FOR" ]; do sleep 0.05; done; fi
          mkdir -p "$FAKE_HOST_ROOT/$n" && cp -R . "$FAKE_HOST_ROOT/$n/" || exit 9
          if [ -n "$FAKE_ECHO" ]; then echo "using token $(printenv "$FAKE_ECHO")"; fi
          echo "https://fake-$(printf '%s' "$n" | tr 'A-Z' 'a-z').local"
          if [ -n "$FAKE_STDERR" ]; then echo "$FAKE_STDERR" >&2; fi
          exit "${FAKE_EXIT:-0}"
          ;;
        inspect)
          echo "project $FAKE_INSPECT_PROJECT"
          ;;
        project)
          sub="$1"; shift
          case "$sub" in
            ls) for p in $FAKE_PROJECTS; do echo "  $p"; done ;;
            add) echo "created $1" ;;
            rm) echo "removed $1" ;;
            *) echo "unknown project command $sub" >&2; exit 2 ;;
          esac
          ;;
        *)
          echo "unknown command $cmd" >&2
          exit 2
          ;;
        esac
        """

    /// A fake `npm install --prefix <dir> … <pkg>@<version>`: hard-links the shared `fake` script (its sibling in the same
    /// FakeTools directory) as `<dir>/node_modules/.bin/<pkg>`.
    static let npmScript = """
        prefix=""; pkg=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --prefix) prefix="$2"; shift 2 ;;
            --*) shift ;;
            install) shift ;;
            *) pkg="$1"; shift ;;
          esac
        done
        name="${pkg%@*}"
        mkdir -p "$prefix/node_modules/.bin" && ln "$(dirname "$0")/fake" "$prefix/node_modules/.bin/$name"
        """

    /// The PATH directory holding the fake `npm` and `fake`.
    static func tools() throws -> URL { try FakeTools.bin(["npm": npmScript, "fake": cliScript]) }
}

extension ReleaseDependencies {
    /// Fakes for every release dependency: recorded sandboxes (real processes), a scripted HTTP probe, the fake adapter,
    /// no wait between smoke rounds, and a PATH with the fake `npm` and CLI. Never the real sandbox, network or providers.
    static func fake(sandbox: FakeSandbox = FakeSandbox(), unsandboxed: FakeSandbox = FakeSandbox(),
                     http: FakeHTTPProbe = FakeHTTPProbe([FakeHTTPProbe.ok()]), adapter: FakeHostingAdapter = FakeHostingAdapter(),
                     environment: [String: String]? = nil) -> ReleaseDependencies {
        let path = ((try? FakeHostingAdapter.tools().path).map { $0 + ":" } ?? "") + "/usr/bin:/bin"
        return ReleaseDependencies(sandbox: sandbox, unsandboxed: unsandboxed, http: http, adapters: { _ in adapter }, sleep: { _ in },
                                   environment: environment ?? ["PATH": path, "LANG": "C"])
    }
}
