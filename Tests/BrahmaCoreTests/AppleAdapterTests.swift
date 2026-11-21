import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BrahmaCore

/// A `SimulatorControlling` that records every call and answers from fixed values (Plan 4a Task 7).
final class FakeSimulator: SimulatorControlling, @unchecked Sendable {
    enum Call: Equatable, Sendable {
        case ensureDevice(String, String?), boot(String), install(String, URL), launch(String, String), terminate(String, String)
        case shutdown(String), screenshot(String, URL), leftovers
    }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var unavailable: String?
    var udid = "SIM-1"
    /// Device UDIDs by device name (else `udid`).
    var udids: [String: String] = [:]
    /// Verbs that fail (`boot`, `install`, `launch`) with a `SimctlFailure`.
    var failing: Set<String> = []
    /// Device UDIDs `shutdownLeftovers` reports as shut down.
    var leftovers: [String] = []
    var calls: [Call] { lock.withLock { _calls } }
    private func record(_ c: Call) { lock.withLock { _calls.append(c) } }
    private func fail(_ verb: String) throws {
        if failing.contains(verb) { throw SimctlFailure(message: "Simulator \(verb) failed (exit 1)", detail: "\(verb): nope") }
    }

    init(unavailable: String? = nil) { self.unavailable = unavailable }

    func availability() -> String? { unavailable }
    func ensureDevice(name: String, deviceType: String?) throws -> String { record(.ensureDevice(name, deviceType)); return udids[name] ?? udid }
    func boot(_ udid: String) throws { record(.boot(udid)); try fail("boot") }
    func install(_ udid: String, app: URL) throws { record(.install(udid, app)); try fail("install") }
    func launch(_ udid: String, bundleId: String) throws { record(.launch(udid, bundleId)); try fail("launch") }
    func terminate(_ udid: String, bundleId: String) throws { record(.terminate(udid, bundleId)) }
    func shutdown(_ udid: String) throws { record(.shutdown(udid)) }
    func screenshot(_ udid: String, to: URL) throws {
        record(.screenshot(udid, to))
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: to)
    }
    func shutdownLeftovers() throws -> [String] { record(.leftovers); return leftovers }
}

/// The iOS Simulator and macOS app adapters (Plan 4a Task 7): the simctl sequence behind the owner's approval, the bundle and
/// executable rules (fix 4), the GUI-policy spawn, the simctl JSON, and the DerivedData-per-run rule.
@Suite(.scratch) struct AppleAdapterTests {
    struct Setup {
        let dir: URL
        let run: URL
        let layout: EngineLayout
        let company: Company
        let sandbox: FakeSandbox
        let simulator: FakeSimulator
        var deps: PreviewDependencies
        var context: PreviewContext
        var surface: PreviewSurface { context.surface }
    }

    static let build = "mkdir -p build/App.app/Contents/MacOS && printf '%s' built > build/App.app/built.txt"

