import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Plan 4a Task 7: the iOS Simulator and macOS app previews. Both build through the sandbox (`PreviewPolicy.appleBuild`: the
// build writes only its fresh export, its DerivedData inside it). The Simulator then installs and runs the app outside any
// sandbox, which is why an iOS surface runs only behind the owner's approval (Task 4's gate, read again here); a macOS app
// runs under `PreviewPolicy.guiApp` through the sandbox runner's `spawn`. Every path an agent names is resolved and must stay
// inside the run (fix 4): `AppBundle`, `ProcessMacAppLauncher`.

// MARK: The bundle rules (fix 4)

/// Where a built `.app` may be and what it may name.
public enum AppBundle {
    public static let outsideRepo = "app_path must stay inside the repo"
    public static let notBuilt = "app_path is not a built .app bundle"
    public static let badExecutableName = "CFBundleExecutable must be a plain file name"
    public static let noExecutable = "the app's Info.plist names no CFBundleExecutable"
    public static let executableOutside = "the app's executable must be a regular file inside the app"
    /// The most of an `Info.plist` the engine reads.
    static let maxPlistBytes = 1_048_576

    /// `<run>/<appPath>`, resolved: `realpath` strictly inside `realpath(run)` (`outsideRepo`), a directory whose name ends in
    /// `.app` (`notBuilt`). Returns the resolved bundle.
    public static func locate(appPath: String, run: URL) throws -> URL {
        try locate(app: run.appending(path: appPath, directoryHint: .isDirectory), run: run)
    }

    /// As `locate(appPath:run:)` for an absolute bundle path.
    public static func locate(app: URL, run: URL) throws -> URL {
        guard let runReal = realpathString(run.path) else { throw WorkError.invalid(notBuilt) }
        guard let real = realpathString(app.path) else { throw WorkError.invalid(notBuilt) }
        guard real.hasPrefix(runReal + "/") else { throw WorkError.invalid(outsideRepo) }
        var st = stat()
        guard real.hasSuffix(".app"), stat(real, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { throw WorkError.invalid(notBuilt) }
        return URL(fileURLWithPath: real, isDirectory: false)
    }

    /// The app's `CFBundleExecutable`, from `Contents/Info.plist` (`PropertyListSerialization`; `noExecutable` when the file is
    /// missing, unreadable, not a dictionary or has no string there): a plain file name, so nothing with `/`, `..`, `'`, a
    /// quote, a backslash or a control character, and not empty or `.` (`badExecutableName`).
    static func executableName(app: URL) throws -> String {
        let plist = app.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
        guard let data = readRegular(plist, limit: maxPlistBytes),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any], let name = dict["CFBundleExecutable"] as? String else {
            throw WorkError.invalid(noExecutable)
        }
        guard !name.isEmpty, name != ".", !name.contains("/"), !name.contains(".."), !name.contains("'"), !SandboxPath.isUnsafe(name) else {
            throw WorkError.invalid(badExecutableName)
        }
        return name
    }

    /// `Contents/MacOS/<name>` of the bundle: a regular file with an execute bit whose `realpath` is still inside the (resolved)
    /// bundle (`executableOutside`). Returns the path as named in the bundle.
    static func executable(app: URL, name: String) throws -> URL {
        guard let appReal = realpathString(app.path) else { throw WorkError.invalid(notBuilt) }
        let candidate = app.appending(path: "Contents/MacOS/\(name)", directoryHint: .notDirectory)
        guard let real = realpathString(candidate.path), real.hasPrefix(appReal + "/") else { throw WorkError.invalid(executableOutside) }
        var st = stat()
        guard stat(real, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_mode & 0o111 != 0 else { throw WorkError.invalid(executableOutside) }
        return candidate
    }

    static func realpathString(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    /// The first `limit` bytes of a regular file (opened without following a link); nil for anything else.
    static func readRegular(_ url: URL, limit: Int) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= limit else { return nil }
        var data = Data(count: Int(st.st_size))
        let n = data.withUnsafeMutableBytes { buf -> Int in
            var done = 0
            while done < buf.count {
                let r = pread(fd, buf.baseAddress! + done, buf.count - done, off_t(done))
                if r < 0 { if errno == EINTR { continue }; return -1 }
                if r == 0 { break }
                done += r
            }
            return done
        }
        guard n == data.count else { return nil }
        return data
    }
}

/// Resolves a built macOS app's executable (`MacAppLaunching`), with the three rules of fix 4: the bundle inside the run, a
/// plain `CFBundleExecutable`, and `Contents/MacOS/<name>` a regular executable inside the bundle.
///
/// Availability: the live check (`LiveSmokeTests.macAppShowsWindowUnderPolicy`) found that an AppKit app aborts at
/// `NSApplication.shared` under 5-lite's profile, which denies the `cfprefsd` and `launchservicesd` mach lookups AppKit needs
/// (the residual the brief anticipated). Until the sandbox allows GUI apps, macOS previews are `unavailable` with
/// `guiResidual`; `guiAllowed: true` (tests, and the day the profile changes) lifts it. The resolution rules work either way.
public struct ProcessMacAppLauncher: MacAppLaunching {
    public static let guiResidual = "macOS app previews need the sandbox to allow GUI apps"

    let guiAllowed: Bool

    public init(guiAllowed: Bool = false) { self.guiAllowed = guiAllowed }

    public func availability() -> String? {
        #if os(macOS)
        guiAllowed ? nil : Self.guiResidual
        #else
        UnavailableMacApps.message
        #endif
    }

    public func executable(inApp app: URL, run: URL) throws -> URL {
        let bundle = try AppBundle.locate(app: app, run: run)
        let name = try AppBundle.executableName(app: bundle)
        // Named relative to the bundle as given (the resolved bundle is inside the run; the returned path is what `exec` runs).
        _ = try AppBundle.executable(app: bundle, name: name)
        return app.appending(path: "Contents/MacOS/\(name)", directoryHint: .notDirectory)
    }
}

// MARK: The Apple build

/// The build step both adapters share: the surface's `build` through the runner `deps.runner(for: c)` picks, in the run, under
/// `c.policy` (`appleBuild`), with its DerivedData inside the run (obligation c): `xcodebuild` is wrapped by an engine-written
/// shell function that passes `-derivedDataPath "$BRAHMA_DERIVED_DATA"` (`<run>/.build/DerivedData`, `PreviewPolicy.derivedData`)
/// before the agent's own arguments, so even a build that forgot the flag writes nothing outside its export. The build's
/// output goes to the log, sealed (capped, redacted) as a CLI build's.
enum AppleBuild {
    /// The function prefix. `command xcodebuild` reaches the real tool; the agent's later arguments win when it passes the
    /// flag itself, and the sandbox refuses any path outside the run either way.
    static let derivedDataPrefix = "xcodebuild() { command xcodebuild -derivedDataPath \"$BRAHMA_DERIVED_DATA\" \"$@\"; }; "

    static func command(_ build: String) -> String { derivedDataPrefix + build }

    /// Nil when the build passed (or there is none); otherwise the update to return.
    static func run(_ c: PreviewContext, deps: PreviewDependencies) async -> PreviewUpdate? {
        guard let build = c.surface.build else { return nil }
        var environment = c.environment
        if environment["BRAHMA_DERIVED_DATA"] == nil { environment["BRAHMA_DERIVED_DATA"] = PreviewPolicy.derivedData(run: c.run).path }
        let outcome = await deps.runner(for: c).run(command: command(build), cwd: c.run, environment: environment, timeout: c.timeouts.build,
                                                    outputURL: c.logURL, policy: c.policy)
        _ = CLIAdapter.seal(c.logURL, redactor: c.redactor)
        if Task.isCancelled { return PreviewUpdate(status: .stopped, message: nil) }
        if CLIAdapter.isUnavailable(outcome) { return PreviewUpdate(status: .unavailable, message: UnavailableSandboxRunner.tail) }
        if outcome.timedOut { return PreviewUpdate(status: .failed, message: "build timed out") }
        guard let code = outcome.exitCode else { return PreviewUpdate(status: .failed, message: "build could not run") }
        if code != 0 { return PreviewUpdate(status: .failed, message: "build failed (exit \(code))") }
        return nil
    }

    /// Blocking tool work (`xcrun simctl`, `Process` waits) off the cooperative pool, on its own thread.
    static func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, any Error>) in
            let thread = Thread { c.resume(with: Result { try body() }) }
            thread.name = "brahma-apple-preview"
            thread.start()
        }
    }
}

