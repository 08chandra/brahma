import Foundation

/// The review tool and the limits of a review turn's MCP server. A review turn is bound to one item: its credential, its
/// server (`--review-item <KEY>`) and these checks all name the same item.
extension CompanyTools {
    static func reviewSpec() -> ToolSpec {
        let s = Self.self
        let flags: JSONValue = .object(["type": .string("boolean"),
                                        "description": .string("Required to approve an item that has review flags")])
        return ToolSpec(
            name: "review",
            description: "Give your decision on the item you are reviewing: approve (the engine then merges the branch into main) or request_changes with concrete notes.",
            inputSchema: s.schema(["key": s.prop("string", "The item key of this review"),
                                   "decision": s.prop("string", "approve or request_changes"),
                                   "notes": s.prop("string", "Concrete findings; required for request_changes"),
                                   "approve_flags": flags], required: ["key", "decision", "notes"]))
    }

    /// Everything a review turn may call. The reviewer's role tools do not matter here: the turn has its own short list.
    func callInReviewTurn(name: String, arguments: [String: JSONValue]) throws -> String {
        guard let rid = reviewItemId, let target = try? store.workItem(id: rid), target.companyId == companyId else {
            throw ToolError(message: "no such work item")
        }
        guard CompanyToolNames.review.contains(name) else { throw ToolError(message: "\(name) is not available in a review turn") }
        if name != "create_work_item", let given = arguments["key"]?.stringValue,
           given.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != target.key {
            throw ToolError(message: "this review turn is limited to \(target.key)")
        }
        return try dispatch(name, arguments)
    }

    func reviewTool(_ args: [String: JSONValue]) throws -> String {
        guard let rid = reviewItemId else { throw ToolError(message: Store.reviewTurnOnlyMessage) }
        let target = try item(key: try string(args, "key"))
        guard target.id == rid else { throw ToolError(message: "this review turn is limited to \(target.key)") }
        guard let decision = ReviewDecision(rawValue: try string(args, "decision").trimmingCharacters(in: .whitespaces)) else {
            throw ToolError(message: "decision must be approve or request_changes")
        }
        var notes = ""
        if let v = args["notes"], v != .null {
            guard let text = v.stringValue else { throw ToolError(message: "argument notes must be a string") }
            notes = text
        }
        var approveFlags = false
        if let v = args["approve_flags"], v != .null {
            guard case .bool(let b) = v else { throw ToolError(message: "argument approve_flags must be true or false") }
            approveFlags = b
        }
        guard let company = try store.company(id: companyId) else { throw ToolError(message: "no such company") }
        let git = store.gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: companyId)
        // The head is read here from the branch, never taken from the agent.
        let head = try? git.head(of: git.branchRef(key: target.key))
        _ = try store.review(itemId: target.id, by: agentId, decision: decision, notes: notes, approveFlags: approveFlags,
                             currentHead: head ?? nil)
        return decision == .approve ? "Approved \(target.key); the engine will merge it into main." : "Requested changes on \(target.key)."
    }
}
