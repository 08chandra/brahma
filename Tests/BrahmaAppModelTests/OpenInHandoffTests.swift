import Foundation
import Testing
import BrahmaCore
@testable import BrahmaAppModel

/// "Open in…" hands the owner's default app a vetted copy, never the artifact's own path (Plan 4a Task 9c, Part B).
@MainActor @Suite(.scratch) struct OpenInHandoffTests {
    /// A recorder in the opener's seat: what reached it, and whether it "opened".
    final class Opener: @unchecked Sendable {
        private(set) var opened: [URL] = []
        var answer = true
        func open(_ url: URL) -> Bool { opened.append(url); return answer }
    }

    private func fixture() throws -> (artifact: URL, folder: URL) {
        let root = try tempDir()
        let artifact = root.appending(path: "artifact", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        return (artifact, root.appending(path: "home/run/open-in", directoryHint: .isDirectory))
    }

    private func write(_ url: URL, _ bytes: [UInt8], mode: mode_t = 0o644) throws {
        try Data(bytes).write(to: url)
        chmod(url.path, mode)
    }

    private static let cad: [UInt8] = Array("ISO-10303-21;\nHEADER;\nENDSEC;\nEND-ISO-10303-21;\n".utf8)

    /// A plain CAD file (the kind the file card shows): opened through a fresh copy in the engine-only folder (0700; the copy
    /// 0600, no execute bit, quarantined, same bytes), and the opener never sees the original path.
    @Test func plainCADOpensViaTheCopy() async throws {
        let (artifact, folder) = try fixture()
        let original = artifact.appending(path: "part.step")
        try write(original, Self.cad)
        let opener = Opener()
        let result = await OpenInHandoff.openCopy(original, into: folder, opener: opener.open)
        let copy = try result.get()
        #expect(opener.opened == [copy])
        #expect(!opener.opened.contains(original))
        #expect(copy.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/"))
        #expect(copy.pathExtension == "step")
        #expect(try Data(contentsOf: copy) == Data(Self.cad))
        var st = stat()
        #expect(lstat(copy.path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(getxattr(copy.path, "com.apple.quarantine", nil, 0, 0, 0) > 0, "the copy is quarantined")
        var dir = stat()
        #expect(stat(folder.path, &dir) == 0 && dir.st_mode & 0o777 == 0o700)
        // The original is untouched.
        #expect(try Data(contentsOf: original) == Data(Self.cad))
    }

    /// Safe by construction (fix round 1, M3): only CAD, 3D-model and image kinds are handed over at all. A `.pdf` (Quick
    /// Look's, never the file card's) and an unknown extension are refused by kind before anything is opened.
    @Test func onlyFileCardKindsAreHandedOver() async throws {
        let (artifact, folder) = try fixture()
        let opener = Opener()
        for name in ["report.pdf", "Report.PDF", "notes.md", "page.html", "data.csv", "clip.mp4", "thing.xyz123", "noext"] {
            let file = artifact.appending(path: name)
            try write(file, Self.cad)
            #expect(await OpenInHandoff.openCopy(file, into: folder, opener: opener.open) == .failure(.kindNotHandedOver(ArtifactKind.ext(of: name))), Comment(rawValue: name))
        }
        #expect(opener.opened.isEmpty)
        #expect(OpenInHandoff.allowedKinds == [.cad, .model3d, .image])
        for name in ["model.glb", "scan.stl", "photo.png", "part.iges"] {
            let file = artifact.appending(path: name)
            try write(file, Self.cad)
            #expect((try? (await OpenInHandoff.openCopy(file, into: folder, opener: opener.open)).get()) != nil, Comment(rawValue: name))
        }
        #expect(opener.opened.count == 4)
    }

    /// A symlink swapped in for an `.app` bundle (what a click would launch): refused before anything is opened.
    @Test func symlinkToAppRefused() async throws {
        let (artifact, folder) = try fixture()
        let bundle = artifact.appending(path: "Evil.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        let swapped = artifact.appending(path: "part.step")
        try FileManager.default.createSymbolicLink(at: swapped, withDestinationURL: bundle)
        let opener = Opener()
        #expect(await OpenInHandoff.openCopy(swapped, into: folder, opener: opener.open) == .failure(.notRegular))
        #expect(opener.opened.isEmpty)
        // A link to a regular file is refused the same way: nothing is ever resolved by path.
        let real = artifact.appending(path: "real.step")
        try write(real, Self.cad)
        let link = artifact.appending(path: "linked.step")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(await OpenInHandoff.openCopy(link, into: folder, opener: opener.open) == .failure(.notRegular))
        #expect(opener.opened.isEmpty)
    }

    /// `.command` (Terminal runs it), in any case, and the other launch-capable extensions: refused by name.
    @Test func commandFileRefused() async throws {
        let (artifact, folder) = try fixture()
        let opener = Opener()
        for name in ["run.command", "RUN.COMMAND", "notes.step.Command", "x.tool", "x.terminal", "x.workflow", "x.webloc",
                     "x.inetloc", "x.fileloc", "x.app", "x.pkg", "x.dmg", "x.jar", "x.sh", "x.scpt", "x.shortcut",
                     "x.afploc", "x.vncloc", "x.mobileconfig", "x.py", "x.iso", "x.webarchive"] {
            let file = artifact.appending(path: name)
            try write(file, Array("echo hi\n".utf8))
            let ext = ArtifactKind.ext(of: name)
            #expect(await OpenInHandoff.openCopy(file, into: folder, opener: opener.open) == .failure(.launchable(ext)), Comment(rawValue: name))
        }
        #expect(opener.opened.isEmpty)
        #expect(OpenInHandoff.refusedExtensions.isSuperset(of: ["app", "command", "tool", "terminal", "workflow", "webloc", "inetloc", "fileloc"]))
        #expect(OpenInHandoff.refusedExtensions.allSatisfy { $0 == $0.lowercased() })
    }

    /// Any execute bit refuses the file, whatever it is called.
    @Test func executableBitRefused() async throws {
        let (artifact, folder) = try fixture()
        let opener = Opener()
        for mode in [0o755, 0o744, 0o700, 0o611] {
            let file = artifact.appending(path: "part-\(String(mode, radix: 8)).step")
            try write(file, Self.cad)
            try FakeTools.fixtureMode(mode, at: file)   // the execute bit is what is under test here
            #expect(await OpenInHandoff.openCopy(file, into: folder, opener: opener.open) == .failure(.executable), Comment(rawValue: String(mode, radix: 8)))
        }
        #expect(opener.opened.isEmpty)
    }

    /// A directory or bundle named like a document, and a file with another hard link (S7), are refused too.
    @Test func bundleAndHardLinkRefused() async throws {
        let (artifact, folder) = try fixture()
        let opener = Opener()
        let dir = artifact.appending(path: "part.step", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(await OpenInHandoff.openCopy(dir, into: folder, opener: opener.open) == .failure(.bundleOrDirectory))
        let real = artifact.appending(path: "a.step")
        try write(real, Self.cad)
        let hard = artifact.appending(path: "b.step")
        try FileManager.default.linkItem(at: real, to: hard)
        #expect(await OpenInHandoff.openCopy(hard, into: folder, opener: opener.open) == .failure(.unsafeFile("has another hard link")))
        let missing = artifact.appending(path: "gone.step")
        #expect(await OpenInHandoff.openCopy(missing, into: folder, opener: opener.open) == .failure(.unreadable))
        #expect(opener.opened.isEmpty)
    }

    /// The copy carries an engine-made name (a safe base, the original's extension) and never the agent's name verbatim; the
    /// opener's refusal is reported as such; every refusal has an engine-written message.
    @Test func copyNamesAndMessages() async throws {
        let (artifact, folder) = try fixture()
        let original = artifact.appending(path: "Q3 résumé (final)!!.STEP")
        try write(original, Self.cad)
        let opener = Opener()
        let copy = try await OpenInHandoff.openCopy(original, into: folder, opener: opener.open).get()
        #expect(copy.lastPathComponent.hasSuffix(".step"))
        #expect(copy.lastPathComponent.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "-" || $0 == "_" || $0 == ".") })
        #expect(copy.lastPathComponent != original.lastPathComponent)
        opener.answer = false
        #expect(await OpenInHandoff.openCopy(original, into: folder, opener: opener.open) == .failure(.noApp))
        for refusal in [OpenInHandoff.Refusal.notRegular, .bundleOrDirectory, .executable, .launchable("command"),
                        .unsafeFile("has another hard link"), .tooLarge, .unreadable, .copyFailed("x"), .noApp, .kindNotHandedOver("pdf")] {
            #expect(!OpenInHandoff.message(refusal).isEmpty)
        }
        #expect(OpenInHandoff.message(.launchable("command")) == "Not opened: .command files can run programs")
    }

    /// "Reveal in Finder" (fix round 1): the same seam with `kinds: nil`, so any artifact kind is revealed as its vetted copy;
    /// a symlink swapped in for an `.app` is refused, Finder is never pointed at the agent's path, and `vet` says up front why a
    /// button must be disabled.
    @Test func revealInFinderShowsTheCopyAndRefusesASwappedApp() async throws {
        let (artifact, folder) = try fixture()
        let finder = Opener()
        let pdf = artifact.appending(path: "report.pdf")
        try write(pdf, Array("%PDF-1.4\n".utf8))
        #expect(OpenInHandoff.vet(pdf, kinds: nil) == nil)
        #expect(OpenInHandoff.vet(pdf) == .kindNotHandedOver("pdf"), "the file card's \"Open in…\" still refuses a pdf by kind")
        let copy = try await OpenInHandoff.openCopy(pdf, into: folder, kinds: nil, opener: finder.open).get()
        #expect(finder.opened == [copy] && copy != pdf && copy.pathExtension == "pdf")
        #expect(copy.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/"))

        let bundle = artifact.appending(path: "Evil.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        let swapped = artifact.appending(path: "index.html")
        try FileManager.default.createSymbolicLink(at: swapped, withDestinationURL: bundle)
        #expect(OpenInHandoff.vet(swapped, kinds: nil) == .notRegular)
        #expect(await OpenInHandoff.openCopy(swapped, into: folder, kinds: nil, opener: finder.open) == .failure(.notRegular))
        let script = artifact.appending(path: "demo.command")
        try write(script, Array("echo hi\n".utf8))
        #expect(OpenInHandoff.vet(script, kinds: nil) == .launchable("command"))
        let exec = artifact.appending(path: "tool.step")
        try write(exec, Self.cad)
        try FakeTools.fixtureMode(0o755, at: exec)
        #expect(OpenInHandoff.vet(exec, kinds: nil) == .executable)
        #expect(finder.opened == [copy], "Finder saw the one vetted copy and nothing else")
        #expect(!finder.opened.contains(swapped) && !finder.opened.contains(script) && !finder.opened.contains(exec))
    }
}