// MARK: iOS

/// An iOS Simulator preview. `start` needs the owner's approval on the surface (`outsideSandboxApprovedAt`, Task 4's gate),
/// else it is `unavailable` with the waiting message and nothing is asked of the Simulator. Then: the build (`AppleBuild`),
/// `app_path` resolved inside the run (`AppBundle.locate`: a `.app` directory), the company's own device (`Brahma <slug>`,
/// created with the surface's `device` type when listed, else the first iPhone), `boot` (an already booted device is fine),
/// `install`, `launch(bundle_id)`: `running` with `simulatorId`. `stop` terminates the app and shuts the device down. `demo`
/// saves a screenshot to `previewLogs/<name>-demo-<sprint>.png` (`"<name>: screenshot saved"`). Every Simulator failure is
/// reported with the engine's own words; simctl's output goes to the surface log.
public struct IOSAdapter: PreviewAdapter {
    public let deps: PreviewDependencies

    public init(deps: PreviewDependencies) { self.deps = deps }

    public var kind: PreviewKind { .ios }
    public func availability() -> String? { deps.simulator.availability() }

    public func start(_ c: PreviewContext) async -> PreviewUpdate {
        guard c.surface.outsideSandboxApprovedAt != nil else {
            return PreviewUpdate(status: .unavailable, message: SimulatorApproval.waitingMessage)
        }
        guard let appPath = c.surface.appPath, let bundleId = c.surface.bundleId else {
            return PreviewUpdate(status: .failed, message: "an ios preview needs build, app_path and bundle_id")
        }
        if let failed = await AppleBuild.run(c, deps: deps) { return failed }
        let app: URL
        do { app = try AppBundle.locate(appPath: appPath, run: c.run) } catch {
            return PreviewUpdate(status: .failed, message: PreviewRunner.text(error))
        }
        let (simulator, name, device, log) = (deps.simulator, SimctlController.deviceName(slug: c.company.slug), c.surface.device, c.logURL)
        do {
            let udid = try await AppleBuild.offPool { try simulator.ensureDevice(name: name, deviceType: device) }
            if Task.isCancelled { return PreviewUpdate(status: .stopped, message: nil) }
            try await AppleBuild.offPool { try simulator.boot(udid) }
            try await AppleBuild.offPool { try simulator.install(udid, app: app) }
            try await AppleBuild.offPool { try simulator.launch(udid, bundleId: bundleId) }
            if Task.isCancelled {
                _ = try? await AppleBuild.offPool { try simulator.terminate(udid, bundleId: bundleId) }
                return PreviewUpdate(status: .stopped, message: nil, simulatorId: udid)
            }
            return PreviewUpdate(status: .running, message: nil, simulatorId: udid)
        } catch let failure as SimctlFailure {
            Self.append(failure.detail, to: log, redactor: c.redactor)
            return PreviewUpdate(status: .failed, message: failure.message)
        } catch {
            return PreviewUpdate(status: .failed, message: "Simulator failed: \(Store.flat(PreviewRunner.text(error), max: 160))")
        }
    }

