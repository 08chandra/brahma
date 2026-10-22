import ArgumentParser
import Foundation
import BrahmaCore

struct SettingsGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settings", abstract: "Owner-wide settings: time zone, plan tier and weekly share.",
        subcommands: [TimeZoneSetting.self, Plan.self, Share.self, HotPaths.self, AutoMerge.self, AutoMergePaths.self])

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
            commandName: "plan", abstract: "Show or set the Claude plan tier, which sets concurrency (pro: 1/1/2, max5x: 1/3/8, max20x: 2/6/16).")
        @Argument(help: "max5x (default), max20x or pro; omit to show the current one.") var tier: PlanTier?

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

extension SettingsGroup {
    struct HotPaths: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "hot-paths",
            abstract: "Show or set the globs that serialize merges (lockfiles, manifests, migrations, routers): an item touching one waits for the others that do.")
        @Argument(help: "Globs to use instead, or 'default'; omit to show the current ones.") var globs: [String] = []

        func run() throws {
            if !globs.isEmpty {
                try requireOwnerShell()
                let (store, _) = try openStore()
                do { try store.setHotPaths(globs.count == 1 && globs[0] == "default" ? nil : globs) }
                catch let SettingsError.invalid(why) { throw fail("invalid hot paths: \(why)") }
            }
            let (store, _) = try openStore()
            for g in store.hotPaths() { print(safe(g)) }
        }
    }
}

extension PlanTier: ExpressibleByArgument {}

extension SettingsGroup {
    enum Switch: String, ExpressibleByArgument, CaseIterable { case on, off }

    struct AutoMerge: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "auto-merge",
            abstract: "Show or switch risk-tiered auto-merge: small, lead-configured tier S changes that pass their check land without a review turn and are audited after.")
        @Argument(help: "on or off; omit to show the current setting.") var value: Switch?

        func run() throws {
            if let value {
                try requireOwnerShell()
                let (store, _) = try openStore()
                try store.setAutoMerge(value == .on)
            }
            let (store, _) = try openStore()
            print("auto-merge: \(store.autoMergeEnabled() ? "on" : "off")")
        }
    }

    struct AutoMergePaths: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "auto-merge-paths",
            abstract: "Show or set the directories an auto-merged change may touch (every changed path must lie under one).")
        @Argument(help: "Directories to use instead, or 'default'; omit to show the current ones.") var paths: [String] = []

        func run() throws {
            if !paths.isEmpty {
                try requireOwnerShell()
                let (store, _) = try openStore()
                do { try store.setAutoMergePaths(paths.count == 1 && paths[0] == "default" ? nil : paths) }
                catch let SettingsError.invalid(why) { throw fail("invalid auto-merge paths: \(why)") }
            }
            let (store, _) = try openStore()
            let company = try store.companies().first
            for p in store.autoMergePaths(companyId: company?.id ?? "") { print(safe(p)) }
        }
    }
}
