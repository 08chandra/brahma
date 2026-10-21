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
            discussion: "--rotate replaces the key and needs the current key to be valid.")

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
            let store = PlatformOwnerKeyStore.make()
            if rotate && !OwnerKey.verify(paths: paths, store: store) {
                // Replacing a key needs proof of the current one. Without it, only the Mac app (user presence) can.
                throw fail("can't rotate the owner key without a valid current key; rotate it from the Brahma app")
            }
            if OwnerKey.exists(paths: paths) && !rotate {
                throw fail("an owner key already exists at \(OwnerKey.url(paths: paths).path); use --rotate to replace it")
            }
            do {
                try OwnerKey.create(paths: paths, store: store, rotate: rotate)
            } catch {
                throw fail("could not create the owner key: \(error)")
            }
            print("owner key created at \(OwnerKey.url(paths: paths).path)")
        }
    }
}
