import Foundation

/// Who gets what (§3.4): the pinned pack's `RoleTemplate.extensions` (publisher-matched), then the company's overrides
/// (`extensionBinding` rows), then the active `extension` grants, kept to what is installed, enabled and allowed on the
/// profile (§4.4), sorted by id. The hash and host-tool checks happen at mount time (`ExtensionLibrary.mounts`).
public enum RoleBundle {
    public struct Installed: Equatable, Sendable {
        public var id: String
        public var publisher: String
        public var hash: String
        public var enabled: Bool
        public init(id: String, publisher: String, hash: String, enabled: Bool) {
            self.id = id; self.publisher = publisher; self.hash = hash; self.enabled = enabled
        }
        var ref: ExtensionRef { ExtensionRef(publisher: publisher, id: id) }
    }

    /// - `grants`: grant values, `<publisher>/<id>`.
    /// - A `remove` binding for the role, the agent or `*` beats every add, pack suggestion and grant.
    public static func effective(packRefs: [ExtensionRef], bindings: [ExtensionBinding], grants: [String], installed: [Installed],
                                 role: String, agentId: String, profile: PermissionProfile) -> [Installed] {
        let byId = Dictionary(installed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var chosen: Set<String> = []
        for ref in packRefs {
            if let have = byId[ref.id], have.publisher == ref.publisher { chosen.insert(ref.id) }
        }
        func applies(_ b: ExtensionBinding) -> Bool {
            switch b.scope {
            case "role": return b.target == role || b.target == "*"
            case "agent": return b.target == agentId
            default: return false
            }
        }
        for b in bindings where b.op == "add" && applies(b) { chosen.insert(b.id) }
        for g in grants {
            if let ref = ExtensionRef.parse(g), let have = byId[ref.id], have.publisher == ref.publisher { chosen.insert(ref.id) }
        }
        for b in bindings where b.op == "remove" && applies(b) { chosen.remove(b.id) }
        return chosen.sorted().compactMap { id in
            guard let have = byId[id], have.enabled else { return nil }
            if profile != .sandboxed, !ExtensionPublisher.isFirstParty(have.publisher) { return nil }
            return have
        }
    }
}
