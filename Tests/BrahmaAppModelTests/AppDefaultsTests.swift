import Foundation
import Testing
@testable import BrahmaAppModel

/// Final-wave item 20 (FW-B2): the smoke, UI-snapshot and map runs never write the owner's real `dev.brahma.app` defaults. The
/// app refuses a harness launch except as a harness copy (its own throwaway defaults domain); the scripts launch only such a
/// copy and remove its domain; test suites (C6 M13) are removed when the test process exits.
@Suite(.scratch) struct AppDefaultsTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func harnessLaunchesRunOnlyAsAHarnessCopy() {
        let owner = LaunchOptions.parse(["Brahma"])
        #expect(AppDefaults.decide(options: owner, bundleIdentifier: AppDefaults.ownerDomain) == .standard)
        for args in [["--smoke-test"], ["--ui-snapshot", "/tmp/x.png"], ["--map-demo"], ["--map-bench=5"]] {
            let options = LaunchOptions.parse(["Brahma"] + args)
            #expect(AppDefaults.isHarness(options), "\(args)")
            guard case .refuse(let why) = AppDefaults.decide(options: options, bundleIdentifier: AppDefaults.ownerDomain) else {
                Issue.record("\(args) would run under the owner's defaults"); continue
            }
            #expect(why.contains(AppDefaults.ownerDomain) && why.contains("harness-app.sh"))
            for other in [nil, "", "dev.brahma.harness.", "com.example.brahma", "dev.brahma.app.harness.x"] {
                #expect(AppDefaults.decide(options: options, bundleIdentifier: other) != .standard, "\(args) under \(other ?? "nil")")
            }
            #expect(AppDefaults.decide(options: options, bundleIdentifier: "dev.brahma.harness.0a1b2c3d") == .standard)
        }
    }

    /// Every script that launches the app for a harness run goes through `scripts/harness-app.sh`: it prepares the copy, cleans
    /// its domain up on exit, and never starts `.build/Brahma.app` itself.
    @Test func harnessScriptsLaunchOnlyTheCopy() throws {
        let scripts = Self.repo.appending(path: "scripts")
        let names = try FileManager.default.contentsOfDirectory(atPath: scripts.path).filter { $0.hasSuffix(".sh") }
        var launching: [String] = []
        for name in names where name != "make-app.sh" && name != "harness-app.sh" {
            let text = try String(contentsOf: scripts.appending(path: name), encoding: .utf8)
            #expect(!text.contains(".build/Brahma.app/Contents/MacOS/Brahma"), "\(name) starts the owner's bundle")
            guard ["--smoke-test", "--ui-snapshot", "--map-demo", "--map-bench"].contains(where: text.contains) else { continue }
            launching.append(name)
            let usesCopy = text.contains(". scripts/harness-app.sh") && text.contains("harness_app_prepare") && text.contains("harness_app_cleanup")
            #expect(usesCopy && text.contains("\"$HARNESS_APP\""), "\(name) does not launch the harness copy")
        }
        #expect(Set(launching).isSuperset(of: ["ui-snapshot.sh", "smoke-app.sh", "map-demo.sh"]), "\(launching)")
    }

    /// The helper's copy carries a `dev.brahma.harness.<id>` identifier, is validly signed, and its cleanup removes only that
    /// domain. Run on a stand-in bundle (no app is launched, no owner defaults are read or written).
    @Test func harnessCopyHasItsOwnIdentifier() throws {
        let fm = FileManager.default
        let dir = try tempDir()
        ScratchScope.current?.allowExecutable(named: "Brahma")   // the stand-in bundle's executable (and its copy), never run
        let bundle = dir.appending(path: ".build/Brahma.app/Contents")
        try fm.createDirectory(at: bundle.appending(path: "MacOS"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: bundle.appending(path: "MacOS/Brahma").path)
        try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>dev.brahma.app</string><key>CFBundleExecutable</key><string>Brahma</string>
            <key>CFBundlePackageType</key><string>APPL</string></dict></plist>
            """.utf8).write(to: bundle.appending(path: "Info.plist"))
        let out = dir.appending(path: "out")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let script = """
            set -euo pipefail
            codesign --force --sign - --identifier dev.brahma.app .build/Brahma.app >/dev/null 2>&1
            . '\(Self.repo.appending(path: "scripts/harness-app.sh").path)'
            harness_app_prepare '\(out.path)'
            /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$HARNESS_BUNDLE/Contents/Info.plist"
            /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' .build/Brahma.app/Contents/Info.plist
            echo "app=$HARNESS_APP"
            harness_app_cleanup
            """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        p.currentDirectoryURL = dir
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "\(text)")
        let lines = text.split(separator: "\n").map(String.init)
        let copied = try #require(lines.first)
        #expect(copied.hasPrefix(AppDefaults.harnessPrefix) && copied.count > AppDefaults.harnessPrefix.count + 8, "\(text)")
        #expect(lines.dropFirst().first == AppDefaults.ownerDomain, "the owner's bundle was changed: \(text)")
        #expect(lines.contains("app=\(out.path)/Brahma.app/Contents/MacOS/Brahma"), "\(text)")
    }

    /// C6 M13: test suites are made only through `TestDefaults` (removed at exit), never as bare `UserDefaults(suiteName:)`.
    @Test func testSuitesAreScratchDefaults() throws {
        let fm = FileManager.default
        let tests = Self.repo.appending(path: "Tests")
        guard let walker = fm.enumerator(atPath: tests.path) else { Issue.record("no Tests directory"); return }
        var offenders: [String] = []
        for case let rel as String in walker where rel.hasSuffix(".swift") && !rel.hasSuffix("/TestDefaults.swift")
            && !rel.hasSuffix("BrahmaAppModelTests/TestSupport.swift") && !rel.hasSuffix("AppDefaultsTests.swift") {
            let text = try String(contentsOf: tests.appending(path: rel), encoding: .utf8)
            if text.contains("UserDefaults(suiteName:") { offenders.append(rel) }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
