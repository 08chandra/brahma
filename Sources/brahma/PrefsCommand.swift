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
            subcommands: [Quiet.self, Digest.self, PreventSleep.self, Notifications.self])

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
    }
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
}