    public func stop(_ c: PreviewContext, state: PreviewState) async {
        guard let udid = state.simulatorId else { return }
        let (simulator, bundleId) = (deps.simulator, c.surface.bundleId)
        _ = try? await AppleBuild.offPool {
            if let bundleId { _ = try? simulator.terminate(udid, bundleId: bundleId) }
            try simulator.shutdown(udid)
        }
    }

    /// `previewLogs/<name>-demo-<sprint>.png` (`<name>-demo.png` without a sprint): any entry already there is removed by
    /// descriptor first (never followed), then simctl writes the screenshot.
    public func demo(_ c: PreviewContext, state: PreviewState) async -> DemoCapture {
        let name = c.surface.name
        guard state.status == .running, let udid = state.simulatorId else { return DemoCapture(ok: false, line: "\(name): not running") }
        let file = c.demoSprint.map { "\(name)-demo-\($0).png" } ?? "\(name)-demo.png"
        let shot = c.layout.previewLogs.appending(path: file, directoryHint: .notDirectory)
        let (simulator, workspace) = (deps.simulator, c.layout.workspace)
        do {
            try await AppleBuild.offPool {
                try EngineFiles.remove(workspace: workspace, dir: ".brahma/preview/logs", name: file)
                try simulator.screenshot(udid, to: shot)
            }
            return DemoCapture(ok: true, line: "\(name): screenshot saved", outputPath: shot.path)
        } catch {
            return DemoCapture(ok: false, line: "\(name): screenshot failed")
        }
    }

