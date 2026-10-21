import Foundation

/// Finds the helper binaries the embedded engine needs, and the login-shell PATH that a Finder launch lacks.
public enum ToolLocator {
    public static func mcpHelper(appBundle: URL, executable: URL,
                                 isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        let bundled = appBundle.appending(path: "Contents/Helpers/brahma").path
        if isExecutable(bundled) { return bundled }
        let sibling = executable.deletingLastPathComponent().appending(path: "brahma").path
        return isExecutable(sibling) ? sibling : nil
    }

    /// `BRAHMA_CLAUDE` wins, and a bad override does not fall back to the search path.
    public static func claude(environment: [String: String], searchPath: String,
                              isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        if let override = environment["BRAHMA_CLAUDE"], !override.isEmpty {
            return isExecutable(override) ? override : nil
        }
        for dir in searchPath.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = "\(dir)/claude"
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// Asks the user's login shell for its PATH. Output goes to a temp file, not a pipe: a grandchild (such as
    /// `sleep`) would keep a pipe open and block an EOF read past the timeout.
    public static func loginShellPath(shell: String, timeout: Duration = .seconds(3)) -> String? {
        let out = FileManager.default.temporaryDirectory.appending(path: "brahma-path-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: out.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: out) else { return nil }
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: out)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf '__BRAHMA_PATH__%s__END__' \"$PATH\""]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardOutput = handle
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        if done.wait(timeout: .now() + seconds) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            return nil
        }
        guard let data = try? Data(contentsOf: out) else { return nil }
        return parseMarkedPath(String(decoding: data, as: UTF8.self))
    }

    public static func parseMarkedPath(_ output: String) -> String? {
        guard let start = output.range(of: "__BRAHMA_PATH__"),
              let end = output.range(of: "__END__", range: start.upperBound..<output.endIndex) else { return nil }
        let path = String(output[start.upperBound..<end.lowerBound])
        return path.isEmpty ? nil : path
    }

    /// Login entries first, then the current ones, de-duplicated, empty entries dropped.
    public static func mergePath(login: String?, current: String) -> String {
        var seen = Set<String>()
        var merged: [String] = []
        for entry in ((login ?? "") + ":" + current).split(separator: ":", omittingEmptySubsequences: true) {
            if seen.insert(String(entry)).inserted { merged.append(String(entry)) }
        }
        return merged.joined(separator: ":")
    }
}
