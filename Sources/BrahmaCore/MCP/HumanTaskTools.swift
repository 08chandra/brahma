import Foundation

/// The human-task tool (Plan L, Task 9: `request_human_task`). It is in `TaintPolicy.taintSafeTools`, so 5-lite's gate lets it
/// through and the handler applies its own tainted-session rule (chief review L4): a tainted session may only file a template
/// that carries no links of its own. Every handler resolves the company from the acting agent only.
extension CompanyTools {
    static func humanTaskToolSpecs() -> [ToolSpec] {
        let strings: JSONValue = .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                          "description": .string("Custom task only: what to do, one short step each (at most 12 of 300 characters)")])
        let links: JSONValue = .object([
            "type": .string("array"),
            "description": .string("Custom task only: https links the owner opens (at most 6); the owner sees each link's host"),
            "items": .object(["type": .string("object"), "properties": .object([
                "title": prop("string", "What the link opens"), "url": prop("string", "https:// address"),
            ]), "required": .array([.string("title"), .string("url")])]),
        ])
        let fields: JSONValue = .object([
            "type": .string("array"),
            "description": .string("Custom task only: URLs the owner pastes back (at most 6). Values are shown to agents, so never ask for a key or password here; use a template"),
            "items": .object(["type": .string("object"), "properties": .object([
                "name": prop("string", "lower_snake field name"), "label": prop("string", "What to paste"),
                "required": prop("boolean", "Whether the owner must fill it (default false)"),
            ]), "required": .array([.string("name"), .string("label")])]),
        ])
        return [
            ToolSpec(name: "request_human_task", description: """
                Ask the owner to do something only a person can, such as creating an account, buying a domain or posting the \
                launch announcement. Prefer a template: hosting-account (provider account and token), domain (args.domain \
                optional), stripe-test-keys, launch-post (args.text, args.url optional). Templates carry the exact links, steps \
                and fields; keys the owner pastes go to the vault and you never see them. A custom task (title, steps, https \
                links, url fields only) is for anything else a person must click. Name the item it blocks with item; you get \
                a notice when it is done.
                """, inputSchema: schema([
                    "template": prop("string", "hosting-account, domain, stripe-test-keys or launch-post"),
                    "args": .object(["type": .string("object"), "description": .string("Template arguments (strings)")]),
                    "title": prop("string", "Custom task only: what the owner should do"),
                    "steps": strings, "links": links, "fields": fields,
                    "item": prop("string", "The work item this blocks, e.g. ACME-3 (it waits until the task is done)"),
                    "reason": prop("string", "Why it is needed, for the owner"),
                ], required: ["reason"])),
        ]
    }

    /// Runs a human-task tool, or returns nil when `name` is not one.
    func dispatchHumanTask(_ name: String, _ args: [String: JSONValue]) throws -> String? {
        do {
            switch name {
            case "request_human_task": return try requestHumanTask(args)
            default: return nil
            }
        } catch let e as WorkError {
            throw ToolError(message: e.message)
        }
    }

    private func requestHumanTask(_ args: [String: JSONValue]) throws -> String {
        let templateName = try optionalString(args, "template")
        let template = try templateName.map { raw -> HumanTaskTemplate in
            guard let t = HumanTaskTemplate(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) else {
                throw ToolError(message: "unknown template \(Store.flat(raw, max: 40)); use hosting-account, domain, stripe-test-keys or launch-post")
            }
            return t
        }
        let templateArgs = try stringMap(args, "args")
        // 0. The tainted-session rule (chief review L4): a template only, with nothing of the agent's that the owner would open.
        //    launch-post is refused whole: every link it builds carries the agent's post text.
        if try sessionIsTainted() {
            let carries = ["links", "steps", "fields", "title"].contains { args[$0] != nil && args[$0] != .null }
            if template == nil || carries || templateArgs["url"] != nil || template == .launchPost {
                do { try store.requestFreshSession(agentId: agentId) } catch {
                    diagnostics("brahma mcp: could not request a fresh session for \(agentId): \(error)")
                }
                throw ToolError(message: HumanTaskPolicy.taintedRefusal)
            }
        }
        let reason = try string(args, "reason")
        // 1. The item is looked up in the acting agent's company only (another company's key is not found).
        let item = try optionalString(args, "item").map { try self.item(key: $0) }
        let steps: [String] = (args["steps"] == nil || args["steps"] == .null) ? [] : try stringArray(args, "steps")
        let links = try objects(args, "links").map { o -> HumanTaskLink in
            guard let title = o["title"]?.stringValue, let url = o["url"]?.stringValue else {
                throw ToolError(message: "each link needs a title and a url (strings)")
            }
            return HumanTaskLink(title: title, url: url)
        }
        let fields = try objects(args, "fields").map { o -> HumanTaskField in
            guard let name = o["name"]?.stringValue, let label = o["label"]?.stringValue else {
                throw ToolError(message: "each field needs a name and a label (strings)")
            }
            var required = false
            if let r = o["required"], r != .null {
                guard let b = r.boolValue else { throw ToolError(message: "a field's required must be a boolean") }
                required = b
            }
            // Always a url field: an agent's task never asks for a key, a password or free text (builder-check 11).
            return HumanTaskField(name: name, label: label, kind: .url, required: required)
        }
        // 2–6. Quota, dedupe, the ask and the item's block, in one write (`Store.requestHumanTask`).
        let (ask, deduped) = try store.requestHumanTask(companyId: companyId, by: agentId, template: template, args: templateArgs,
                                                        title: try optionalString(args, "title"), steps: steps, links: links,
                                                        fields: fields, itemId: item?.id, reason: reason)
        return deduped ? Store.alreadyRequestedText(ask) : Store.requestedHumanTaskText(ask)
    }

    /// The agent's session is tainted: its row, or the fail-closed flag file. An unreadable row counts as tainted.
    private func sessionIsTainted() throws -> Bool {
        guard let me = try store.agent(id: agentId) else { return true }
        return me.sessionTainted || (taintFlag.map(TaintFlag.exists) ?? false)
    }

    /// An optional object of string values.
    private func stringMap(_ args: [String: JSONValue], _ key: String) throws -> [String: String] {
        guard let v = args[key], v != .null else { return [:] }
        guard case .object(let o) = v else { throw ToolError(message: "argument \(key) must be an object of strings") }
        return try o.mapValues {
            guard let s = $0.stringValue else { throw ToolError(message: "argument \(key) must be an object of strings") }
            return s
        }
    }

    /// An optional array of objects.
    private func objects(_ args: [String: JSONValue], _ key: String) throws -> [[String: JSONValue]] {
        guard let v = args[key], v != .null else { return [] }
        guard let a = v.arrayValue else { throw ToolError(message: "argument \(key) must be an array of objects") }
        return try a.map {
            guard case .object(let o) = $0 else { throw ToolError(message: "argument \(key) must be an array of objects") }
            return o
        }
    }
}
