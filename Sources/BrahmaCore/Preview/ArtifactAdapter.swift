import Foundation

/// Published artifacts as a preview kind (Plan 4a Task 6). Artifacts are never a surface (`publish_artifact` makes them, and
/// the runner skips the `artifact` kind), so `start` only says so; what this adapter gives is the demo line: the latest
/// artifact's ref, never its title (agent text; the title shows only in the app).
public struct ArtifactAdapter: PreviewAdapter {
    public let store: Store

    public init(store: Store) { self.store = store }

    public var kind: PreviewKind { .artifact }

    public func availability() -> String? { nil }

    public func start(_ c: PreviewContext) async -> PreviewUpdate {
        PreviewUpdate(status: .unavailable, message: "artifacts appear automatically; use publish_artifact")
    }

    public func stop(_ c: PreviewContext, state: PreviewState) async {}

    public func demo(_ c: PreviewContext, state: PreviewState) async -> DemoCapture {
        Self.latestDemo(store: store, companyId: c.company.id) ?? DemoCapture(ok: false, line: "artifacts: none published")
    }

    /// `ok`, `"artifacts: latest AR-<n>"`; nil when the company has published none. A store that can't be read is not ok:
    /// `"artifacts: could not be read: <error>"`.
    public static func latestDemo(store: Store, companyId: String) -> DemoCapture? {
        do {
            guard let latest = try store.latestArtifact(companyId: companyId) else { return nil }
            return DemoCapture(ok: true, line: "artifacts: latest \(latest.ref)")
        } catch {
            return DemoCapture(ok: false, line: "artifacts: could not be read: \(Store.flat("\(error)", max: 200))")
        }
    }
}