    static func setup(kind: PreviewKind, build: String? = AppleAdapterTests.build, appPath: String = "build/App.app",
                      approved: Bool = true, bundleId: String? = "com.acme.app", device: String? = "iPhone 15 Pro",
                      name: String? = nil, simulator: FakeSimulator = FakeSimulator()) throws -> Setup {
        let dir = try tempDir().resolvedForSandbox
        let runDir = dir.appending(path: "run", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let layout = EngineLayout(workspace: dir.appending(path: "ws", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: layout.workspace, withIntermediateDirectories: true)
        _ = try EngineFiles.directory(workspace: layout.workspace, ".brahma/preview/logs")
        let now = Date()
        let surface = PreviewSurface(id: "s1", companyId: "c1", name: name ?? (kind == .ios ? "phone" : "mac"), kind: kind.rawValue, position: 0,
                                     build: build, run: nil, url: nil, setById: "owner", createdAt: now, updatedAt: now,
                                     appPath: appPath, bundleId: kind == .ios ? bundleId : nil, device: kind == .ios ? device : nil,
                                     outsideSandboxApprovedAt: approved && kind == .ios ? now : nil)
        let company = Company(id: "c1", name: "Acme", slug: "acme", goal: "g", workspacePath: layout.workspace.path, status: .running,
                              usageMode: .low, priorityWeight: 1, createdAt: now)
        let sandboxLayout = SandboxLayout(paths: BrahmaPaths(home: dir.appending(path: "home"), workspaces: dir.appending(path: "wss")),
                                          company: company, agentHandle: "preview")
        let policies = PreviewPolicy.forKind(kind, layout: layout, run: runDir, company: company, sandbox: sandboxLayout, port: 0,
                                             surface: surface.name)
        var environment = ["PATH": "/bin:/usr/bin"]
        environment["BRAHMA_DERIVED_DATA"] = PreviewPolicy.derivedData(run: runDir).path
        let redactor = Redactor()
        redactor.update([], version: "v1")
        let context = PreviewContext(surface: surface, company: company, layout: layout, run: runDir, commit: String(repeating: "a", count: 40),
                                     port: 0, policy: policies.policy, environment: environment, logURL: layout.previewLog(name: surface.name),
                                     timeouts: PreviewTimeouts(poll: .milliseconds(50)), appPolicy: policies.appPolicy, redactor: redactor)
        let sandbox = FakeSandbox()
        var deps = PreviewDependencies.fake(sandbox: sandbox)
        deps.simulator = simulator
        deps.macApps = ProcessMacAppLauncher(guiAllowed: true)
        return Setup(dir: dir, run: runDir, layout: layout, company: company, sandbox: sandbox, simulator: simulator, deps: deps, context: context)
    }

    /// Writes a macOS app bundle at `app`: `Contents/Info.plist` with `executable` as `CFBundleExecutable`, and (unless
    /// `withBinary` is false) `Contents/MacOS/<executable>` as a small executable shell script running `body`.
    static func writeApp(_ app: URL, executable: String, body: String = "sleep 300", withBinary: Bool = true) throws {
        let macOS = app.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleExecutable": executable, "CFBundleIdentifier": "com.acme.mac", "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appending(path: "Contents/Info.plist"))
        if withBinary, !executable.contains("/") {
            let bin = macOS.appending(path: executable)
            try "#!/bin/sh\n\(body)\n".write(to: bin, atomically: true, encoding: .utf8)
            try FakeTools.fixtureMode(0o755, at: bin)   // an app executable is what is under test here
        }
    }

    static func message(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let e as WorkError { return e.message } catch { return "\(error)" }
    }

    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }

    // MARK: iOS

