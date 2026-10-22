import ArgumentParser
import Foundation
import BrahmaCore
import BrahmaKeychain

struct OwnerGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "owner", abstract: "Owner key management.", subcommands: [Init.self])

    struct Init: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "init",
            abstract: "Create the owner key that owner commands require (interactive terminal only).",
            discussion: "Whenever a key hash is stored, init (and --rotate) need the current key file to be valid.")

        @Flag(help: "Replace an existing owner key.") var rotate = false

        func run() throws {
            if ProcessInfo.processInfo.environment["BRAHMA_AGENT_ID"] != nil {
                throw fail("owner commands can't run inside an agent turn")
            }
            guard isatty(0) == 1, isatty(1) == 1 else {
                FileHandle.standardError.write(Data("brahma owner init must be run in an interactive terminal\n".utf8))
                throw ExitCode.failure
            }
            let paths = BrahmaPaths.fromEnvironment()
            let store = try ownerKeyStore(for: paths)
            do {
                try OwnerKey.initForCLI(paths: paths, store: store, rotate: rotate)
            } catch OwnerKeyError.proofRequired {
                // Re-keying needs proof of the current key, even if owner.key was deleted. Without it, only the
                // Mac app (user presence) can replace the key.
                throw fail("can't create or rotate the owner key without a valid current key; replace it from the Brahma app")
            } catch OwnerKeyError.alreadyExists {
                throw fail("an owner key already exists at \(OwnerKey.url(paths: paths).path); use --rotate to replace it")
            } catch {
                throw fail("could not create the owner key: \(error)")
            }
            print("owner key created at \(OwnerKey.url(paths: paths).path)")
        }
    }
}
