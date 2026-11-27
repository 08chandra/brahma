import Foundation
import Testing
@testable import BrahmaCore

/// A plain-HTTP git server on 127.0.0.1 (git's own `http-backend` as CGI behind python3's `http.server`) serving bare
/// repositories under `root` at `/<owner>/<repo>.git`. Every request must carry Basic credentials `x-access-token:<token>`
/// (else 401 with a Basic challenge), so a push succeeds only if the engine's credential helper delivered the token. It counts
/// requests with and without the right credential (`counts`) and never writes a header value anywhere. Never the internet.
final class LoopbackGitServer {
    static var available: Bool {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .contains { FileManager.default.isExecutableFile(atPath: "\($0)/python3") }
    }

    /// Arguments: root, port file, count file; the expected token arrives on stdin (never in argv or the environment).
    static let server = #"""
        exec python3 -I - "$@" 3<&0 <<'PY'
        import http.server, subprocess, sys, os, base64, threading
        root, portfile, countfile = sys.argv[1:4]
        token = os.fdopen(3).readline().rstrip("\n")
        expected = "Basic " + base64.b64encode(("x-access-token:" + token).encode()).decode()
        lock = threading.Lock()
        counts = {"authorized": 0, "unauthorized": 0}
        def bump(k):
            with lock:
                counts[k] += 1
                open(countfile + ".tmp", "w").write("%d %d" % (counts["authorized"], counts["unauthorized"]))
                os.rename(countfile + ".tmp", countfile)
        class H(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.0"
            def log_message(self, *a): pass
            def do_GET(self): self.cgi()
            def do_POST(self): self.cgi()
            def cgi(self):
                path, _, query = self.path.partition("?")
                if self.headers.get("Authorization") != expected:
                    bump("unauthorized")
                    self.send_response(401); self.send_header("WWW-Authenticate", 'Basic realm="t"'); self.end_headers(); return
                bump("authorized")
                n = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(n) if n else b""
                env = {"PATH": os.environ.get("PATH", ""), "GIT_PROJECT_ROOT": root, "GIT_HTTP_EXPORT_ALL": "1", "PATH_INFO": path,
                       "QUERY_STRING": query, "REQUEST_METHOD": self.command, "CONTENT_TYPE": self.headers.get("Content-Type", ""),
                       "CONTENT_LENGTH": str(len(body)), "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                       "REMOTE_USER": "x-access-token"}
                if self.headers.get("Content-Encoding"): env["HTTP_CONTENT_ENCODING"] = self.headers["Content-Encoding"]
                if self.headers.get("Git-Protocol"): env["GIT_PROTOCOL"] = self.headers["Git-Protocol"]
                p = subprocess.run(["git", "-c", "http.receivepack=true", "http-backend"], input=body, stdout=subprocess.PIPE, env=env)
                out = p.stdout
                i, sep = out.find(b"\r\n\r\n"), 4
                if i < 0: i, sep = out.find(b"\n\n"), 2
                head, rest = (out[:i], out[i + sep:]) if i >= 0 else (b"", out)
                status, headers = 200, []
                for line in head.decode("latin1").splitlines():
                    k, _, v = line.partition(":"); v = v.strip()
                    if k.lower() == "status": status = int(v.split()[0])
                    elif k: headers.append((k, v))
                self.send_response(status)
                for k, v in headers: self.send_header(k, v)
                self.end_headers(); self.wfile.write(rest)
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        srv.daemon_threads = True
        open(portfile + ".tmp", "w").write(str(srv.server_address[1])); os.rename(portfile + ".tmp", portfile)
        srv.serve_forever()
        PY
        """#

    let root: URL
    let port: Int
    private let process: Process
    private let countFile: URL

    /// `token` is handed to the server on its stdin.
    init(token: String) throws {
        let dir = try tempDir()
        root = dir.appending(path: "srv", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let portFile = dir.appending(path: "port")
        countFile = dir.appending(path: "counts")
        process = Process()
        process.executableURL = try FakeTools.script("brahma-test-git-http", Self.server)
        process.arguments = [root.path, portFile.path, countFile.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data((token + "\n").utf8))
        try input.fileHandleForWriting.close()
        var found: Int?
        for _ in 0..<200 {
            if let data = FileManager.default.contents(atPath: portFile.path), let n = Int(String(decoding: data, as: UTF8.self)) { found = n; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let found else { process.terminate(); process.waitUntilExit(); throw FakeError(description: "the loopback git server did not start") }
        port = found
    }

    /// `http://127.0.0.1:<port>`: what `GitPush.loopbackRemote` points `https://github.com` at.
    var base: String { "http://127.0.0.1:\(port)" }

    /// A bare repository at `/<owner>/<name>.git`.
    @discardableResult
    func bare(_ repo: GitHubRepoRef) throws -> URL {
        let dir = root.appending(path: "\(repo.owner)/\(repo.name).git", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // No template: git's sample hooks are executables the scratch check would flag.
        try GitFixture.plainGit(["init", "-q", "--bare", "--template=", "--initial-branch=main"], in: dir)
        return dir
    }

    /// Requests that carried the right credential, and ones that did not.
    var counts: (authorized: Int, unauthorized: Int) {
        guard let data = FileManager.default.contents(atPath: countFile.path) else { return (0, 0) }
        let parts = String(decoding: data, as: UTF8.self).split(separator: " ").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : (0, 0)
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }
}
