import Foundation

/// A team's notes file (`<workspace>/.brahma/notes/<team|company>.md`): retro lessons appended as `## ` sections. It never
/// grows past `cap` bytes: the oldest sections go first, and the first line then says how many were trimmed and when.
public enum NotesFile {
    public static let cap = 8192
    static let trimmedPrefix = "_Earlier notes trimmed: "

    /// The notes file of a team, or of the whole company for `nil`.
    public static func path(workspace: URL, team: String?) -> URL {
        let name = (team ?? "company").lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return workspace.appending(path: ".brahma/notes/\(name.isEmpty ? "company" : name).md")
    }

    /// Appends `## <heading>` and `lines`, then trims to `cap`. `date` and `timeZone` date the trim line (the owner's zone).
    public static func append(path: URL, heading: String, lines: [String], date: Date = Date(), timeZone: TimeZone = .current) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        var (trimmed, preamble, sections) = parse(existing)
        let clean = lines.map { Store.stripControls($0) }
        sections.append((["## " + Store.flat(heading, max: 200)] + clean).joined(separator: "\n") + "\n")

        func render(_ trimmedCount: Int) -> String {
            var out = ""
            if trimmedCount > 0 {
                out += "\(trimmedPrefix)\(trimmedCount) sections removed on \(day(date, timeZone))._\n"
            }
            out += preamble
            out += sections.joined()
            return out
        }
        var text = render(trimmed)
        // Oldest sections go first; the newest one always stays.
        while text.utf8.count > cap, sections.count > 1 {
            sections.removeFirst()
            trimmed += 1
            text = render(trimmed)
        }
        if text.utf8.count > cap {
            // A single section over the cap is cut at a line boundary.
            preamble = ""
            text = render(trimmed)
            let head = text.utf8.count - (sections.last?.utf8.count ?? 0)
            let budget = cap - head - "…\n".utf8.count
            var kept = ""
            for line in (sections.last ?? "").components(separatedBy: "\n") where !line.isEmpty {
                let next = kept + line + "\n"
                if next.utf8.count > budget { break }
                kept = next
            }
            sections[sections.count - 1] = kept + "…\n"
            text = render(trimmed)
        }
        try text.write(to: path, atomically: true, encoding: .utf8)
    }

    /// (sections trimmed so far, text before the first section, the sections each with their trailing newline).
    static func parse(_ text: String) -> (Int, String, [String]) {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var trimmed = 0
        if let first = lines.first, first.hasPrefix(trimmedPrefix) {
            let rest = first.dropFirst(trimmedPrefix.count)
            trimmed = Int(rest.prefix { $0.isNumber }) ?? 0
            lines.removeFirst()
        }
        var preamble = ""
        var sections: [String] = []
        for line in lines {
            if line.hasPrefix("## ") {
                sections.append(line + "\n")
            } else if sections.isEmpty {
                preamble += line + "\n"
            } else {
                sections[sections.count - 1] += line + "\n"
            }
        }
        return (trimmed, preamble, sections)
    }

    static func day(_ date: Date, _ zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
