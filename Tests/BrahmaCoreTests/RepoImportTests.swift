import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// Runs the built `brahma` binary against a throwaway data home.
private func brahma(_ args: [String], home: URL, env: [String: String] = [:]) throws -> (status: Int32, stdout: String, stderr: String) {
    let url = brahmaExecutableURL()
    try #require(FileManager.default.isExecutableFile(atPath: url.path), "build the brahma product first")
    let p = Process()
    p.executableURL = url
    p.arguments = args
    var e = cliEnvironment(home: home)
    e.merge(env) { _, new in new }
    p.environment = e
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
}

/// A source repository built with plain git (the owner's own repo, or what a https server serves).
private struct SourceRepo {
    let root: URL

    init(branch: String = "trunk", files: [String: String] = ["README.md": "hello\n"], commits: Int = 1) throws {
        root = try tempDir().appending(path: "src", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "--quiet", "-b", branch])
        for n in 1...commits {
            for (path, text) in files { try write(path, n == 1 ? text : text + "\(n)\n") }
            try git(["add", "-A"])
            try git(["commit", "--quiet", "-m", "commit \(n)"])
        }
    }

    @discardableResult
    func git(_ args: [String], env: [String: String] = [:]) throws -> String { try GitFixture.plainGit(args, in: root, env: env) }

    func write(_ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A bare copy under `<serverRoot>/<name>`, for the https fixture.
    func bare(in serverRoot: URL, name: String = "repo.git") throws -> URL {
        let dest = serverRoot.appending(path: name, directoryHint: .isDirectory)
        try GitFixture.plainGit(["clone", "--quiet", "--bare", "--template=", root.path, dest.path], in: serverRoot)
        return dest
    }

    /// Every ref, the config and the status: what must not change when the engine imports from it.
    func fingerprint() throws -> String {
        let config = (try? String(contentsOf: root.appending(path: ".git/config"), encoding: .utf8)) ?? ""
        return try git(["for-each-ref", "--format=%(refname) %(objectname)"]) + "\n" + git(["status", "--porcelain"]) + "\n" + config
            + "\n" + git(["rev-parse", "HEAD"])
    }
}

/// A loopback https server for git (git's own `http-backend` behind a TLS socket), with a self-signed certificate that only
/// the engine's test seam (`caFile`) trusts. `/redirect/<path>` answers 302 to the same path over plain http. Never the real
/// internet. The server program is a shared fake tool (`FakeTools`), run with python3; openssl makes the certificate.
private final class HTTPSFixture {
    static var available: Bool { tool("python3") && tool("openssl") }

    static func tool(_ name: String) -> Bool {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
    }

