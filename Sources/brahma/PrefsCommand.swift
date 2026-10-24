import ArgumentParser
import Foundation
import BrahmaCore

struct PrefsGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prefs", abstract: "Show or set notification preferences: quiet hours, digest time, sleep prevention.",
        subcommands: [Show.self, Set.self], defaultSubcommand: Show.self)

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "Show the preferences (read-only).")

        func run() throws {
            let (store, _) = try openStore()
            printPrefs(try store.ownerPrefs(), zone: store.ownerTimeZone())
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Change a preference (owner only).",
            subcommands: [Quiet.self, Digest.self, PreventSleep.self, Notifications.self, Push.self, PushDetailCommand.self])

        struct Quiet: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "quiet", abstract: "Quiet hours as HH:MM-HH:MM in your time zone (may cross midnight), or off.")
            @Argument(help: "22:00-08:00, or off.") var window: String

            func run() throws {
                try update { prefs in
                    if window.lowercased() == "off" {
                        prefs.quietEnabled = false
                        return
                    }
                    let parts = window.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
                    guard parts.count == 2, OwnerPrefs.parseTime(parts[0]) != nil, OwnerPrefs.parseTime(parts[1]) != nil else {
                        throw fail("quiet hours look like 22:00-08:00, or off")
                    }
                    prefs.quietEnabled = true
                    prefs.quietStart = parts[0]
                    prefs.quietEnd = parts[1]
                }
            }
        }

        struct Digest: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "digest", abstract: "When the daily digest is made, as HH:MM in your time zone.")
            @Argument(help: "08:00") var time: String

            func run() throws {
                try update { prefs in
                    guard OwnerPrefs.parseTime(time) != nil else { throw fail("the digest time looks like 08:00") }
                    prefs.digestTime = time
                }
            }
        }

        struct PreventSleep: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "prevent-sleep", abstract: "Keep the Mac awake while agents run.")
            @Argument(help: "on or off.") var value: OnOff

            func run() throws { try update { $0.preventSleep = value == .on } }
        }

        struct Notifications: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "notifications", abstract: "Whether the app posts desktop notifications.")
            @Argument(help: "on or off.") var value: OnOff

            func run() throws { try update { $0.notificationsEnabled = value == .on } }
        }

        enum PushChoice: String, ExpressibleByArgument { case ntfy, pushover, off }

        struct Push: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "push",
                abstract: "Phone alerts: 'push ntfy <topic> [--server <https url>]', 'push pushover' (app token, then user key, one per line on standard input) or 'push off'.")
            @Argument(help: "ntfy, pushover or off.") var provider: PushChoice
            @Argument(help: "The ntfy topic: a long random name, because anyone who knows it can read it.") var topic: String?
            @Option(help: "The ntfy server (https only). Default https://ntfy.sh.") var server: String?
            @Flag(help: "ntfy: read an access token from standard input (stored in the vault as owner:NTFY_TOKEN).") var tokenStdin = false

            func run() throws {
                try requireOwnerShell()
                let (store, _) = try openStore()
                do {
                    switch provider {
                    case .off:
                        try store.setPush(provider: nil)
                        for name in [OwnerCredential.ntfyToken, OwnerCredential.pushoverAppToken, OwnerCredential.pushoverUserKey] {
                            try cliSecretVault().delete(companyId: OwnerCredential.scope, name: name)
                        }
                    case .ntfy:
                        guard let topic else { throw fail("ntfy needs a topic: brahma prefs set push ntfy <topic>") }
                        // Validated before anything is stored.
                        _ = try NtfyChannel(server: server ?? OwnerPrefs.defaultPushServer, topic: topic, token: nil)
                        if tokenStdin {
                            try cliSecretVault().set(companyId: OwnerCredential.scope, name: OwnerCredential.ntfyToken,
                                                     value: try SecretInput.read(from: .standardInput))
                        }
                        try store.setPush(provider: .ntfy, topic: topic, server: server)
                    case .pushover:
                        let lines = try readPushoverCredentials()
                        let vault = try cliSecretVault()
                        try vault.set(companyId: OwnerCredential.scope, name: OwnerCredential.pushoverAppToken, value: lines.app)
                        try vault.set(companyId: OwnerCredential.scope, name: OwnerCredential.pushoverUserKey, value: lines.user)
                        try store.setPush(provider: .pushover)
                    }
                } catch let e as PushError {
                    throw fail(e.description)
                } catch let e as SecretError {
                    throw fail(e.message)
                } catch let e as SettingsError {
                    if case .invalid(let m) = e { throw fail(m) }
                    throw e
                }
                printPrefs(try store.ownerPrefs(), zone: store.ownerTimeZone())
            }
        }

        struct PushDetailCommand: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "push-detail", abstract: "What a phone alert says: counts (default, no text from agents) or titles (ask titles, 80 characters).")
            @Argument(help: "counts or titles.") var detail: PushDetail

            func run() throws {
                try requireOwnerShell()
                let (store, _) = try openStore()
                try store.setPushDetail(detail)
                printPrefs(try store.ownerPrefs(), zone: store.ownerTimeZone())
            }
        }
    }
}

extension PushDetail: ExpressibleByArgument {}

/// The Pushover app token and user key: two lines on standard input, or two prompts in a terminal.
private func readPushoverCredentials() throws -> (app: String, user: String) {
    func prompt(_ label: String) throws -> String {
        guard let line = getpass("\(label): "), let text = String(validatingCString: line), !text.isEmpty else { throw fail("\(label) is empty") }
        return text
    }
    if isatty(STDIN_FILENO) != 0 { return (try prompt("Pushover app token"), try prompt("Pushover user key")) }
    let data = try FileHandle.standardInput.readToEnd() ?? Data()
    let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard lines.count == 2 else { throw fail("expected two lines on standard input: the Pushover app token, then the user key") }
    return (lines[0], lines[1])
}

enum OnOff: String, ExpressibleByArgument { case on, off }

private func update(_ change: (inout OwnerPrefs) throws -> Void) throws {
    try requireOwnerShell()
    let (store, _) = try openStore()
    var prefs = try store.ownerPrefs()
    try change(&prefs)
    do { try store.updateOwnerPrefs(prefs) } catch { throw fail("\(error)") }
    printPrefs(try store.ownerPrefs(), zone: store.ownerTimeZone())
}

private func printPrefs(_ prefs: OwnerPrefs, zone: TimeZone) {
    print("notifications: \(prefs.notificationsEnabled ? "on" : "off")")
    print("quiet hours: \(prefs.quietEnabled ? "\(prefs.quietStart)-\(prefs.quietEnd)" : "off") (\(safe(zone.identifier)))")
    print("digest: \(prefs.digestTime)")
    print("prevent sleep: \(prefs.preventSleep ? "on" : "off")")
    switch prefs.pushProvider {
    case nil: print("phone alerts: off")
    case .ntfy?: print("phone alerts: ntfy \(safe(prefs.pushServer))/\(safe(prefs.pushTopic ?? "?")) (\(prefs.pushDetail.rawValue))")
    case .pushover?: print("phone alerts: pushover (\(prefs.pushDetail.rawValue))")
    }
}
