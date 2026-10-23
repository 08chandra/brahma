import Foundation

/// A team's notes file (`<workspace>/.brahma/notes/<team|company>.md`): retro lessons appended as `## ` sections. It never
/// grows past `cap` bytes: the oldest sections go first, and the first line then says how many were trimmed and when.
public enum NotesFile {
    public static let cap = 8192
    static let trimmedPrefix = "_Earlier notes trimmed: "

    /// What is read of an existing notes file (a file grown past this by hand is read up to here).
    static let readLimit = 64 * 1024
    static let directory = ".brahma/notes"

    /// The notes file of a team, or of the whole company for `nil`.
    public static func path(workspace: URL, team: String?) -> URL {
        workspace.appending(path: "\(directory)/\(fileName(team: team))")
    }

    static func fileName(team: String?) -> String {
        let name = (team ?? "company").lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return "\(name.isEmpty ? "company" : name).md"
    }

    /// Appends `## <heading>` and `lines` to the team's notes file, then trims to `cap`. `date` and `timeZone` date the trim
    /// line (the owner's zone). Written through `EngineFiles`: a link or odd file in its place is never read or followed but
    /// replaced by a fresh notes file, and returned so the caller can alert; a notes directory that is a link throws.
    @discardableResult
    public static func append(workspace: URL, team: String?, heading: String, lines: [String], date: Date = Date(),
                              timeZone: TimeZone = .current) throws -> UnsafeEngineFile? {
        let name = fileName(team: team)
        var found: UnsafeEngineFile?
        var existing = ""
        do {
            if let data = try EngineFiles.read(workspace: workspace, dir: directory, name: name, limit: readLimit) {
                existing = String(decoding: data, as: UTF8.self)
            }
        } catch let problem as UnsafeEngineFile where problem.path.hasSuffix("/" + name) {
            found = problem
        }
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
        let replaced = try EngineFiles.replace(Data(text.utf8), workspace: workspace, dir: directory, name: name)
        return found ?? replaced
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