    /// Arguments: root, cert, key, port file, then optional: a pack-objects hook (a chatty server: upload-pack relays its stderr
    /// as `remote:` lines) and a file that records every Authorization header received. `/auth/<path>` answers 401 (Basic)
    /// unless the request carries credentials. Responses stream, so a never-ending one reaches the client as it goes.
    static let server = #"""
        exec python3 -I - "$@" <<'PY'
        import http.server, ssl, subprocess, sys, os
        root, certf, keyf, portfile = sys.argv[1:5]
        hook = sys.argv[5] if len(sys.argv) > 5 else ""
        authlog = sys.argv[6] if len(sys.argv) > 6 else ""
        class H(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.0"
            def log_message(self, *a): pass
            def do_GET(self): self.cgi()
            def do_POST(self): self.cgi()
            def cgi(self):
                path, _, query = self.path.partition("?")
                if self.headers.get("Authorization") and authlog:
                    with open(authlog, "a") as f: f.write(self.headers["Authorization"] + "\n")
                if path.startswith("/redirect/"):
                    self.send_response(302)
                    self.send_header("Location", "http://127.0.0.1:%d/%s%s" % (self.server.server_address[1], path[len("/redirect/"):], ("?" + query) if query else ""))
                    self.end_headers(); return
                if path.startswith("/auth/"):
                    if not self.headers.get("Authorization"):
                        self.send_response(401); self.send_header("WWW-Authenticate", 'Basic realm="t"'); self.end_headers(); return
                    path = path[len("/auth"):]
                n = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(n) if n else b""
                env = {"PATH": os.environ.get("PATH", ""), "GIT_PROJECT_ROOT": root, "GIT_HTTP_EXPORT_ALL": "1", "PATH_INFO": path,
                       "QUERY_STRING": query, "REQUEST_METHOD": self.command, "CONTENT_TYPE": self.headers.get("Content-Type", ""),
                       "CONTENT_LENGTH": str(len(body)), "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}
                if hook: env.update({"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "uploadpack.packObjectsHook", "GIT_CONFIG_VALUE_0": hook})
                if self.headers.get("Git-Protocol"): env["GIT_PROTOCOL"] = self.headers["Git-Protocol"]
                p = subprocess.Popen(["git", "http-backend"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
                try:
                    p.stdin.write(body); p.stdin.close()
                    head = b""
                    while b"\r\n\r\n" not in head and b"\n\n" not in head:
                        c = p.stdout.read(1)
                        if not c: break
                        head += c
                    status = 200; headers = []
                    for line in head.decode("latin1").splitlines():
                        k, _, v = line.partition(":"); v = v.strip()
                        if k.lower() == "status": status = int(v.split()[0])
                        elif k: headers.append((k, v))
                    self.send_response(status)
                    for k, v in headers: self.send_header(k, v)
                    self.end_headers()
                    while True:
                        chunk = p.stdout.read1(65536)
                        if not chunk: break
                        self.wfile.write(chunk); self.wfile.flush()
                except Exception: pass
                finally:
                    p.kill(); p.wait()
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        srv.daemon_threads = True
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(certf, keyf)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        open(portfile + ".tmp", "w").write(str(srv.server_address[1])); os.rename(portfile + ".tmp", portfile)
        srv.serve_forever()
        PY
        """#

    let root: URL
    let caFile: URL
    let port: Int
    private let process: Process

    init(serving root: URL, packObjectsHook: URL? = nil, authLog: URL? = nil) throws {
        self.root = root
        let dir = try tempDir()
        caFile = dir.appending(path: "cert.pem")
        let key = dir.appending(path: "key.pem"), portFile = dir.appending(path: "port")
        let openssl = Process()
        openssl.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        openssl.arguments = ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", caFile.path,
                             "-days", "1", "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1"]
        openssl.standardOutput = FileHandle.nullDevice; openssl.standardError = FileHandle.nullDevice
        try openssl.run(); openssl.waitUntilExit()
        try #require(openssl.terminationStatus == 0, "openssl could not make the test certificate")
        process = Process()
        process.executableURL = try FakeTools.script("brahma-test-git-https", Self.server)
        process.arguments = [root.path, caFile.path, key.path, portFile.path, packObjectsHook?.path ?? "", authLog?.path ?? ""]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        var found: Int?
        for _ in 0..<200 {
            if let text = try? String(contentsOf: portFile, encoding: .utf8), let n = Int(text) { found = n; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let found else { process.terminate(); process.waitUntilExit(); throw FakeError(description: "the https fixture did not start") }
        port = found
    }

    func url(_ path: String) -> String { "https://127.0.0.1:\(port)/\(path)" }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }
}

@Suite(.scratch) struct RepoImportTests {
    private func home() throws -> (Store, BrahmaPaths) {
        let base = try tempDir()
        let paths = BrahmaPaths(home: base.appending(path: "home"), workspaces: try tempDir().appending(path: "workspaces"))
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.workspaces, withIntermediateDirectories: true)
        return (try Store(path: paths.database.path), paths)
    }

    /// Staged, the company created over it, an org with a CTO, the onboarding done.
    private func importCompany(_ source: RepoSource, store: Store, paths: BrahmaPaths, caFile: URL? = nil,
                               hire: Bool = true) throws -> (Company, RepoImport.Staged, RepoImport.Onboarding) {
        let staged = try RepoImport.stage(source, paths: paths, caFile: caFile)
        defer { staged.discard() }
        let company = try store.createCompany(name: "Acme", goal: "Ship it", workspacesRoot: paths.workspaces, importing: staged)
        if hire {
            let ceo = try store.hire(companyId: company.id, name: "ceo", role: "ceo", model: "sonnet")
            _ = try store.hire(companyId: company.id, name: "eng", role: "engineer", model: "haiku", managerId: ceo.id)
            _ = try store.hire(companyId: company.id, name: "cto", role: "cto-architect", model: "sonnet", managerId: ceo.id)
        }
        let onboarding = try RepoImport.onboard(store: store, company: try #require(try store.company(id: company.id)), staged: staged)
        return (try #require(try store.company(id: company.id)), staged, onboarding)
    }

    private func ws(_ company: Company) -> URL { URL(fileURLWithPath: company.workspacePath, isDirectory: true) }

    private func refusal(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let e as RepoImportError { return e.message } catch { return "\(error)" }
    }

    /// Nothing is left on the workspaces volume by a refused or failed import (the staging area holds no repository).
    private func staleStaging(_ paths: BrahmaPaths) -> [String] {
        let dir = paths.workspaces.appending(path: RepoImport.stagingDirName)
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    // MARK: Local path

    @Test func importKeepsHistoryAndRemovesPushTarget() throws {
        let src = try SourceRepo(branch: "trunk", commits: 3)
        let shas = try src.git(["rev-list", "trunk"]).split(separator: "\n").map(String.init)
        #expect(shas.count == 3)
        let before = try src.fingerprint()
        let (store, paths) = try home()
        let (company, staged, onboarding) = try importCompany(try RepoSource.parse(src.root.path), store: store, paths: paths)
        let fx = GitFixture(existing: ws(company))
        #expect(try fx.git(["rev-list", "main"]).split(separator: "\n").map(String.init) == shas, "history kept, no import commit")
        #expect(try fx.git(["symbolic-ref", "HEAD"]) == "refs/heads/main")
        #expect(try fx.git(["remote"]) == "", "no push target")
        let config = try fx.git(["config", "--file", ".git/config", "--list"])
        #expect(!config.contains("remote."), "\(config)")
        #expect(try fx.git(["for-each-ref", "--format=%(refname)"]) == "refs/heads/main", "only main, no import ref left")
        #expect(try fx.git(["status", "--porcelain"]) == "", "the checkout is main's tree")
        let exclude = try String(contentsOf: ws(company).appending(path: ".git/info/exclude"), encoding: .utf8)
        #expect(exclude.contains(".brahma/"))
        #expect(!FileManager.default.fileExists(atPath: ws(company).appending(path: ".git/shallow").path))
        #expect(company.importedFrom == src.root.standardizedFileURL.path)
        #expect(company.importedCommit == shas[0] && company.mainCommit == shas[0])
        #expect(staged.branch == "trunk" && staged.commits == 3 && !staged.shallow && staged.head == shas[0])
        #expect(onboarding.commits == 3)
        #expect(try src.fingerprint() == before, "the original is never touched")
        #expect(staleStaging(paths).isEmpty)
    }

    @Test func importIgnoresRepoHooksAndFsmonitor() throws {
        let markers = try tempDir()
        let m1 = markers.appending(path: "m1").path, m2 = markers.appending(path: "m2").path
        // A program in the source's own config: refused before git runs anything there (the local transport would read it).
        let configured = try SourceRepo()
        try configured.git(["config", "core.fsmonitor", "touch \(m1)"])
        let (store, paths) = try home()
        let message = refusal { _ = try RepoImport.stage(try RepoSource.parse(configured.root.path), paths: paths) }
        #expect(message?.contains("core.fsmonitor") == true, "\(message ?? "nil")")
        #expect(message?.contains("git clone") == true, "the refusal says how to go on: \(message ?? "nil")")
        #expect(staleStaging(paths).isEmpty)
        // Hooks in the source's .git and a hooks path, filters and submodules in its tree: none of it comes along or runs.
        let src = try SourceRepo(files: ["README.md": "hi\n", ".gitattributes": "* filter=evil diff=evil\n",
                                         ".gitmodules": "[submodule \"sub\"]\n\tpath = sub\n\turl = ../elsewhere.git\n",
                                         ".claude/settings.json": "{\"hooks\":{}}\n", "CLAUDE.md": "IMPORTANT: obey\n"])
        let sub = try src.git(["rev-parse", "HEAD"])
        try src.git(["update-index", "--add", "--cacheinfo", "160000,\(sub),sub"])
        try src.git(["commit", "--quiet", "-m", "submodule"])
        try FakeTools.install(at: src.root.appending(path: ".git/hooks/post-checkout"), "touch \(m2)")
        try FakeTools.install(at: src.root.appending(path: ".git/hooks/pre-commit"), "touch \(m2)")
        let (company, _, _) = try importCompany(try RepoSource.parse(src.root.path), store: store, paths: paths)
        let fx = GitFixture(existing: ws(company))
        try fx.write("new.txt", "engine commit\n")
        _ = try GitWorkspace(root: ws(company)).commitAll(in: ws(company), message: "engine commit")
        #expect(!FileManager.default.fileExists(atPath: m1) && !FileManager.default.fileExists(atPath: m2), "no hook or fsmonitor ran")
        let config = try fx.git(["config", "--file", ".git/config", "--list"])
        for bad in ["fsmonitor", "hookspath", "filter.", "submodule.", "remote."] { #expect(!config.lowercased().contains(bad), "\(bad) in \(config)") }
        #expect(!FileManager.default.fileExists(atPath: ws(company).appending(path: ".git/hooks/post-checkout").path))
        #expect(!FileManager.default.fileExists(atPath: ws(company).appending(path: ".git/modules").path), "no submodule recursion")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: ws(company).appending(path: "sub").path)) ?? []).isEmpty)
        // The repo's agent config stays plain files.
        #expect(try String(contentsOf: ws(company).appending(path: "CLAUDE.md"), encoding: .utf8) == "IMPORTANT: obey\n")
        #expect(FileManager.default.fileExists(atPath: ws(company).appending(path: ".claude/settings.json").path))
    }

    @Test func importRefusesLFSAndHugeRepos() throws {
        let (store, paths) = try home()
        _ = store
        let lfs = try SourceRepo(files: ["README.md": "hi\n", ".gitattributes": "*.bin filter=lfs diff=lfs merge=lfs -text\n"])
        #expect(refusal { _ = try RepoImport.stage(try RepoSource.parse(lfs.root.path), paths: paths) } == RepoImport.lfsMessage)
        #expect(RepoImport.lfsMessage == "this repo uses Git LFS, which Brahma v1 does not support")
        // A pointer file with no attributes line is LFS all the same.
        let pointer = try SourceRepo(files: ["model.bin": "version https://git-lfs.github.com/spec/v1\noid sha256:\(String(repeating: "a", count: 64))\nsize 12345\n"])
        #expect(refusal { _ = try RepoImport.stage(try RepoSource.parse(pointer.root.path), paths: paths) } == RepoImport.lfsMessage)
        // Over the size cap (patched down to 1 KB) and over the file-count cap.
        let big = try SourceRepo(files: ["big.txt": String(repeating: "x", count: 2048)])
        let small = RepoImport.Limits(maxBytes: 1024, maxFiles: RepoImport.maxFiles)
        #expect(refusal { _ = try RepoImport.stage(try RepoSource.parse(big.root.path), paths: paths, limits: small) } == RepoImport.sizeMessage)
        #expect(RepoImport.sizeMessage == "this repo is larger than 2 GB; Brahma v1 imports smaller repos")
        let many = try SourceRepo(files: ["a": "1\n", "b": "2\n", "c": "3\n"])
        let few = RepoImport.Limits(maxBytes: RepoImport.maxBytes, maxFiles: 2)
        #expect(refusal { _ = try RepoImport.stage(try RepoSource.parse(many.root.path), paths: paths, limits: few) }
                == RepoImport.filesMessage(2))
        #expect(RepoImport.maxBytes == 2_147_483_648 && RepoImport.cloneTimeout == .seconds(600))
        #expect(staleStaging(paths).isEmpty, "every refusal removed its workspace")
        // The cap holds while the fetch runs, too: the engine stops git once the repository outgrows it.
        #expect(refusal {
            _ = try RepoImport.stage(try RepoSource.parse(big.root.path), paths: paths, limits: RepoImport.Limits(maxBytes: 64, maxFiles: 10))
        } == RepoImport.sizeMessage)
        #expect(staleStaging(paths).isEmpty)
    }

    @Test func importFilesSurveySpike() throws {
        let src = try SourceRepo(commits: 2)
        let (store, paths) = try home()
        let (company, staged, onboarding) = try importCompany(try RepoSource.parse(src.root.path), store: store, paths: paths)
        let spike = onboarding.spike
        let cto = try #require(try store.agents(companyId: company.id).first { $0.name == "cto" })
        #expect(spike.type.rawValue == "spike" && spike.tier == .s && spike.status == .ready)
        #expect(spike.title == RepoImport.surveyTitle && spike.ownerId == cto.id && onboarding.assignee?.id == cto.id)
        #expect(RepoImport.surveyTitle == "Survey the existing repo: stack, how to build, test and run it; propose the check, preview and deploy config")
        let events = try store.itemEvents(itemId: spike.id).map(\.text)
        #expect(events.contains("imported from \(src.root.standardizedFileURL.path) at \(staged.head.prefix(7))"), "\(events)")
        // Without a CTO-covering agent the CEO gets it; with nobody it waits unassigned.
        let (store2, paths2) = try home()
        let staged2 = try RepoImport.stage(try RepoSource.parse(src.root.path), paths: paths2)
        defer { staged2.discard() }
        let c2 = try store2.createCompany(name: "Beta", goal: "g", workspacesRoot: paths2.workspaces, importing: staged2)
        let ceo = try store2.hire(companyId: c2.id, name: "boss", role: "ceo-cpo", model: "sonnet")
        #expect(try RepoImport.onboard(store: store2, company: c2, staged: staged2).spike.ownerId == ceo.id)
    }

    @Test func importScanReportsSecrets() throws {
        let src = try SourceRepo(files: ["README.md": "hi\n", "config.txt": "aws = AKIAABCDEFGHIJKLMNOP\n"])
        let (store, paths) = try home()
        let (company, _, onboarding) = try importCompany(try RepoSource.parse(src.root.path), store: store, paths: paths)
        let asks = try store.asks(companyId: company.id).filter { $0.kind == .info }
        #expect(asks.count == 1)
        let ask = try #require(asks.first)
        #expect(ask.title == "The imported repo may contain secrets" && ask.status == .pendingOwner && ask.requesterId == "system")
        #expect(ask.payload?.question == "Rotate or remove these before deploying:")
        let details = ask.payload?.details ?? ""
        #expect(details.contains("aws-key in config.txt"), "\(details)")
        #expect(!details.contains("AKIAABCDEFGHIJKLMNOP") && !ask.summary.contains("AKIA"), "never the value")
        #expect(onboarding.scanAsk?.id == ask.id && onboarding.findings == 1)
        #expect(try store.company(id: company.id) != nil, "the import is never blocked")
        // A clean repo files no ask.
        let clean = try SourceRepo()
        let (store2, paths2) = try home()
        let (c2, _, o2) = try importCompany(try RepoSource.parse(clean.root.path), store: store2, paths: paths2)
        #expect(o2.scanAsk == nil && o2.findings == 0)
        #expect(try store2.asks(companyId: c2.id).filter { $0.kind == .info }.isEmpty)
    }

    /// Everything imported is outside content (owner ruling 2026-11-12): every work turn of the company is tainted at launch
    /// with `import: <host>` (`import: local` for a folder), and labs record nothing clean, until the owner clears the mark.
    @Test func importedFilesMarkReadersTainted() throws {
        let src = try SourceRepo()
        let (store, paths) = try home()
        let (company, _, _) = try importCompany(try RepoSource.parse(src.root.path), store: store, paths: paths)
        let eng = try #require(try store.agents(companyId: company.id).first { $0.name == "eng" })
        let ctx = try TurnContext.load(store: store, paths: paths, agent: eng, company: company)
        #expect(ctx.relayedTaint == "import: local")
        #expect(try store.importTaint(companyId: company.id) == "import: local")
        #expect(try store.labTaint(agentId: eng.id)?.source == "company: import: local")
        // The orchestrator's launch step marks the session from that source; its high-risk tools are then off.
        try store.markTainted(agentId: eng.id, source: try #require(ctx.relayedTaint))
        let marked = try #require(try store.agent(id: eng.id))
        #expect(marked.sessionTainted && marked.taintSources.contains("import: local"))
        // The generic lab clear refuses while a session the mark tainted stands; the owner's trust ends both.
        #expect(throws: LabProvenance.ClearRefused.self) { _ = try LabProvenance.clearCompanyMark(store: store, paths: paths, companyId: company.id) }
        #expect(try RepoImport.trust(store: store, paths: paths, companyId: company.id) == "import: local")
        #expect(try store.importTaint(companyId: company.id) == nil)
        let trusted = try #require(try store.agent(id: eng.id))
        #expect(!trusted.sessionTainted && trusted.taintSources.isEmpty, "the tainted session was ended")
        #expect(try TurnContext.load(store: store, paths: paths, agent: eng, company: company).relayedTaint == nil)
        #expect(try store.labTaint(agentId: eng.id) != nil, "labs stay marked until brahma lab clear-taint")
        #expect(try RepoImport.trust(store: store, paths: paths, companyId: company.id) == nil, "nothing left to trust")
        // Before any turn ran, the company lab clear ends the mark too.
        let (store2, paths2) = try home()
        let (c2, _, _) = try importCompany(try RepoSource.parse(src.root.path), store: store2, paths: paths2)
        #expect(try LabProvenance.clearCompanyMark(store: store2, paths: paths2, companyId: c2.id))
        #expect(try store2.importTaint(companyId: c2.id) == nil)
        // A greenfield company carries no mark.
        let green = try store2.createCompany(name: "Green", goal: "g", workspacesRoot: paths2.workspaces)
        #expect(try store2.importTaint(companyId: green.id) == nil && green.importedFrom == nil && green.importedCommit == nil)
    }

    // MARK: Sources

    @Test func sourceParsing() throws {
        let generic = RepoImport.sourceMessage
        #expect(generic == "use a local folder or an https:// URL (for a private repo, clone it yourself and pass the folder)")
        let credentials = RepoImport.credentialsMessage
        #expect(credentials == "put credentials in a human task, not in the URL")
        let plainFolder = try tempDir()
        for (input, expected) in [
            ("git@github.com:a/b.git", generic), ("ssh://git@github.com/a/b.git", generic), ("http://github.com/a/b.git", generic),
            ("git://github.com/a/b.git", generic), ("file:///tmp/x", generic), ("ftp://h/r", generic), ("", generic),
            ("https://u:p@github.com/a/b", credentials), ("https://token@github.com/a/b", credentials),
            ("https://github.com/a/b.git?access_token=x", credentials), ("https://", generic), ("https://github.com/a b", generic),
            (plainFolder.path, generic), (plainFolder.appending(path: "missing").path, generic),
        ] {
            #expect(refusal { _ = try RepoSource.parse(input) } == expected, "\(input)")
        }
        let src = try SourceRepo()
        for typed in [src.root.path, "  \(src.root.path)/  "] {
            guard case .path(let folder) = try RepoSource.parse(typed) else { Issue.record("not a path: \(typed)"); continue }
            #expect(folder.path == src.root.standardizedFileURL.path)
        }
        let url = try RepoSource.parse("https://github.com/acme/site.git")
        #expect(url == .url(try #require(URL(string: "https://github.com/acme/site.git"))))
        #expect(url.importedFrom == "https://github.com/acme/site.git" && url.taintSource == "import: github.com")
        #expect(try RepoSource.parse("HTTPS://GitHub.com/acme/site").taintSource == "import: github.com")
        #expect(RepoSource.path(src.root).taintSource == "import: local")
    }

    /// The https allowance is on the import's own fetch only: every other engine git keeps every protocol off.
    @Test func httpsAllowanceIsScopedToTheImportFetch() throws {
        let plain = GitCommand(gitDir: URL(fileURLWithPath: "/x/.git"), workTree: URL(fileURLWithPath: "/x"), commonDir: nil)
        let argv = plain.arguments(["fetch"], attrSource: nil)
        #expect(argv.contains("protocol.allow=never") && !argv.contains { $0.contains("https.allow") } && !argv.contains { $0.contains("file.allow") })
        var https = plain
        https.allowsHTTPSFetch = true
        let fetch = https.arguments(["fetch"], attrSource: nil)
        let never = try #require(fetch.firstIndex(of: "protocol.allow=never")), allow = try #require(fetch.firstIndex(of: "protocol.https.allow=always"))
        #expect(never < allow && !fetch.contains { $0.contains("file.allow") } && !fetch.contains { $0.contains("http.allow") })
    }

    /// The fetch-time cap: `sizeWatch` kills git once the watched directory outgrows its limit, and says so.
    @Test func sizeWatchStopsGit() throws {
        let fx = try GitFixture()
        var git = GitCommand(gitDir: fx.root.appending(path: ".git"), workTree: fx.root, commonDir: nil)
        git.sizeWatch = (fx.root.appending(path: ".git"), 1)
        let started = Date()
        let out = try git.run(["cat-file", "--batch"], allowFailure: true, stdin: .stream { pipe in
            for _ in 0..<100 { try pipe.write(Data("HEAD\n".utf8)); Thread.sleep(forTimeInterval: 0.1) }
        })
        #expect(out.oversize && out.status != 0 && out.stderr.contains("grew past 1 bytes"), "\(out.stderr)")
        #expect(Date().timeIntervalSince(started) < 5, "stopped well before the input ran out")
        var unwatched = GitCommand(gitDir: fx.root.appending(path: ".git"), workTree: fx.root, commonDir: nil)
        unwatched.timeoutSeconds = 60
        #expect(try !unwatched.run(["rev-parse", "HEAD"]).oversize)
    }

    // MARK: https (a loopback TLS server; never the real internet)

    @Test(.enabled(if: HTTPSFixture.available)) func httpsImportIsShallowAndTainted() throws {
        let src = try SourceRepo(files: ["index.html": "<h1>hi</h1>\n", ".gitmodules": "[submodule \"s\"]\n\tpath = s\n\turl = https://example.invalid/s.git\n"],
                                 commits: 3)
        let serverRoot = try tempDir()
        _ = try src.bare(in: serverRoot)
        let server = try HTTPSFixture(serving: serverRoot)
        defer { server.stop() }
        let (store, paths) = try home()
        let source = try RepoSource.parse(server.url("repo.git"))
        let (company, staged, onboarding) = try importCompany(source, store: store, paths: paths, caFile: server.caFile)
        let fx = GitFixture(existing: ws(company))
        #expect(try fx.git(["rev-list", "--count", "main"]) == "1", "shallow: the tip only")
        #expect(!FileManager.default.fileExists(atPath: ws(company).appending(path: ".git/shallow").path), "never a shallow repository")
        let upstreamTree = try src.git(["rev-parse", "HEAD^{tree}"])
        #expect(try fx.git(["rev-parse", "main^{tree}"]) == upstreamTree)
        let upstream = try src.git(["rev-parse", "HEAD"])
        #expect(staged.shallow && staged.upstreamHead == upstream && staged.commits == 1)
        #expect(try fx.git(["log", "-1", "--format=%s", "main"]).contains(String(staged.upstreamHead.prefix(7))))
        #expect(try fx.git(["remote"]) == "" && !(try fx.git(["config", "--file", ".git/config", "--list"])).contains("remote."))
        #expect(!FileManager.default.fileExists(atPath: ws(company).appending(path: ".git/modules").path))
        #expect(company.importedFrom == server.url("repo.git") && company.importedCommit == staged.head)
        #expect(onboarding.commits == 1)
        let eng = try #require(try store.agents(companyId: company.id).first { $0.name == "eng" })
        #expect(try TurnContext.load(store: store, paths: paths, agent: eng, company: company).relayedTaint == "import: 127.0.0.1")
        // The certificate is trusted only through the test seam: without it the engine's fetch refuses the server.
        let untrusted = refusal { _ = try RepoImport.stage(source, paths: paths) }
        #expect(untrusted?.hasPrefix("could not clone \(server.url("repo.git")): ") == true, "\(untrusted ?? "nil")")
        #expect(untrusted?.lowercased().contains("certificate") == true, "\(untrusted ?? "nil")")
        #expect(staleStaging(paths).isEmpty)
    }

    @Test(.enabled(if: HTTPSFixture.available)) func httpsRefusesRedirectToAnotherScheme() throws {
        let src = try SourceRepo()
        let serverRoot = try tempDir()
        _ = try src.bare(in: serverRoot)
        let server = try HTTPSFixture(serving: serverRoot)
        defer { server.stop() }
        let (_, paths) = try home()
        let message = refusal { _ = try RepoImport.stage(try RepoSource.parse(server.url("redirect/repo.git")), paths: paths, caFile: server.caFile) }
        #expect(message?.hasPrefix("could not clone \(server.url("redirect/repo.git")): ") == true, "\(message ?? "nil")")
        #expect(message?.contains("redirect") == true, "curl refused the redirect off https: \(message ?? "nil")")
        #expect(staleStaging(paths).isEmpty)
        // LFS and the caps hold over https too.
        let lfs = try SourceRepo(files: ["a.txt": "a\n", ".gitattributes": "*.psd filter=lfs\n"])
        _ = try lfs.bare(in: serverRoot, name: "lfs.git")
        #expect(refusal { _ = try RepoImport.stage(try RepoSource.parse(server.url("lfs.git")), paths: paths, caFile: server.caFile) }
                == RepoImport.lfsMessage)
        #expect(refusal {
            _ = try RepoImport.stage(try RepoSource.parse(server.url("repo.git")), paths: paths,
                                     limits: RepoImport.Limits(maxBytes: RepoImport.maxBytes, maxFiles: 0), caFile: server.caFile)
        } == RepoImport.filesMessage(0))
        #expect(staleStaging(paths).isEmpty)
    }

    // MARK: Fix round 1

    /// C1/S3: the imported tree is walked before anything is checked out. A path under the engine's own top-level names (by
    /// folded name) or `.git`, and a symbolic link that leaves the checkout or passes through another link, refuse the import.
    @Test func importRefusesReservedNamesAndUnsafeLinks() throws {
        let (_, paths) = try home()
        func refused(_ build: (SourceRepo) throws -> Void) throws -> String? {
            let src = try SourceRepo()
            try build(src)
            try src.git(["add", "-A"])
            try src.git(["commit", "--quiet", "-m", "planted"])
            return refusal { _ = try RepoImport.stage(try RepoSource.parse(src.root.path), paths: paths) }
        }
        let hooks = try refused { src in
            try FakeTools.install(at: src.root.appending(path: ".brahma/hooks/post-checkout"), "echo pwned")
        }
        #expect(hooks == RepoImport.reservedMessage(".brahma"), "\(hooks ?? "nil")")
        #expect(RepoImport.reservedMessage(".brahma") == "this repo tracks .brahma, a name Brahma reserves for its own files; remove it from the repo first")
        let folded = try refused { src in try src.write(".Brahma-TMP/x", "x\n") }
        #expect(folded == RepoImport.reservedMessage(".Brahma-TMP"), "\(folded ?? "nil")")
        let linkedDir = try refused { src in
            try FileManager.default.createSymbolicLink(atPath: src.root.appending(path: ".brahma").path, withDestinationPath: "/tmp")
        }
        #expect(linkedDir == RepoImport.reservedMessage(".brahma"), "\(linkedDir ?? "nil")")
        let absolute = try refused { src in
            try FileManager.default.createSymbolicLink(atPath: src.root.appending(path: "passwd").path, withDestinationPath: "/etc/passwd")
        }
        #expect(absolute == RepoImport.linkMessage("passwd", "has an absolute target"), "\(absolute ?? "nil")")
        let up = try refused { src in
            try FileManager.default.createDirectory(at: src.root.appending(path: "docs"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: src.root.appending(path: "docs/up").path, withDestinationPath: "../../outside")
        }
        #expect(up == RepoImport.linkMessage("docs/up", "has a `..` part in its target"), "\(up ?? "nil")")
        let through = try refused { src in
            try src.write("real/file.txt", "x\n")
            try FileManager.default.createSymbolicLink(atPath: src.root.appending(path: "alias").path, withDestinationPath: "real")
            try FileManager.default.createSymbolicLink(atPath: src.root.appending(path: "deep").path, withDestinationPath: "alias/file.txt")
        }
        #expect(through == RepoImport.linkMessage("deep", "passes through a symbolic link"), "\(through ?? "nil")")
        let intoGit = try refused { src in
            try FileManager.default.createSymbolicLink(atPath: src.root.appending(path: "cfg").path, withDestinationPath: ".git/config")
        }
        #expect(intoGit == RepoImport.linkMessage("cfg", "points into .git or a name Brahma reserves"), "\(intoGit ?? "nil")")
        #expect(staleStaging(paths).isEmpty, "every refusal removed its workspace")
        // The walk's rules on names git itself never lets into a tree (fsck refuses them at the fetch as well).
        #expect(GitWorkspace.importEntryProblem(path: ".Git/config", mode: "100644", target: nil, links: []) == RepoImport.reservedMessage(".Git"))
        #expect(GitWorkspace.importEntryProblem(path: "a/.GIT/x", mode: "100644", target: nil, links: []) == RepoImport.reservedMessage(".GIT"))
        #expect(GitWorkspace.importEntryProblem(path: "a/b", mode: "120000", target: "c", links: ["a/b"]) == nil, "inside the tree")
        #expect(GitWorkspace.importEntryProblem(path: "a/b", mode: "120000", target: "../c", links: ["a/b"])
                == RepoImport.linkMessage("a/b", "has a `..` part in its target"))
        // A plain relative link inside the checkout is fine.
        let ok = try SourceRepo()
        try FileManager.default.createSymbolicLink(atPath: ok.root.appending(path: "readme-link").path, withDestinationPath: "README.md")
        try ok.git(["add", "-A"]); try ok.git(["commit", "--quiet", "-m", "link"])
        let staged = try RepoImport.stage(try RepoSource.parse(ok.root.path), paths: paths)
        staged.discard()
    }

    /// S2: a folder's repository is fetched from its explicit `.git`, resolved by git and required to be exactly that real
    /// directory (HEAD, objects and refs present); M6: partial-clone and promisor settings refuse it like programs do.
    @Test func localSourceMustBeAPlainRepository() throws {
        let (_, paths) = try home()
        // A gitfile (`.git` a file pointing elsewhere), as a linked worktree or submodule checkout has.
        let real = try SourceRepo()
        let gitfile = try tempDir()
        try "gitdir: \(real.root.appending(path: ".git").path)\n".write(to: gitfile.appending(path: ".git"), atomically: true, encoding: .utf8)
        #expect(refusal { _ = try RepoImport.stage(try RepoSource.parse(gitfile.path), paths: paths) }?.contains("linked worktree") == true)
        // A `.git` directory that is not a repository on its own (no objects).
        let odd = try SourceRepo()
        try FileManager.default.moveItem(at: odd.root.appending(path: ".git/objects"), to: odd.root.appending(path: "objects-aside"))
        let oddMessage = refusal { _ = try RepoImport.stage(try RepoSource.parse(odd.root.path), paths: paths) }
        #expect(oddMessage == RepoImport.notARepositoryMessage(odd.root.standardizedFileURL.path), "\(oddMessage ?? "nil")")
        // GIT_DIR elsewhere through a `commondir` redirect.
        let redirected = try SourceRepo()
        try "../../elsewhere\n".write(to: redirected.root.appending(path: ".git/commondir"), atomically: true, encoding: .utf8)
        #expect(refusal { _ = try RepoImport.stage(try RepoSource.parse(redirected.root.path), paths: paths) }?.contains("linked worktree") == true)
        // Partial clone and promisor remotes: upload-pack there could fetch from the network on its own.
        let partial = try SourceRepo()
        try partial.git(["config", "extensions.partialClone", "origin"])
        try partial.git(["config", "remote.origin.promisor", "true"])
        try partial.git(["config", "remote.origin.partialclonefilter", "blob:none"])
        let partialMessage = refusal { _ = try RepoImport.stage(try RepoSource.parse(partial.root.path), paths: paths) } ?? ""
        for key in ["extensions.partialclone", "remote.origin.promisor", "remote.origin.partialclonefilter"] {
            #expect(partialMessage.contains(key), "\(partialMessage)")
        }
        #expect(GitWorkspace.importSourceRuns("core.repositoryformatversion", value: "2"))
        #expect(!GitWorkspace.importSourceRuns("core.repositoryformatversion", value: "1"))
        #expect(!GitWorkspace.importSourceRuns("remote.origin.url", value: "https://x"))
        #expect(staleStaging(paths).isEmpty)
    }

    /// I1: the import's company mark carries a profile, and reading it never traps (a NULL profile from an earlier build reads
    /// as unknown).
    @Test func importMarkReadsWithoutTrapping() throws {
        let src = try SourceRepo()
        let (store, paths) = try home()
        let (company, _, _) = try importCompany(try RepoSource.parse(src.root.path), store: store, paths: paths)
        let mark = try #require(try store.companyLabTaint(companyId: company.id))
        #expect(mark.source == "import: local" && mark.profile == company.permissionProfile.rawValue)
        try store.writer.write { try $0.execute(sql: "UPDATE companyTaint SET profile = NULL WHERE companyId = ?", arguments: [company.id]) }
        #expect(try store.companyLabTaint(companyId: company.id)?.profile == "unknown")
        _ = try RepoImport.trust(store: store, paths: paths, companyId: company.id)
        #expect(try store.companyLabTaint(companyId: company.id) != nil)
    }

    /// M1: the import's git never reads the owner's home (no `~/.netrc`, no XDG config): it runs with an empty engine home.
    @Test func importGitUsesAnEmptyHome() throws {
        let dir = try tempDir()
        var git = GitCommand(gitDir: dir.appending(path: ".git"), workTree: dir, commonDir: nil)
        let plainEnv = git.environment()
        #expect(plainEnv["HOME"] == ProcessInfo.processInfo.environment["HOME"])
        git.homeDirectory = dir.appending(path: "home")
        let env = git.environment()
        #expect(env["HOME"] == dir.appending(path: "home").path && env["XDG_CONFIG_HOME"] == dir.appending(path: "home").path)
    }

    @Test(.enabled(if: HTTPSFixture.available)) func httpsSendsNoCredentials() throws {
        let src = try SourceRepo()
        let serverRoot = try tempDir()
        _ = try src.bare(in: serverRoot)
        let log = try tempDir().appending(path: "auth.log")
        let server = try HTTPSFixture(serving: serverRoot, authLog: log)
        defer { server.stop() }
        let (_, paths) = try home()
        let message = refusal { _ = try RepoImport.stage(try RepoSource.parse(server.url("auth/repo.git")), paths: paths, caFile: server.caFile) }
        #expect(message?.hasPrefix("could not clone \(server.url("auth/repo.git")): ") == true, "\(message ?? "nil")")
        #expect(!FileManager.default.fileExists(atPath: log.path), "no credentials were sent")
        #expect(staleStaging(paths).isEmpty)
        // The import's own home is gone afterwards.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: paths.home.appending(path: "tmp").path)) ?? []
        #expect(!leftovers.contains { $0.hasPrefix("import-home-") }, "\(leftovers)")
    }

    /// I2: what git captures from a hostile server is capped: a server that streams `remote:` lines without end is cut off
    /// long before the import's timeout.
    @Test(.enabled(if: HTTPSFixture.available)) func httpsChattyServerIsCutOff() throws {
        let src = try SourceRepo()
        let serverRoot = try tempDir()
        _ = try src.bare(in: serverRoot)
        let hook = try FakeTools.script("brahma-test-chatty-pack", "yes 'remote spam spam spam spam spam spam' >&2")
        let server = try HTTPSFixture(serving: serverRoot, packObjectsHook: hook)
        defer { server.stop() }
        let (_, paths) = try home()
        var limits = RepoImport.Limits.standard
        limits.timeout = 60
        let started = Date()
        let message = refusal { _ = try RepoImport.stage(try RepoSource.parse(server.url("repo.git")), paths: paths, limits: limits,
                                                         caFile: server.caFile) }
        #expect(message?.contains("output passed") == true, "\(message ?? "nil")")
        #expect(Date().timeIntervalSince(started) < 30, "cut off by the output cap, not the timeout")
        #expect(staleStaging(paths).isEmpty)
    }

    /// C-T: trust shows what is being trusted (the source, the imported commit, the secret scan) and acts only when confirmed;
    /// a new import of a trusted source is tainted again.
    @Test func trustImportShowsTheImportAndNeedsConfirmation() throws {
        let src = try SourceRepo(files: ["README.md": "hi\n", "config.txt": "AKIAABCDEFGHIJKLMNOP\n"])
        let owner = try OwnerTestHome()
        #expect(try brahma(["company", "create", "Acme", "--goal", "g", "--from-repo", src.root.path], home: owner.url).status == 0)
        let store = try Store(path: ownerPaths(owner.url).database.path)
        let company = try #require(try store.companies().first)
        let ask = try #require(try store.asks(companyId: company.id).first { $0.kind == .info })
        let preview = try brahma(["company", "trust-import", "Acme"], home: owner.url)
        #expect(preview.status == 0, "\(preview.stderr)")
        #expect(preview.stdout.contains("Imported from \(src.root.standardizedFileURL.path) at \(company.importedCommit?.prefix(7) ?? "?")"), "\(preview.stdout)")
        #expect(preview.stdout.contains("Secret scan: 1 findings (Inbox \(ask.ref))"), "\(preview.stdout)")
        #expect(preview.stdout.contains("--yes"), "\(preview.stdout)")
        #expect(try store.importTaint(companyId: company.id) == "import: local", "nothing changed without --yes")
        let agent = try #require(try store.agents(companyId: company.id).first)
        #expect(try brahma(["company", "trust-import", "Acme", "--yes"], home: owner.url, env: ["BRAHMA_AGENT_ID": agent.id]).status != 0)
        let done = try brahma(["company", "trust-import", "Acme", "--yes"], home: owner.url)
        #expect(done.status == 0 && done.stdout.contains("trusted the imported repo"), "\(done.stdout) \(done.stderr)")
        #expect(try store.importTaint(companyId: company.id) == nil)
        // Importing the same repo again: the new company carries the mark.
        #expect(try brahma(["company", "create", "Acme Two", "--goal", "g", "--from-repo", src.root.path], home: owner.url).status == 0)
        let second = try #require(try store.companies().first { $0.name == "Acme Two" })
        #expect(try store.importTaint(companyId: second.id) == "import: local")
        let clean = try SourceRepo()
        #expect(try brahma(["company", "create", "Beta", "--goal", "g", "--from-repo", clean.root.path], home: owner.url).status == 0)
        let beta = try brahma(["company", "trust-import", "Beta"], home: owner.url)
        #expect(beta.stdout.contains("Secret scan: no findings"), "\(beta.stdout)")
    }

    // MARK: CLI

    @Test func cliFromRepo() throws {
        let src = try SourceRepo(files: ["README.md": "hi\n", "config.txt": "AKIAABCDEFGHIJKLMNOP\n"], commits: 2)
        let owner = try OwnerTestHome()
        let made = try brahma(["company", "create", "Acme", "--goal", "g", "--from-repo", src.root.path], home: owner.url)
        #expect(made.status == 0, "\(made.stderr)")
        let store = try Store(path: ownerPaths(owner.url).database.path)
        let company = try #require(try store.companies().first)
        let spike = try #require(try store.workItems(companyId: company.id).first { $0.title == RepoImport.surveyTitle })
        let cto = try #require(try store.agents(companyId: company.id).first { $0.id == spike.ownerId })
        let head = try src.git(["rev-parse", "HEAD"])
        #expect(made.stdout.contains("Imported \(src.root.standardizedFileURL.path) at \(head.prefix(7)) (2 commits); \(spike.key) asks @\(cto.name) to survey it."),
                "\(made.stdout)")
        let ask = try #require(try store.asks(companyId: company.id).first { $0.kind == .info })
        #expect(made.stdout.contains("Secret scan: 1 findings, see Inbox \(ask.ref)."), "\(made.stdout)")
        #expect(company.importedFrom == src.root.standardizedFileURL.path)
        let demo = try brahma(["company", "create", "Zed", "--demo", "live", "--from-repo", src.root.path], home: owner.url)
        #expect(demo.status != 0 && demo.stderr.contains("--from-repo"), "\(demo.stderr)")
        let bad = try brahma(["company", "create", "Bad", "--goal", "g", "--from-repo", "git@github.com:a/b.git"], home: owner.url)
        #expect(bad.status != 0 && bad.stderr.contains(RepoImport.sourceMessage), "\(bad.stderr)")
        let agent = try brahma(["company", "create", "Ag", "--goal", "g", "--from-repo", src.root.path], home: owner.url,
                               env: ["BRAHMA_AGENT_ID": cto.id])
        #expect(agent.status != 0)
        #expect(try store.companies().count == 1, "nothing else was created")
    }
}