    /// simctl's own words, to the surface log (engine-written, no link followed), sealed like a build log.
    static func append(_ text: String, to log: URL, redactor: Redactor?) {
        guard !text.isEmpty else { return }
        let fd = open(log.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        let line = Array((text.hasSuffix("\n") ? text : text + "\n").utf8)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        _ = CLIAdapter.seal(log, redactor: redactor)
    }
}

// MARK: macOS

/// A macOS app preview: the build (`AppleBuild`), the executable resolved by `deps.macApps` (fix 4), then
/// `spawn("exec '<executable>'", policy: c.appPolicy)` (`PreviewPolicy.guiApp`) through the runner `deps.runner(for: c)` picks;
/// the process goes in `deps.processes` and `c.onSpawn` hears its pid. An app gone before one poll interval is
/// `failed("exited during start (exit <n>)")`. `demo` says `"<name>: running"` or `"<name>: not running"`.
public struct MacAppAdapter: PreviewAdapter {
    public let deps: PreviewDependencies

    public init(deps: PreviewDependencies) { self.deps = deps }

    public var kind: PreviewKind { .macos }
    public func availability() -> String? { deps.macApps.availability() }

    /// `exec '<path>'`, the path single-quoted (a `'` inside it is closed, escaped and reopened).
    public static func launchCommand(_ executable: URL) -> String {
        "exec '" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public func start(_ c: PreviewContext) async -> PreviewUpdate {
        guard let appPath = c.surface.appPath else { return PreviewUpdate(status: .failed, message: "a macos preview needs build and app_path") }
        if let failed = await AppleBuild.run(c, deps: deps) { return failed }
        let executable: URL
        do {
            let app = try AppBundle.locate(appPath: appPath, run: c.run)
            executable = try deps.macApps.executable(inApp: app, run: c.run)
        } catch {
            return PreviewUpdate(status: .failed, message: PreviewRunner.text(error))
        }
        let runner = deps.runner(for: c)
        let process: any SandboxedProcess
        do {
            process = try runner.spawn(command: Self.launchCommand(executable), cwd: c.run, environment: c.environment, logURL: c.logURL,
                                       policy: c.appPolicy ?? c.policy)
        } catch SandboxError.unavailable {
            return PreviewUpdate(status: .unavailable, message: UnavailableSandboxRunner.tail)
        } catch {
            return PreviewUpdate(status: .failed, message: "could not launch the app: \(Store.flat(PreviewRunner.text(error), max: 160))")
        }
        deps.processes.insert(process)
        await c.onSpawn?(process.pid)
        try? await AwakeTime.sleep(for: c.timeouts.poll)
        if Task.isCancelled {
            await process.terminate(grace: WebAdapter.stopGrace)
            deps.processes.remove(process.pid)
            return PreviewUpdate(status: .stopped, message: nil, process: process.pid)
        }
        if !process.isAlive() {
            let code = await WebAdapter.exitCode(process)
            deps.processes.remove(process.pid)
            return PreviewUpdate(status: .failed, message: "exited during start (exit \(code))")
        }
        return PreviewUpdate(status: .running, message: nil, process: process.pid)
    }

    public func stop(_ c: PreviewContext, state: PreviewState) async {
        guard let pid = state.pid, let process = deps.processes.process(pid) else { return }
        await process.terminate(grace: WebAdapter.stopGrace)
        deps.processes.remove(pid)
    }

    public func demo(_ c: PreviewContext, state: PreviewState) async -> DemoCapture {
        let name = c.surface.name
        if state.status == .running, let pid = state.pid, let process = deps.processes.process(pid), process.isAlive() {
            return DemoCapture(ok: true, line: "\(name): running")
        }
        return DemoCapture(ok: false, line: "\(name): not running")
    }
}

// MARK: simctl

/// A `simctl` call that did not succeed: the engine's message (no tool output) and simctl's words for the log.
struct SimctlFailure: Error, Sendable {
    var message: String
    var detail: String
}

/// The iOS Simulator through `xcrun simctl` (`Process`, engine-fixed argv; `SandboxedRunner` is not involved: Task 4's
/// constraint lists `xcrun simctl` among the plain-`Process` tools). The engine touches only its own devices, named
/// `Brahma <slug>`; the owner's simulators are never created, booted, shut down or listed as ours.
public struct SimctlController: SimulatorControlling {
    public typealias Exec = @Sendable ([String]) -> (status: Int32, stdout: String, stderr: String)

