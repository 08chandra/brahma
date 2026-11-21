import Foundation
@testable import BrahmaCore

/// C2b fix round 4 (R4-4): a stand-in for the `brahma-pdf` helper, compiled from C once per test process, that tries what
/// the helper's sandbox must deny. The PDF reader runs its helper directly (no shell), so a script can't stand in for it any
/// more. The probe takes its orders from its input file (argv[1], the one file the reader hands it), one per line:
///
/// - `read <path>` / `write <path>`: open the path; success exits 1.
/// - `exec <path>`: `execv` the path in place; a return (denied) goes on.
/// - `spawn <path>`: `posix_spawn` the path; success exits 1.
/// - `fork`: `fork()`; success exits 1 (the child exits at once).
/// - `setsid`: `setsid()` or `setpgid(0, 0)` succeeding, or the probe not leading its own session, exits 1.
/// - `connect <port>`: a TCP connection to 127.0.0.1:<port>; success exits 1.
/// - `joinparent`: move into the parent's process group (outside the run's own); failure exits 1.
/// - `hog <MiB>`: allocate and touch that much memory, then sleep 60 s.
/// - `flood`: write to standard output forever.
/// - `spin`: loop forever.
/// After the last order it prints a valid, empty helper output and exits 0. So a probe the sandbox stops reads as a clean
/// PDF, and one it lets through is refused (exit 1, or no output).
enum HelperProbe {
    static let source = #"""
    #include <errno.h>
    #include <fcntl.h>
    #include <netinet/in.h>
    #include <arpa/inet.h>
    #include <spawn.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/socket.h>
    #include <unistd.h>
    extern char **environ;
    int main(int argc, char **argv) {
        if (argc < 2) return 2;
        FILE *f = fopen(argv[1], "r");
        if (!f) return 3;
        char line[4096];
        while (fgets(line, sizeof line, f)) {
            line[strcspn(line, "\n")] = 0;
            char *arg = strchr(line, ' ');
            if (arg) *arg++ = 0;
            if (!strcmp(line, "read")) { if (open(arg, O_RDONLY) >= 0) return 1; }
            else if (!strcmp(line, "write")) { if (open(arg, O_WRONLY | O_CREAT, 0600) >= 0) return 1; }
            else if (!strcmp(line, "exec")) { char *a[] = { arg, NULL }; execv(arg, a); }
            else if (!strcmp(line, "spawn")) { pid_t p; char *a[] = { arg, "-c", "exit 0", NULL }; if (posix_spawn(&p, arg, NULL, NULL, a, environ) == 0) return 1; }
            else if (!strcmp(line, "fork")) { pid_t p = fork(); if (p == 0) _exit(0); if (p > 0) return 1; }
            else if (!strcmp(line, "setsid")) {
                if (getsid(0) != getpid()) return 1;
                if (setsid() != -1) return 1;
                if (setpgid(0, 0) == 0 && getpgrp() != getpid()) return 1;
            }
            else if (!strcmp(line, "connect")) {
                int s = socket(AF_INET, SOCK_STREAM, 0);
                struct sockaddr_in a; memset(&a, 0, sizeof a); a.sin_family = AF_INET; a.sin_port = htons(atoi(arg));
                a.sin_addr.s_addr = inet_addr("127.0.0.1");
                if (s >= 0 && connect(s, (struct sockaddr *)&a, sizeof a) == 0) return 1;
            }
            else if (!strcmp(line, "joinparent")) { if (setpgid(0, getpgid(getppid())) != 0) return 1; }
            else if (!strcmp(line, "hog")) {
                size_t n = (size_t)atoi(arg) << 20; volatile char *p = malloc(n);
                for (size_t i = 0; p && i < n; i += 4096) p[i] = 1;
                sleep(60);
            }
            else if (!strcmp(line, "flood")) { char b[65536]; memset(b, 'x', sizeof b); for (;;) if (write(1, b, sizeof b) < 0) return 4; }
            else if (!strcmp(line, "spin")) { for (;;) {} }
        }
        static const unsigned char empty[] = "BRAHMA-PDF/1\nE\0\0\0\010\0\0\0\0\0\0\0\0";
        fwrite(empty, 1, sizeof empty - 1, stdout);
        return 0;
    }
    """#

    private static let lock = NSLock()
    nonisolated(unsafe) private static var built: URL??

    /// The probe binary (resolved), compiled once with the system C compiler; nil when there is none.
    static func binary() -> URL? {
        lock.withLock {
            if let built { return built }
            let result = compile()
            built = .some(result)
            return result
        }
    }

    private static func compile() -> URL? {
        do {
            let dir = Scratch.root.appending(path: "probe-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let source = dir.appending(path: "probe.c"), binary = dir.appending(path: "brahma-pdf-probe")
            try Data(Self.source.utf8).write(to: source)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
            p.arguments = ["-O", "-o", binary.path, source.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }
            return binary.resolvedForSandbox
        } catch {
            return nil
        }
    }
}
