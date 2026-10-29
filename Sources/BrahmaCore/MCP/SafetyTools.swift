import Foundation

/// The safety tools: `request_access` (Task 9). Task 4-wire adds `use_secret` and `request_secret` here. Registered from
/// `CompanyTools` like the other groups; none of them can approve anything (only the owner, or a preset the owner turned on).
extension CompanyTools {
    static func safetyToolSpecs() -> [ToolSpec] {
        [
            ToolSpec(name: "request_access", description: """
                Ask the owner for access your sandbox does not give you: a Bash egress domain (network_domain), a WebFetch \
                domain (web_domain) or a directory to read (read_path, absolute). The owner chooses the scope and duration; a \
                grant takes effect from your next turn, never this one. Requests for the same access are shared company-wide.
                """, inputSchema: schema([
                    "kind": prop("string", "network_domain, web_domain, read_path or extension"),
                    "value": prop("string", "A host name (or *.parent), or an absolute directory path"),
                    "reason": prop("string", "Why you need it"),
                    "item": prop("string", "Work item key this is for (needed for scope item)"),
                    "scope": prop("string", "Who it should cover: once, item, agent (default), role or company"),
                    "duration": prop("string", "How long: turn, sprint (default) or always"),
                ], required: ["kind", "value", "reason"])),
        ]
    }

    /// Runs a safety tool, or returns nil when `name` is not one.
    func dispatchSafety(_ name: String, _ args: [String: JSONValue]) throws -> String? {
        do {
            switch name {
            case "request_access": return try requestAccess(args)
            default: return nil
            }
        } catch let e as WorkError {
            throw ToolError(message: e.message)
        } catch let e as SandboxError {
            throw ToolError(message: e.description)
        }
    }

    // MARK: Tools

    private func requestAccess(_ args: [String: JSONValue]) throws -> String {
        let kindName = try string(args, "kind").trimmingCharacters(in: .whitespaces).lowercased()
        guard let kind = GrantKind(rawValue: kindName) else {
            throw ToolError(message: "kind must be one of: \(GrantKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let value = try string(args, "value"), reason = try string(args, "reason")
        let scope = try optionalString(args, "scope").map { s -> GrantScope in
            guard let v = GrantScope(rawValue: s.trimmingCharacters(in: .whitespaces).lowercased()) else {
                throw ToolError(message: "scope must be one of: \(GrantScope.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return v
        }
        let duration = try optionalString(args, "duration").map { s -> GrantDuration in
            guard let v = GrantDuration(rawValue: s.trimmingCharacters(in: .whitespaces).lowercased()) else {
                throw ToolError(message: "duration must be one of: \(GrantDuration.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return v
        }
        // Items are looked up inside this company only; the store checks every id again.
        var itemId: String?
        if let key = try optionalString(args, "item") {
            guard let item = try store.workItem(companyId: companyId, key: key.trimmingCharacters(in: .whitespaces).uppercased()) else {
                throw ToolError(message: "no work item \(Store.flat(key, max: 40).uppercased())")
            }
            itemId = item.id
        }
        let result = try store.requestAccess(companyId: companyId, agentId: agentId, kind: kind, value: value, reason: reason,
                                             itemId: itemId, scope: scope, duration: duration)
        if result.deduped { return "Already requested as \(result.ask.ref)." }
        let what = "\(result.ask.ref) (\(Store.flat(result.ask.title, max: 300)))"
        if let grant = result.grant {
            return "Requested \(what). Approved as \(grant.ref) under an access preset the owner turned on; it takes effect from your next turn."
        }
        return "Requested \(what). The owner will decide; you'll get a notice. Grants take effect from your next turn."
    }
}