    @Test func iosSequence() async throws {
        var s = try Self.setup(kind: .ios)
        s.context.demoSprint = 3
        let adapter = IOSAdapter(deps: s.deps)
        #expect(adapter.kind == .ios && adapter.availability() == nil)
        let update = await adapter.start(s.context)
        #expect(update.status == .running && update.simulatorId == "SIM-1" && update.process == nil, "\(update)")
        // The build ran through the sandbox runner in the run under the Apple build policy (writes only the run), with its
        // DerivedData inside the run (obligation c): `-derivedDataPath` is passed, and no shared cache or logs dir is writable.
        let calls = s.sandbox.calls
        #expect(calls.count == 1 && calls.first?.kind == .run && calls.first?.cwd == s.run && calls.first?.output == s.context.logURL)
        let command = try #require(calls.first?.command)
        #expect(command.contains(Self.build) && command.contains("-derivedDataPath"), "\(command)")
        #expect(command.contains("\"$BRAHMA_DERIVED_DATA\"") || command.contains(PreviewPolicy.derivedData(run: s.run).path), "\(command)")
        #expect(calls.first?.environment["BRAHMA_DERIVED_DATA"] == s.run.appending(path: ".build/DerivedData").path)
        #expect(calls.first?.policy.writable == [s.run.resolvedForSandbox] && calls.first?.policy.readable == [s.run.resolvedForSandbox])
        #expect(calls.first?.policy.toolchain == true)
        // Then the simctl sequence on the surface's own device (`Brahma <company slug>-<surface name>`).
        let app = s.run.appending(path: "build/App.app")
        #expect(s.simulator.calls == [.ensureDevice("Brahma acme phone", "iPhone 15 Pro"), .boot("SIM-1"),
                                      .install("SIM-1", app.resolvedForSandbox), .launch("SIM-1", "com.acme.app")], "\(s.simulator.calls)")
        // The demo: a screenshot in the engine's logs directory, named for the surface and the sprint.
        let state = PreviewState(surfaceId: "s1", companyId: "c1", status: .running, updatedAt: Date(), simulatorId: "SIM-1")
        let demo = await adapter.demo(s.context, state: state)
        let shot = s.layout.previewLogs.appending(path: "phone-demo-3.png")
        #expect(demo.ok && demo.line == "phone: screenshot saved" && demo.outputPath == shot.path, "\(demo)")
        #expect(FileManager.default.fileExists(atPath: shot.path))
        #expect(s.simulator.calls.last == .screenshot("SIM-1", shot))
        // A demo of a surface not running: nothing is asked of the Simulator.
        let before = s.simulator.calls.count
        let idle = await adapter.demo(s.context, state: PreviewState(surfaceId: "s1", companyId: "c1", status: .stopped, updatedAt: Date()))
        #expect(!idle.ok && idle.line == "phone: not running" && s.simulator.calls.count == before)
        // Stop: terminate the app, shut the device down.
        await adapter.stop(s.context, state: state)
        #expect(Array(s.simulator.calls.suffix(2)) == [.terminate("SIM-1", "com.acme.app"), .shutdown("SIM-1")])
    }

    /// Fix round 1, I2: every iOS surface has its own device, so one surface's `device` type is honoured and its stop never
    /// shuts down a sibling's device.
    @Test func iosDevicePerSurface() async throws {
        let sim = FakeSimulator()
        sim.udids = ["Brahma acme phone": "SIM-P", "Brahma acme pad": "SIM-T"]
        let phone = try Self.setup(kind: .ios, simulator: sim)
        let pad = try Self.setup(kind: .ios, device: "iPad Pro 13-inch (M5)", name: "pad", simulator: sim)
        let p = await IOSAdapter(deps: phone.deps).start(phone.context)
        let t = await IOSAdapter(deps: pad.deps).start(pad.context)
        #expect(p.status == .running && p.simulatorId == "SIM-P", "\(p)")
        #expect(t.status == .running && t.simulatorId == "SIM-T", "\(t)")
        #expect(sim.calls.contains(.ensureDevice("Brahma acme phone", "iPhone 15 Pro")) && sim.calls.contains(.ensureDevice("Brahma acme pad", "iPad Pro 13-inch (M5)")))
        #expect(SimctlController.deviceName(slug: "acme", surface: "phone") == "Brahma acme phone" && SimctlController.isBrahmaDevice("Brahma acme phone"))
        // Stopping the phone leaves the pad's device alone.
        await IOSAdapter(deps: phone.deps).stop(phone.context, state: PreviewState(surfaceId: "s1", companyId: "c1", status: .running, updatedAt: Date(), simulatorId: "SIM-P"))
        #expect(sim.calls.contains(.shutdown("SIM-P")) && !sim.calls.contains(.shutdown("SIM-T")), "\(sim.calls)")
        #expect(sim.calls.filter { if case .shutdown = $0 { return true }; return false }.count == 1)
        // The scripted controller creates the per-surface device rather than reusing the company-wide one in the fixture.
        let script = SimctlScript(devices: try Self.fixture("simctl-devices"), types: try Self.fixture("simctl-devicetypes"))
        let ctl = SimctlController(exec: script.exec, available: { true })
        #expect(try ctl.ensureDevice(name: SimctlController.deviceName(slug: "acme", surface: "phone"), deviceType: "iPhone 15 Pro") == "NEW-UDID-1")
        #expect(script.argvs.last == ["create", "Brahma acme phone", "com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro"], "\(script.argvs)")
    }

    /// Fix round 1, M1: a start that fails after `boot` (install, launch) shuts the device down again; nothing stays booted.
    @Test func iosFailedStartShutsDown() async throws {
        for verb in ["install", "launch"] {
            let sim = FakeSimulator()
            sim.failing = [verb]
            let s = try Self.setup(kind: .ios, simulator: sim)
            let update = await IOSAdapter(deps: s.deps).start(s.context)
            #expect(update.status == .failed && update.message == "Simulator \(verb) failed (exit 1)" && update.simulatorId == nil, "\(verb): \(update)")
            #expect(sim.calls.last == .shutdown("SIM-1"), "\(verb): \(sim.calls)")
            #expect(sim.calls.contains(.boot("SIM-1")))
            // simctl's own words went to the sealed log, not the message.
            #expect(Self.text(s.context.logURL)?.contains("\(verb): nope") == true)
        }
        // A boot failure: nothing to shut down.
        let sim = FakeSimulator()
        sim.failing = ["boot"]
        let s = try Self.setup(kind: .ios, simulator: sim)
        let update = await IOSAdapter(deps: s.deps).start(s.context)
        #expect(update.status == .failed && update.message == "Simulator boot failed (exit 1)")
        #expect(!sim.calls.contains(.shutdown("SIM-1")))
    }

    static func text(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    @Test func iosNeedsOwnerApproval() async throws {
        let s = try Self.setup(kind: .ios, approved: false)
        let update = await IOSAdapter(deps: s.deps).start(s.context)
        #expect(update.status == .unavailable && update.message == SimulatorApproval.waitingMessage, "\(update)")
        #expect(s.simulator.calls.isEmpty && s.sandbox.calls.isEmpty)
        // Without a Simulator here, the adapter says so and still asks nothing.
        var deps = s.deps
        deps.simulator = FakeSimulator(unavailable: UnavailableSimulator.message)
        #expect(IOSAdapter(deps: deps).availability() == "iOS previews need macOS with Xcode")
    }

    @Test func iosMissingAppPath() async throws {
        // The build does not produce the bundle.
        let s = try Self.setup(kind: .ios, build: "echo nothing built")
        let update = await IOSAdapter(deps: s.deps).start(s.context)
        #expect(update.status == .failed && update.message == AppBundle.notBuilt, "\(update)")
        #expect(s.simulator.calls.isEmpty)
        // A file, not a directory, at app_path.
        let f = try Self.setup(kind: .ios, build: "mkdir -p build && echo x > build/App.app")
        let file = await IOSAdapter(deps: f.deps).start(f.context)
        #expect(file.status == .failed && file.message == AppBundle.notBuilt, "\(file)")
        // A directory that does not end in .app.
        let d = try Self.setup(kind: .ios, build: "mkdir -p build/App", appPath: "build/App")
        let dir = await IOSAdapter(deps: d.deps).start(d.context)
        #expect(dir.status == .failed && dir.message == AppBundle.notBuilt, "\(dir)")
        // A failed build never reaches the Simulator.
        let b = try Self.setup(kind: .ios, build: "exit 2")
        let failed = await IOSAdapter(deps: b.deps).start(b.context)
        #expect(failed.status == .failed && failed.message == "build failed (exit 2)" && b.simulator.calls.isEmpty, "\(failed)")
    }

    // MARK: Bundle validation (fix 4, obligation a)

    @Test func bundleValidation() async throws {
        let outside = try tempDir().resolvedForSandbox
        try Self.writeApp(outside.appending(path: "Evil.app"), executable: "Evil")
        // An app_path symlink out of the run: refused for iOS and for macOS, exactly.
        let ios = try Self.setup(kind: .ios, build: "mkdir -p build && ln -s '\(outside.path)/Evil.app' build/App.app")
        let update = await IOSAdapter(deps: ios.deps).start(ios.context)
        #expect(update.status == .failed && update.message == "app_path must stay inside the repo", "\(update)")
        #expect(ios.simulator.calls.isEmpty)
        let mac = try Self.setup(kind: .macos, build: "mkdir -p build && ln -s '\(outside.path)/Evil.app' build/App.app")
        let macUpdate = await MacAppAdapter(deps: mac.deps).start(mac.context)
        #expect(macUpdate.status == .failed && macUpdate.message == "app_path must stay inside the repo", "\(macUpdate)")
        #expect(mac.sandbox.calls.map(\.kind) == [.run], "no spawn")
        let launcher = ProcessMacAppLauncher()
        #expect(Self.message { _ = try launcher.executable(inApp: mac.run.appending(path: "build/App.app"), run: mac.run) }
                == "app_path must stay inside the repo")
        // A parent directory linked out of the run is the same escape.
        let linkedParent = try Self.setup(kind: .macos, build: "ln -s '\(outside.path)' build")
        try Self.writeApp(outside.appending(path: "App.app"), executable: "App")
        let parent = await MacAppAdapter(deps: linkedParent.deps).start(linkedParent.context)
        #expect(parent.status == .failed && parent.message == "app_path must stay inside the repo", "\(parent)")
        // An app whose app_path is the run itself, or above it, is not inside.
        #expect(Self.message { _ = try AppBundle.locate(appPath: ".", run: mac.run) } == "app_path must stay inside the repo")
        #expect(Self.message { _ = try AppBundle.locate(appPath: "../run", run: mac.run) } == "app_path must stay inside the repo")

        // CFBundleExecutable with a path, `..`, or a quote: refused exactly.
        for bad in ["../../bin/sh", "a'b", "Contents/MacOS/x", "/bin/sh", ".."] {
            let s = try Self.setup(kind: .macos, build: "true")
            let app = s.run.appending(path: "build/App.app")
            try Self.writeApp(app, executable: bad, withBinary: false)
            #expect(Self.message { _ = try launcher.executable(inApp: app, run: s.run) } == "CFBundleExecutable must be a plain file name", "\(bad)")
            let started = await MacAppAdapter(deps: s.deps).start(s.context)
            #expect(started.status == .failed && started.message == "CFBundleExecutable must be a plain file name", "\(bad): \(started)")
            #expect(s.sandbox.calls.map(\.kind) == [.run], "no spawn for \(bad)")
        }
        // No Info.plist, or one without CFBundleExecutable.
        let none = try Self.setup(kind: .macos, build: "mkdir -p build/App.app/Contents/MacOS")
        let noPlist = await MacAppAdapter(deps: none.deps).start(none.context)
        #expect(noPlist.status == .failed && noPlist.message == AppBundle.noExecutable, "\(noPlist)")
        // The executable is a symlink pointing outside the app: refused.
        let linked = try Self.setup(kind: .macos, build: "true")
        let app = linked.run.appending(path: "build/App.app")
        try Self.writeApp(app, executable: "App", withBinary: false)
        try FileManager.default.createSymbolicLink(at: app.appending(path: "Contents/MacOS/App"), withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        #expect(Self.message { _ = try launcher.executable(inApp: app, run: linked.run) } == AppBundle.executableOutside)
        let escaped = await MacAppAdapter(deps: linked.deps).start(linked.context)
        #expect(escaped.status == .failed && escaped.message == AppBundle.executableOutside && linked.sandbox.calls.map(\.kind) == [.run], "\(escaped)")
        // A link to a file inside the run but outside the app, a directory, and a non-executable file: all refused.
        let sibling = try Self.setup(kind: .macos, build: "true")
        let app2 = sibling.run.appending(path: "build/App.app")
        try Self.writeApp(app2, executable: "App", withBinary: false)
        try "#!/bin/sh\nsleep 300\n".write(to: sibling.run.appending(path: "build/other.sh"), atomically: true, encoding: .utf8)
        try FakeTools.fixtureMode(0o755, at: sibling.run.appending(path: "build/other.sh"))
        try FileManager.default.createSymbolicLink(at: app2.appending(path: "Contents/MacOS/App"), withDestinationURL: sibling.run.appending(path: "build/other.sh"))
        #expect(Self.message { _ = try launcher.executable(inApp: app2, run: sibling.run) } == AppBundle.executableOutside)
        try FileManager.default.removeItem(at: app2.appending(path: "Contents/MacOS/App"))
        try FileManager.default.createDirectory(at: app2.appending(path: "Contents/MacOS/App"), withIntermediateDirectories: true)
        #expect(Self.message { _ = try launcher.executable(inApp: app2, run: sibling.run) } == AppBundle.executableOutside)
        try FileManager.default.removeItem(at: app2.appending(path: "Contents/MacOS/App"))
        try "not executable".write(to: app2.appending(path: "Contents/MacOS/App"), atomically: true, encoding: .utf8)
        #expect(Self.message { _ = try launcher.executable(inApp: app2, run: sibling.run) } == AppBundle.executableOutside)
        // A good bundle resolves to its executable.
        let good = try Self.setup(kind: .macos, build: "true")
        let app3 = good.run.appending(path: "build/App.app")
        try Self.writeApp(app3, executable: "App")
        #expect(try launcher.executable(inApp: app3, run: good.run) == app3.appending(path: "Contents/MacOS/App"))
    }

    // MARK: macOS

    @Test func macAppLaunchTracksPid() async throws {
        let s = try Self.setup(kind: .macos, build: "mkdir -p build && echo built")
        let app = s.run.appending(path: "build/App.app")
        try Self.writeApp(app, executable: "App", body: "sleep 300")
        let adapter = MacAppAdapter(deps: s.deps)
        #expect(adapter.kind == .macos && adapter.availability() == nil)
        // The live check's residual: the shipped launcher keeps macOS previews unavailable, with the brief's exact reason.
        var shipped = s.deps
        shipped.macApps = ProcessMacAppLauncher()
        #expect(MacAppAdapter(deps: shipped).availability() == "macOS app previews need the sandbox to allow GUI apps")
        #expect(PreviewDependencies.live(sandbox: FakeSandbox()).macApps.availability() == ProcessMacAppLauncher.guiResidual)
        let heard = Heard()
        var context = s.context
        context.onSpawn = { pid, _ in heard.set(pid) }
        let update = await adapter.start(context)
        let pid = try #require(update.process)
        #expect(update.status == .running && update.message == nil, "\(update)")
        #expect(heard.pid == pid)
        // The build ran under the Apple build policy (DerivedData inside the run), the app under the GUI policy, single-quoted.
        let calls = s.sandbox.calls
        #expect(calls.map(\.kind) == [.run, .spawn])
        #expect(calls[0].command.contains("-derivedDataPath") && calls[0].policy == s.context.policy)
        #expect(calls[0].policy.writable == [s.run.resolvedForSandbox])
        #expect(calls[1].command == "exec '\(app.appending(path: "Contents/MacOS/App").path)'", "\(calls[1].command)")
        #expect(calls[1].policy == s.context.appPolicy && calls[1].policy.writable.first?.path.hasSuffix(".brahma/preview/apps/mac") == true)
        #expect(calls[1].cwd == s.run && calls[1].output == s.context.logURL)
        #expect(s.deps.processes.process(pid) != nil && kill(pid, 0) == 0)
        // The demo says whether it is still running.
        let running = PreviewState(surfaceId: "s1", companyId: "c1", status: .running, pid: pid, updatedAt: Date())
        let demo = await adapter.demo(context, state: running)
        #expect(demo.ok && demo.line == "mac: running", "\(demo)")
        await adapter.stop(context, state: running)
        #expect(s.deps.processes.process(pid) == nil)
        #expect(await PreviewRunnerTests.waitUntil(.seconds(30)) { kill(-pid, 0) != 0 })
        let stopped = await adapter.demo(context, state: PreviewState(surfaceId: "s1", companyId: "c1", status: .stopped, updatedAt: Date()))
        #expect(!stopped.ok && stopped.line == "mac: not running", "\(stopped)")
        // An app that exits at once is a failed start, never left in the table.
        let quick = try Self.setup(kind: .macos, build: "true")
        try Self.writeApp(quick.run.appending(path: "build/App.app"), executable: "App", body: "exit 7")
        var quickContext = quick.context
        quickContext.timeouts = PreviewTimeouts(poll: .seconds(2))   // one liveness check after `poll`; generous under suite load
        let gone = await MacAppAdapter(deps: quick.deps).start(quickContext)
        #expect(gone.status == .failed && gone.message == "exited during start (exit 7)" && quick.deps.processes.count == 0, "\(gone)")
    }

    final class Heard: @unchecked Sendable {
        private let lock = NSLock(); private var _pid: Int32?
        func set(_ p: Int32) { lock.withLock { _pid = p } }
        var pid: Int32? { lock.withLock { _pid } }
    }

    // MARK: simctl

    @Test func simctlJSONParsing() throws {
        let devices = try SimctlController.parseDevices(try Self.fixture("simctl-devices"))
        #expect(devices.count == 5)
        // Runtimes in key order (a JSON object has none of its own), devices in the file's order within each.
        #expect(devices.map(\.name) == ["iPhone 16 Pro", "Brahma old", "iPhone 17 Pro", "iPhone 17 Pro Max", "Brahma acme"])
        let ours = try #require(devices.first { $0.name == "Brahma acme" })
        #expect(ours.udid == "A1B2C3D4-0000-4000-8000-00000000BEEF" && ours.state == "Booted" && ours.isAvailable)
        #expect(devices.first { $0.name == "Brahma old" }?.isAvailable == false)
        // Only Brahma-named devices are the engine's; the booted owner device never is.
        let booted = SimctlController.bootedBrahmaDevices(devices)
        #expect(booted.map(\.udid) == ["A1B2C3D4-0000-4000-8000-00000000BEEF"])
        #expect(SimctlController.isBrahmaDevice("Brahma acme") && !SimctlController.isBrahmaDevice("iPhone 17 Pro") && !SimctlController.isBrahmaDevice("brahma x"))
        let types = try SimctlController.parseDeviceTypes(try Self.fixture("simctl-devicetypes"))
        #expect(types.map(\.name) == ["Apple Watch Series 11 (46mm)", "iPhone 17 Pro", "iPhone 17", "iPhone 15 Pro", "iPad Pro 13-inch (M5)"])
        // The asked-for type when listed, else the first iPhone (never a watch).
        #expect(SimctlController.pick(types, named: "iPhone 15 Pro")?.identifier == "com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro")
        #expect(SimctlController.pick(types, named: "iPhone 99")?.identifier == "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro")
        #expect(SimctlController.pick(types, named: nil)?.identifier == "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro")
        #expect(SimctlController.pick([types[0]], named: nil) == nil)
        #expect(throws: (any Error).self) { try SimctlController.parseDevices(Data("nope".utf8)) }

        // The controller over a scripted `simctl`: argv is engine-fixed, the device is reused when present, created when not.
        let script = SimctlScript(devices: try Self.fixture("simctl-devices"), types: try Self.fixture("simctl-devicetypes"))
        let sim = SimctlController(exec: script.exec, available: { true })
        #expect(sim.availability() == nil)
        #expect(try sim.ensureDevice(name: "Brahma acme", deviceType: nil) == "A1B2C3D4-0000-4000-8000-00000000BEEF")
        #expect(script.argvs == [["list", "devices", "-j"]])
        #expect(try sim.ensureDevice(name: "Brahma beta", deviceType: "iPhone 15 Pro") == "NEW-UDID-1")
        #expect(script.argvs.last == ["create", "Brahma beta", "com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro"], "\(script.argvs)")
        #expect(try sim.ensureDevice(name: "Brahma gamma", deviceType: "Nope") == "NEW-UDID-1")
        #expect(script.argvs.last == ["create", "Brahma gamma", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"])
        // A non-Brahma name is never created or reused.
        #expect(Self.message { _ = try sim.ensureDevice(name: "iPhone 17 Pro", deviceType: nil) } != nil)
        #expect(!script.argvs.contains(["create", "iPhone 17 Pro", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"]))
        // Boot tolerates an already booted device; another failure throws.
        script.bootStatus = (149, "Unable to boot device in current state: Booted")
        try sim.boot("A1B2C3D4-0000-4000-8000-00000000BEEF")
        script.bootStatus = (1, "An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=60)")
        #expect(Self.message { try sim.boot("A1B2C3D4-0000-4000-8000-00000000BEEF") } != nil)
        try sim.install("U", app: URL(fileURLWithPath: "/r/App.app"))
        #expect(script.argvs.last == ["install", "U", "/r/App.app"])
        try sim.launch("U", bundleId: "com.acme.app")
        #expect(script.argvs.last == ["launch", "U", "com.acme.app"])
        try sim.terminate("U", bundleId: "com.acme.app")
        #expect(script.argvs.last == ["terminate", "U", "com.acme.app"])
        try sim.shutdown("U")
        #expect(script.argvs.last == ["shutdown", "U"])
        try sim.screenshot("U", to: URL(fileURLWithPath: "/l/p.png"))
        #expect(script.argvs.last == ["io", "U", "screenshot", "/l/p.png"])
        // The leftovers sweep shuts down the booted Brahma device only.
        let swept = try sim.shutdownLeftovers()
        #expect(swept == ["A1B2C3D4-0000-4000-8000-00000000BEEF"] && script.argvs.last == ["shutdown", "A1B2C3D4-0000-4000-8000-00000000BEEF"])
        #expect(!script.argvs.contains(["shutdown", "742D0B6B-FC28-4602-9CB8-58AFB788F31B"]))
        // Without simctl, the controller is unavailable and runs nothing.
        let none = SimctlController(exec: script.exec, available: { false })
        #expect(none.availability() == UnavailableSimulator.message)
    }

    /// A scripted `simctl`: lists from the fixtures, creates `NEW-UDID-1`, and records every argv.
    final class SimctlScript: @unchecked Sendable {
        let devices: Data, types: Data
        private let lock = NSLock()
        private var _argvs: [[String]] = []
        var bootStatus: (Int32, String) = (0, "")
        var argvs: [[String]] { lock.withLock { _argvs } }
        init(devices: Data, types: Data) { self.devices = devices; self.types = types }
        var exec: SimctlController.Exec {
            { [self] argv in
                lock.withLock { _argvs.append(argv) }
                switch argv.first {
                case "list": return (0, String(decoding: argv[1] == "devices" ? devices : types, as: UTF8.self), "")
                case "create": return (0, "NEW-UDID-1\n", "")
                case "boot": return (bootStatus.0, "", bootStatus.1)
                default: return (0, "", "")
                }
            }
        }
    }

    /// Owner hands-on check: a real `Brahma <slug>` device is created, booted, shut down and deleted. Only with `BRAHMA_SIM=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BRAHMA_SIM"] == "1"), .timeLimit(.minutes(5)))
    func realSimulatorIfEnabled() throws {
        let sim = SimctlController()
        try #require(sim.availability() == nil)
        let name = SimctlController.deviceName(slug: "test-\(UUID().uuidString.prefix(8).lowercased())")
        let udid = try sim.ensureDevice(name: name, deviceType: nil)
        defer { _ = try? sim.shutdown(udid); _ = try? sim.delete(udid) }
        #expect(try sim.ensureDevice(name: name, deviceType: nil) == udid, "reused, not created twice")
        try sim.boot(udid)
        try sim.boot(udid)   // tolerated
        let shot = try tempDir().appending(path: "shot.png")
        try sim.screenshot(udid, to: shot)
        #expect(FileManager.default.fileExists(atPath: shot.path))
        try sim.shutdown(udid)
    }

    // MARK: Recovery (obligation b)

    /// A Simulator device an earlier engine left booted is shut down at the next runner's first pass: the recorded one, and
    /// every booted `Brahma …` device; the owner's devices are never touched.
    @Test func recoveryShutsDownLeftoverSimulator() async throws {
        let sim = FakeSimulator()
        sim.leftovers = ["OLD-2"]
        let x = try PreviewKindsTests.Fx(results: [.ios: PreviewUpdate(status: .running, message: nil, simulatorId: "SIM-1")], simulator: sim)
        #expect(x.ios().ok)
        // An earlier engine's record: running on SIM-9.
        let surface = try x.surface("phone")
        try x.store.savePreviewState(PreviewState(surfaceId: surface.id, companyId: x.company.id, status: .running, commit: x.company.mainCommit,
                                                  updatedAt: x.now, simulatorId: "SIM-9"))
        await x.runner.reconcile(now: x.now)
        await x.runner.waitForStarts()
        #expect(sim.calls.contains(.shutdown("SIM-9")) && sim.calls.contains(.leftovers), "\(sim.calls)")
        #expect(!sim.calls.contains { if case .boot = $0 { return true }; return false }, "nothing booted without the owner's approval")
        let state = try x.state("phone")
        #expect(state.simulatorId == nil && state.status == .unavailable, "\(state)")
        await x.runner.stopAll()
    }

    // MARK: The profile is built from the checked paths (obligation d)

    /// `SeatbeltRunner.prepare` validates the policy's paths and then renders the profile. A path swapped for a link between
    /// the two must not widen the profile: the profile names exactly the paths the check saw.
    @Test func profileUsesCheckedPaths() throws {
        let dir = try Scratch.homeDir().resolvedForSandbox
        let outside = dir.appending(path: "outside")
        let appData = dir.appending(path: "ws/.brahma/preview/apps/mac")
        let run = dir.appending(path: "run")
        for d in [outside, appData, run] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let baseline = SandboxBaseline.current(paths: BrahmaPaths(home: dir.appending(path: "home"), workspaces: dir.appending(path: "wss")),
                                               otherWorkspaces: [], backupTargets: [])
        try #require(baseline.problem == nil)
        let policy = SandboxPolicy(writable: [appData], readable: [run], network: .none, toolchain: false)
        // 1. A readable entry (the run) swapped for a link out between the check and the render: the profile still names the
        //    checked path, never the link's target.
        let swapped = Swapped()
        let readSwap = SeatbeltRunner(baseline: { baseline }, proxies: EgressProxyPool(), termGrace: 1, afterValidate: {
            try? FileManager.default.removeItem(at: run)
            try? FileManager.default.createSymbolicLink(at: run, withDestinationURL: outside)
            swapped.set()
        })
        let prepared = try readSwap.prepare(command: "true", environment: [:], policy: policy, proxyPort: nil, marker: nil)
        #expect(swapped.did)
        let profile = try #require(prepared.arguments.dropFirst(2).first)
        #expect(profile.contains("(subpath \(SeatbeltProfile.quote(run.path)))"), "\(profile)")
        #expect(profile.contains("(subpath \(SeatbeltProfile.quote(appData.path)))"), "\(profile)")
        #expect(!profile.contains(SeatbeltProfile.quote(outside.path)), "the link's target leaked into the profile:\n\(profile)")
        #expect(prepared.environment["TMPDIR"] == appData.appending(path: ".brahma-tmp").path)
        SeatbeltRunner.removeTemp(policy)
        // The same policy presented with the link already in place is refused by the check itself.
        #expect(throws: (any Error).self) { try readSwap.prepare(command: "true", environment: [:], policy: policy, proxyPort: nil, marker: nil) }
        try FileManager.default.removeItem(at: run)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        // 2. The writable entry (the app-data place) swapped the same way: the engine's own TMPDIR step opens it without
        //    following links, so nothing is prepared and nothing lands in the target.
        let writeSwap = SeatbeltRunner(baseline: { baseline }, proxies: EgressProxyPool(), termGrace: 1, afterValidate: {
            try? FileManager.default.removeItem(at: appData)
            try? FileManager.default.createSymbolicLink(at: appData, withDestinationURL: outside)
        })
        #expect(throws: (any Error).self) { try writeSwap.prepare(command: "true", environment: [:], policy: policy, proxyPort: nil, marker: nil) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty, "the engine wrote through the link")
        // 3. The renderer itself: with the policy's paths taken as checked, no link is followed at render time.
        let plain = SeatbeltProfile.render(policy: policy, baseline: baseline, proxyPort: nil, resolvePolicyPaths: false)
        #expect(plain.contains("(subpath \(SeatbeltProfile.quote(appData.path)))") && !plain.contains(SeatbeltProfile.quote(outside.path)), "\(plain)")
    }

    final class Swapped: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        func set() { lock.withLock { v = true } }
        var did: Bool { lock.withLock { v } }
    }
}
