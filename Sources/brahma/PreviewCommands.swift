import ArgumentParser
import Foundation
import BrahmaCore

/// The company's previews (Plan L). `list` is read-only; `set`, `remove` and `restart` are owner-write commands.
struct PreviewGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preview", abstract: "A company's previews: list them, set, remove or restart one.",
        subcommands: [List.self, Set.self, Remove.self, Restart.self], defaultSubcommand: List.self)

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List a company's previews: name, kind, status, url or message, commit.")
        @Argument(help: "Company name or slug.") var company: String

        func run() throws {
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let surfaces = try store.previewSurfaces(companyId: c.id)
            guard !surfaces.isEmpty else { print("(no previews)"); return }
            let states = try store.previewStates(companyId: c.id)
            for s in surfaces {
                let state = states[s.id]
                var parts = [s.name, s.kind, (state?.status ?? .idle).rawValue]
                if let message = state?.message, !message.isEmpty {
                    parts.append(message)
                } else if let url = state?.resolvedURL ?? s.url {
                    parts.append(url)
                }
                if let commit = state?.commit, !commit.isEmpty { parts.append("@" + String(commit.prefix(7))) }
                print(safe(parts.joined(separator: "  ")))
            }
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set (create or replace) a preview the engine builds from main: web, backend, cli, ios or macos (owner only).")
        @Argument(help: "Company name or slug.") var company: String
        @Argument(help: "Preview name: lowercase letters, digits and dashes (max 24).") var name: String
        @Option(help: "web (default), backend, cli, ios or macos.") var kind: String = PreviewKind.web.rawValue
        @Option(name: .customLong("run"), help: "web/backend: shell command that starts the server; write {port} where the engine's port goes.") var runCommand: String?
        @Option(help: "web/backend: where it answers, e.g. http://127.0.0.1:{port}/.") var url: String?
        @Option(help: "Shell command run first, e.g. \"npm ci && npm run build\" (required for ios and macos).") var build: String?
        @Option(help: "A smoke request, e.g. \"GET / 200\" (repeatable, up to 10).") var smoke: [String] = []
        @Option(help: "cli: the shell command whose output is the preview.") var demo: String?
        @Option(help: "backend: its OpenAPI file, relative to the repo root.") var openapi: String?
        @Option(name: .customLong("app-path"), help: "ios/macos: the built .app, relative to the repo root.") var appPath: String?
        @Option(name: .customLong("bundle-id"), help: "ios: the app's bundle id.") var bundleId: String?
        @Option(help: "ios: the Simulator device type, e.g. \"iPhone 15 Pro\".") var device: String?

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let draft = PreviewDraft(name: name, kind: kind.trimmingCharacters(in: .whitespaces).lowercased(), run: runCommand, url: url,
                                     build: build, smoke: smoke, demo: demo, openapiPath: openapi, appPath: appPath, bundleId: bundleId,
                                     device: device)
            let surface: PreviewSurface
            do { surface = try store.upsertPreviewSurface(companyId: c.id, by: .owner, draft) } catch let e as WorkError { throw fail(e.message) }
            print(safe("Preview \(surface.name) (\(surface.kind)) set; the engine builds it from main."))
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a preview; the engine stops it (owner only).")
        @Argument(help: "Company name or slug.") var company: String
        @Argument(help: "Preview name.") var name: String

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            do { _ = try store.removePreviewSurface(companyId: c.id, name: name, by: .owner) } catch let e as WorkError { throw fail(e.message) }
            print(safe("Preview \(name) removed."))
        }
    }

    struct Restart: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Ask the engine to rebuild and restart a preview from main (owner only).")
        @Argument(help: "Company name or slug.") var company: String
        @Argument(help: "Preview name.") var name: String

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            guard let surface = try store.previewSurfaces(companyId: c.id).first(where: { $0.name == name }) else {
                throw fail("no preview named \(name)")
            }
            do { try store.requestPreviewRestart(surfaceId: surface.id, by: .owner) } catch let e as WorkError { throw fail(e.message) }
            print(safe("Preview \(surface.name) will restart."))
        }
    }
}