    public static let devicePrefix = "Brahma "
    /// How long one `simctl` call may take.
    public static let callTimeout: TimeInterval = 180

    let exec: Exec
    let available: @Sendable () -> Bool

    /// The real `xcrun simctl`.
    public init() { self.init(exec: Self.xcrunSimctl, available: Self.findSimctl) }

    init(exec: @escaping Exec, available: @escaping @Sendable () -> Bool) { self.exec = exec; self.available = available }

    public static func deviceName(slug: String) -> String { devicePrefix + slug }
    public static func isBrahmaDevice(_ name: String) -> Bool { name.hasPrefix(devicePrefix) }

    struct Device: Equatable, Sendable {
        var name: String
        var udid: String
        var state: String
        var isAvailable: Bool
    }

    struct DeviceType: Equatable, Sendable {
        var name: String
        var identifier: String
        var productFamily: String
    }

    // MARK: Availability

    public func availability() -> String? {
        #if os(macOS)
        available() ? nil : UnavailableSimulator.message
        #else
        UnavailableSimulator.message
        #endif
    }

    /// Whether `xcrun --find simctl` succeeds.
    static let findSimctl: @Sendable () -> Bool = {
        #if os(macOS)
        return runProcess("/usr/bin/xcrun", ["--find", "simctl"], timeout: 30)?.status == 0
        #else
        return false
        #endif
    }

    /// `xcrun simctl <argv>`.
    static let xcrunSimctl: Exec = { argv in
        runProcess("/usr/bin/xcrun", ["simctl"] + argv, timeout: callTimeout) ?? (status: -1, stdout: "", stderr: "could not run xcrun")
    }

    /// Runs `executable` with `arguments` to completion (or `timeout`, then SIGKILL), capturing both streams.
    static func runProcess(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, stdout: String, stderr: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        var env: [String: String] = ["PATH": "/usr/bin:/bin"]
        for key in ["DEVELOPER_DIR", "HOME", "TMPDIR"] { if let v = ProcessInfo.processInfo.environment[key] { env[key] = v } }
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return nil }
        final class Box: @unchecked Sendable { var out = Data(); var err = Data() }
        let box = Box()
        let readers = DispatchGroup()
        readers.enter(); Thread.detachNewThread { box.out = out.fileHandleForReading.readDataToEndOfFile(); readers.leave() }
        readers.enter(); Thread.detachNewThread { box.err = err.fileHandleForReading.readDataToEndOfFile(); readers.leave() }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            kill(p.processIdentifier, SIGKILL)
            done.wait()
        }
        readers.wait()
        return (p.terminationStatus, String(decoding: box.out, as: UTF8.self), String(decoding: box.err, as: UTF8.self))
    }

    // MARK: Devices

