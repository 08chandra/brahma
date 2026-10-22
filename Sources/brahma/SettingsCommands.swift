import ArgumentParser
import Foundation
import BrahmaCore

struct SettingsGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settings", abstract: "Owner-wide settings: time zone, plan tier and weekly share.",
        subcommands: [TimeZoneSetting.self, Plan.self, Share.self])

    struct TimeZoneSetting: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "timezone", abstract: "Show or set the time zone used for every clock time (an IANA id such as Asia/Kolkata).")
        @Argument(help: "IANA time zone id; omit to show the current one.") var id: String?

        func run() throws {
            if let id {
                try requireOwnerShell()
                let (store, _) = try openStore()
                do { try store.setOwnerTimeZone(id) } catch { throw fail("unknown time zone '\(id)'") }
                print("time zone: \(store.ownerTimeZone().identifier)")
            } else {
                let (store, _) = try openStore()
                print("time zone: \(store.ownerTimeZone().identifier)")
            }
        }
    }

    struct Plan: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "plan", abstract: "Show or set the Claude plan tier, which sets concurrency (max5x: 1/3/8, max20x: 2/6/16).")
        @Argument(help: "max5x (default) or max20x; omit to show the current one.") var tier: PlanTier?

        func run() throws {
            if let tier {
                try requireOwnerShell()
                let (store, _) = try openStore()
                try store.setPlanTier(tier)
            }
            let (store, _) = try openStore()
            let t = store.planTier()
            print("plan: \(t.rawValue) (low \(t.modeCap(.low)) / balanced \(t.modeCap(.balanced)) / max \(t.modeCap(.max)) concurrent turns, "
                  + "\(t.seatBudget) seats for a new company)")
        }
    }

    struct Share: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "share", abstract: "Show or set the percentage of the weekly allowance the companies may use (10-100; the rest is yours).")
        @Argument(help: "Percent, 10 to 100; omit to show the current one.") var percent: Int?

        func run() throws {
            if let percent {
                guard (10...100).contains(percent) else { throw fail("share must be between 10 and 100 percent") }
                try requireOwnerShell()
                let (store, _) = try openStore()
                try store.setWeeklyShare(Double(percent) / 100)
            }
            let (store, _) = try openStore()
            print("weekly share: \(Int((store.weeklyShare() * 100).rounded()))%")
        }
    }
}

extension PlanTier: ExpressibleByArgument {}
