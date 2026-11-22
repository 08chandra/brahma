import ArgumentParser
import Foundation
import BrahmaCore

/// A company's published artifacts (Plan 4a Task 6). `list` (the default) is read-only; `publish` and `rm` are owner-write
/// commands (`requireOwnerShell`): an agent publishes through its `publish_artifact` tool, as itself. Titles and every other
/// agent-controlled field print through `safe()`.
struct ArtifactsGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "artifacts", abstract: "A company's published artifacts: list them, publish a workspace file or folder, delete one.",
        subcommands: [List.self, Publish.self, Remove.self], defaultSubcommand: List.self)

    /// `AR-<n>  <kind>  <title>  @<by>  <yyyy-MM-dd HH:mm>`.
    static func line(_ a: Artifact, names: [String: String]) -> String {
        let by = a.publishedById == "owner" ? "owner" : names[a.publishedById] ?? a.publishedById
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cliTimeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let title = a.title.split(whereSeparator: \.isNewline).joined(separator: " ")
        return safe([a.ref, a.kind.rawValue, title, "@\(by)", f.string(from: a.createdAt)].joined(separator: "  "))
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "The company's artifacts, newest first.")
        @Argument(help: "Company name or slug.") var company: String
        @Option(help: "How many to show (default 20).") var limit: Int = 20

        func run() throws {
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let names = Dictionary(try store.agents(companyId: c.id).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            for a in try store.artifacts(companyId: c.id, limit: max(1, min(limit, 500))) { print(ArtifactsGroup.line(a, names: names)) }
        }
    }

    struct Publish: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Publish a file or folder of the company workspace as an artifact (owner only).")
        @Argument(help: "Company name or slug.") var company: String
        @Argument(help: "The file or folder, inside the company workspace (relative paths start in the current directory).") var path: String
        @Option(help: "A short title (at most 120 characters).") var title: String
        @Option(help: "The work item it belongs to, e.g. ACME-12.") var item: String?

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let artifact: Artifact
            do {
                artifact = try store.publishArtifact(companyId: c.id, by: .owner, sourcePath: path, title: title, itemKey: item, baseDirectory: cwd)
            } catch let e as WorkError { throw fail(e.message) }
            print(safe(artifact.publishedLine))
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete an artifact and its copy (owner only).")
        @Argument(help: "Company name or slug.") var company: String
        @Argument(help: "The artifact, e.g. AR-3.") var artifact: String

        func run() throws {
            try requireOwnerShell()
            guard let number = Artifact.parseRef(artifact) else { throw fail(ArtifactMessages.refShape) }
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            guard let a = try store.artifact(companyId: c.id, number: number) else { throw fail("no artifact AR-\(number)") }
            do { try store.deleteArtifact(id: a.id, by: .owner) } catch let e as WorkError { throw fail(e.message) }
            print("Deleted \(a.ref).")
        }
    }
}
