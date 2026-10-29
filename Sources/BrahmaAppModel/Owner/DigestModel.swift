import Foundation
import Observation
import BrahmaCore

/// Inbox › Digest: the latest stored daily digest of the selected company, rendered through `SafeMarkdown` (agent text in it
/// is already escaped by the builder; nothing in it can link or load anything), and "Build now".
@MainActor @Observable
public final class DigestModel {
    public private(set) var digest: OwnerDigest?
    public private(set) var rendered: AttributedString?
    /// "2026-10-28 08:00 – 2026-10-29 08:00 (owner time)".
    public private(set) var periodLine: String?
    public private(set) var error: String?
    public private(set) var isBuilding = false
    public var companyId: String?
    @ObservationIgnored private let store: Store

    public init(store: Store) {
        self.store = store
    }

    public func reload() async {
        guard let companyId else { digest = nil; rendered = nil; periodLine = nil; return }
        let store = self.store
        struct Read: Sendable { var digest: OwnerDigest?; var zone: TimeZone }
        do {
            let read: Read = try await Task.detached {
                Read(digest: try store.latestDigest(companyId: companyId), zone: store.ownerTimeZone())
            }.value
            digest = read.digest
            rendered = read.digest.map { SafeMarkdown.render($0.markdown) }
            periodLine = read.digest.map { Self.period($0, timeZone: read.zone) }
        } catch {
            self.error = "\(error)"
        }
    }

    /// Builds a digest now, since the last one (else the last 24 hours), and stores it: what `brahma dev digest` does.
    public func buildNow() async {
        guard let companyId, !isBuilding else { return }
        isBuilding = true
        defer { isBuilding = false }
        let store = self.store
        do {
            try await Task.detached {
                let now = Date()
                let since = try store.lastDigestEnd(companyId: companyId) ?? now.addingTimeInterval(-86_400)
                let digest = try DigestBuilder.build(store: store, companyId: companyId, since: since, now: now, tz: store.ownerTimeZone())
                _ = try store.saveDigest(companyId: companyId, digest: digest, now: now)
            }.value
            error = nil
        } catch {
            self.error = "Couldn't build the digest: \(error)"
        }
        await reload()
    }

    static func period(_ d: OwnerDigest, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(f.string(from: d.periodStart)) – \(f.string(from: d.periodEnd))"
    }
}
