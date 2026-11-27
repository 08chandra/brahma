import Foundation

/// The security-relevant settings on `Company`, each with an order from strictest to loosest (coordinator ruling S35). A
/// restore keeps, for each one, the stricter of the live and the restored value, and says so; every other stored property of
/// `Company` is listed in `notSecurityRelevant` with the reason. `CompanySecurityTests` fails when a property is in neither
/// list, so a new field must be classified before it ships.
public enum CompanySecurity {
    struct Field {
        let name: String
        /// Puts the stricter of `live` and `restored` into `merged`; returns a line (without the company's name) when that
        /// changed what the snapshot had.
        let keepStricter: (_ merged: inout Company, _ live: Company, _ restored: Company) -> String?
    }

    /// A scalar with a total order: lower rank is stricter.
    private static func ordered<T>(_ name: String, _ path: WritableKeyPath<Company, T>, _ label: String,
                                   rank: @escaping (T) -> Int, show: @escaping (T) -> String) -> Field {
        Field(name: name) { merged, live, restored in
            let l = live[keyPath: path], r = restored[keyPath: path]
            guard rank(l) < rank(r) else { return nil }
            merged[keyPath: path] = l
            return "\(label) kept at \(show(l)) (the snapshot had \(show(r)))"
        }
    }

    /// An allow-list: fewer entries is stricter, so the restore keeps only what both databases allow.
    private static func allowList(_ name: String, _ path: WritableKeyPath<Company, [String]>, _ label: String) -> Field {
        Field(name: name) { merged, live, restored in
            let kept = Set(live[keyPath: path])
            let dropped = restored[keyPath: path].filter { !kept.contains($0) }
            guard !dropped.isEmpty else { return nil }
            merged[keyPath: path] = restored[keyPath: path].filter { kept.contains($0) }
            return "\(label) removed after the snapshot stay removed: \(dropped.sorted().joined(separator: ", "))"
        }
    }

    /// Computed (its closures hold key paths, which are not `Sendable`): built on each use, a handful of entries.
    static var fields: [Field] { [
        // Approvals: `everything` asks the owner most, `auto` least.
        ordered("autonomy", \.autonomy, "autonomy", rank: { [.everything: 0, .important: 1, .auto: 2][$0] ?? 2 }, show: \.rawValue),
        // Permissions.
        ordered("permissionProfile", \.permissionProfile, "profile", rank: \.breadth, show: \.rawValue),
        Field(name: "roleProfiles") { merged, live, restored in
            var lines: [String] = []
            for role in Set(live.roleProfiles.keys).union(restored.roleProfiles.keys).sorted() {
                let l = live.profile(forRole: role), r = restored.profile(forRole: role)
                let keep = PermissionProfile.narrower(l, r)
                merged.roleProfiles[role] = keep
                if keep.breadth < r.breadth { lines.append("role \(role) kept at \(keep.rawValue) (the snapshot had \(r.rawValue))") }
            }
            return lines.isEmpty ? nil : lines.joined(separator: "; ")
        },
        allowList("toolchainReadPaths", \.toolchainReadPaths, "toolchain read paths"),
        // Network.
        allowList("allowedDomains", \.allowedDomains, "network domains"),
        allowList("webDomains", \.webDomains, "web domains"),
        ordered("allowLocalBinding", \.allowLocalBinding, "local listening", rank: { $0 ? 1 : 0 }, show: { $0 ? "allowed" : "off" }),
        // Merging.
        ordered("autoMergeSmall", \.autoMergeSmall, "auto-merge", rank: { $0 ? 1 : 0 }, show: { $0 ? "on" : "off" }),
        // Landing (Plan X8): `local` keeps every commit on this machine; `pr` pushes to GitHub, and engine-merge lets the engine
        // merge there itself. A restore never re-enables either.
        ordered("landing", \.landing, "landing", rank: { $0 == .local ? 0 : 1 }, show: \.rawValue),
        ordered("engineMerge", \.engineMerge, "engine-merge", rank: { $0 ? 1 : 0 }, show: { $0 ? "on" : "off" }),
        // The owner's pause: nothing of a paused company runs.
        ordered("status", \.status, "status", rank: { $0 == .paused ? 0 : 1 }, show: \.rawValue),
    ] }

    /// Every other stored property of `Company`, and why a restore may take the snapshot's value.
    static let notSecurityRelevant: [String: String] = [
        "id": "identity", "name": "label", "slug": "label", "goal": "text the agents read, not a permission",
        "workspacePath": "where the company lives; not an owner switch",
        "usageMode": "spend pacing, not approvals, permissions, network or merging",
        "priorityWeight": "scheduling share", "createdAt": "history", "packId": "role catalog", "packVersion": "role catalog",
        "ownerReserve": "spend pacing", "ultraShare": "spend cap; each Ultra run still needs the owner's approval",
        "mainCommit": "re-adopted by the restore marker (S1), which raises the main alert on any other head",
        "pendingMainCommit": "as mainCommit", "autoMergeCount": "a counter", "cadence": "sprint completion rule",
        // Plan L (Task 5): the smoke check is agent-set (ops roles), runs sandboxed, and a deploy still needs the owner's approval
        // plus a passing run at the release commit; the red-main bug id is engine bookkeeping.
        "smokeCheck": "agent-set check command, not an owner switch; deploys still need the owner and a passing run",
        "smokeCheckSetById": "who set the smoke check", "redBugItemId": "engine bookkeeping for the red-main bug",
        // Plan L (Task 14): provenance, set once at creation; the import's taint mark lives in `companyTaint`, carried on its own.
        "importedFrom": "provenance of an imported workspace", "importedCommit": "provenance of an imported workspace",
        // Plan 4a (Task 1a): the main check is agent-set (ops roles) and runs sandboxed like the smoke check; the rest are
        // queue tuning and engine bookkeeping. Nothing here widens what an agent may do or what main may receive unreviewed.
        "mainCheck": "agent-set check command, not an owner switch; it runs sandboxed", "mainCheckSetById": "who set the main check",
        "mergeBatchSize": "queue throughput, not a permission", "mergeStrategy": "how approved work lands; every merge is still approved",
        "mergeHold": "engine bookkeeping: why the queue is held",
    ]

    /// The restored company with every security-relevant field at the stricter of the two, and what that changed.
    public static func stricter(live: Company, restored: Company) -> (Company, [String]) {
        var merged = restored
        let lines = fields.compactMap { $0.keepStricter(&merged, live, restored) }
        return (merged, lines)
    }
}
