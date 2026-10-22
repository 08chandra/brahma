import Foundation

/// The audit tool of a batched audit turn (9c). The turn's credential is issued with kind `audit` and its server's mode comes
/// from that credential alone; the samples the tool may judge are the ones the engine bound to the turn.
extension CompanyTools {
    static func auditSpec() -> ToolSpec {
        let s = Self.self
        return ToolSpec(
            name: "audit",
            description: "Record your verdict on one auto-merged item of this audit: ok true if the merged change is correct, in scope and safe; ok false with concrete notes otherwise.",
            inputSchema: s.schema(["key": s.prop("string", "The item key, one of this audit's items"),
                                   "ok": s.prop("boolean", "true if the merged change is fine"),
                                   "notes": s.prop("string", "Concrete findings; required when ok is false")],
                                  required: ["key", "ok", "notes"]))
    }

    /// Everything an audit turn may call: `audit` only.
    func callInAuditTurn(name: String, arguments: [String: JSONValue]) throws -> String {
        guard CompanyToolNames.audit.contains(name) else { throw ToolError(message: "\(name) is not available in an audit turn") }
        return try dispatch(name, arguments)
    }

    func auditTool(_ args: [String: JSONValue]) throws -> String {
        guard let turnId = auditTurnId else { throw ToolError(message: Store.auditTurnOnlyMessage) }
        let key = try string(args, "key")
        guard case .bool(let ok)? = args["ok"] else { throw ToolError(message: "argument ok must be true or false") }
        var notes = ""
        if let v = args["notes"], v != .null {
            guard let text = v.stringValue else { throw ToolError(message: "argument notes must be a string") }
            notes = text
        }
        let sample = try store.recordAudit(turnId: turnId, agentId: agentId, companyId: companyId, key: key, ok: ok, notes: notes)
        let shown = try store.workItem(id: sample.itemId)?.key ?? key
        if ok { return "Recorded: \(shown) is ok." }
        let followUp = try sample.followUpId.flatMap { try store.workItem(id: $0)?.key }
        return "Recorded: the audit of \(shown) failed; its author's changes now always get a full review"
            + (followUp.map { ", and \($0) is open to revert or fix it." } ?? ".")
    }
}