    public func ensureDevice(name: String, deviceType: String?) throws -> String {
        guard Self.isBrahmaDevice(name) else { throw WorkError.invalid("the engine controls only its own Brahma Simulator devices") }
        let devices = try Self.parseDevices(try data(["list", "devices", "-j"], verb: "list"))
        if let mine = devices.first(where: { $0.name == name && $0.isAvailable }) { return mine.udid }
        let types = try Self.parseDeviceTypes(try data(["list", "devicetypes", "-j"], verb: "list"))
        guard let type = Self.pick(types, named: deviceType) else {
            throw SimctlFailure(message: "no iPhone Simulator device type is installed", detail: "")
        }
        let created = try run(["create", name, type.identifier], verb: "create")
        let udid = created.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !udid.isEmpty, udid.count <= 64, !udid.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw SimctlFailure(message: "Simulator create gave no device id", detail: created)
        }
        return udid
    }

    /// An already booted device is fine.
    public func boot(_ udid: String) throws { try run(["boot", udid], verb: "boot", tolerating: "current state: Booted") }
    public func install(_ udid: String, app: URL) throws { try run(["install", udid, app.path], verb: "install") }
    public func launch(_ udid: String, bundleId: String) throws { try run(["launch", udid, bundleId], verb: "launch") }
    public func terminate(_ udid: String, bundleId: String) throws { try run(["terminate", udid, bundleId], verb: "terminate") }
    /// An already shut down device is fine.
    public func shutdown(_ udid: String) throws { try run(["shutdown", udid], verb: "shutdown", tolerating: "current state: Shutdown") }
    public func screenshot(_ udid: String, to: URL) throws { try run(["io", udid, "screenshot", to.path], verb: "screenshot") }
    /// Deletes one of the engine's devices (the live check's cleanup).
    public func delete(_ udid: String) throws { try run(["delete", udid], verb: "delete") }

    /// Every booted `Brahma …` device is shut down (an earlier engine's leftovers; obligation b). Owner devices are never
    /// touched. Returns the UDIDs shut down; nothing without simctl.
    public func shutdownLeftovers() throws -> [String] {
        guard availability() == nil else { return [] }
        let devices = try Self.parseDevices(try data(["list", "devices", "-j"], verb: "list"))
        var done: [String] = []
        for device in Self.bootedBrahmaDevices(devices) {
            try shutdown(device.udid)
            done.append(device.udid)
        }
        return done
    }

    static func bootedBrahmaDevices(_ devices: [Device]) -> [Device] {
        devices.filter { isBrahmaDevice($0.name) && $0.isAvailable && $0.state == "Booted" }
    }

    /// `simctl list devices -j`: every device of every runtime (runtimes in key order, devices as listed).
    static func parseDevices(_ data: Data) throws -> [Device] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = root["devices"] as? [String: Any] else { throw WorkError.invalid("unexpected simctl device list") }
        var devices: [Device] = []
        for key in runtimes.keys.sorted() {
            for entry in runtimes[key] as? [[String: Any]] ?? [] {
                guard let name = entry["name"] as? String, let udid = entry["udid"] as? String else { continue }
                devices.append(Device(name: name, udid: udid, state: entry["state"] as? String ?? "", isAvailable: entry["isAvailable"] as? Bool ?? false))
            }
        }
        return devices
    }

    /// `simctl list devicetypes -j`.
    static func parseDeviceTypes(_ data: Data) throws -> [DeviceType] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["devicetypes"] as? [[String: Any]] else { throw WorkError.invalid("unexpected simctl device type list") }
        return list.compactMap { entry in
            guard let name = entry["name"] as? String, let id = entry["identifier"] as? String else { return nil }
            return DeviceType(name: name, identifier: id, productFamily: entry["productFamily"] as? String ?? "")
        }
    }

    /// The type named `named` when it is listed, else the first iPhone; nil when there is no iPhone at all.
    static func pick(_ types: [DeviceType], named: String?) -> DeviceType? {
        if let named, let exact = types.first(where: { $0.name == named }) { return exact }
        return types.first { $0.productFamily == "iPhone" }
    }

    // MARK: Calls

    @discardableResult
    private func run(_ argv: [String], verb: String, tolerating: String? = nil) throws -> String {
        let result = exec(argv)
        if result.status == 0 { return result.stdout }
        if let tolerating, result.stderr.contains(tolerating) || result.stdout.contains(tolerating) { return result.stdout }
        throw SimctlFailure(message: "Simulator \(verb) failed (exit \(result.status))", detail: result.stderr.isEmpty ? result.stdout : result.stderr)
    }

    private func data(_ argv: [String], verb: String) throws -> Data { Data(try run(argv, verb: verb).utf8) }
}
