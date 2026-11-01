import Foundation

/// The safety tools: `request_access` (Task 9), `request_secret` and `use_secret` (Task 4-wire). Registered from
/// `CompanyTools` like the other groups; none of them can approve anything (only the owner, or a preset the owner turned on),
/// and none ever returns a secret value: a test key reaches an agent only through its next turn's environment.
extension CompanyTools {
    static func safetyToolSpecs() -> [ToolSpec] {
        [
            ToolSpec(name: "request_secret", description: """
                Ask the owner for a secret (an API key, a token) by name. The owner provides it in the app; it is never shown \
                to you. A test key (test: true) can be put in your environment for the item you work on (use_secret); any other \
                secret is engine-held and used by connectors on your behalf.
                """, inputSchema: schema([
                    "name": prop("string", "Secret name: A-Z, 0-9 and _, for example STRIPE_TEST_KEY"),
                    "reason": prop("string", "Why you need it"),
                    "test": prop("boolean", "Whether you need it in your environment (a test key); default false"),
                ], required: ["name", "reason"])),
            ToolSpec(name: "use_secret", description: """
                Take a test key into your environment for the work item you hold. It is there from your next turn (not this \
                one), for your turns on the item and the item's checks, while the item is In progress or In review and you hold \
                it; it goes when you release the item or it is done. Engine-held secrets cannot be taken: connectors use them for you.
                """, inputSchema: schema(["name": prop("string", "Secret name, as the owner stored it")], required: ["name"])),
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
            case "request_secret": return try requestSecret(args)
            case "use_secret": return try useSecret(args)
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

    /// `request_secret {name, reason, test?}`: a `request` ask for the owner (`Store.requestSecret`; the quota applies there).
    private func requestSecret(_ args: [String: JSONValue]) throws -> String {
        let name = try string(args, "name").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let reason = try string(args, "reason")
        var test = false
        if let v = args["test"], v != .null {
            guard let b = v.boolValue else { throw ToolError(message: "argument test must be true or false") }
            test = b
        }
        let result = try store.requestSecret(companyId: companyId, agentId: agentId, name: name, reason: reason, test: test)
        if result.deduped { return "Already requested as \(result.ask.ref)." }
        return "Requested \(result.ask.ref) (\(name)). The owner provides secrets in the app."
    }

    /// `use_secret {name}`: opens a use of a test key for the item the agent holds (`Store.openSecretUse`). The value is
    /// never in the reply; it reaches the agent's next turn through its environment.
    private func useSecret(_ args: [String: JSONValue]) throws -> String {
        let name = try string(args, "name").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let opened = try store.openSecretUse(companyId: companyId, agentId: agentId, name: name)
        return "\(name) will be in your environment from your next turn while you work on \(opened.key)"
    }
}
