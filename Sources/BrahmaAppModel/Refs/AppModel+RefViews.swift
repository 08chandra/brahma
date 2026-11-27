import Foundation
import BrahmaCore

/// Plan C Task C7a: the owner-side seams the views draw from, each a thin call over an existing engine API. Every string they
/// return is the engine's gated final string (or built by a gated presentation such as `SharingRows.make`); the stored values
/// come from the injected vault, and a vault that can't be read refuses (nothing is shown ungated).
extension AppModel {
    /// How many reads per shared ref the SHARING filter's READS toggle loads (newest first).
    public nonisolated static let sharingReadsPerRef = 20
    /// How many distinct shared refs the READS toggle looks up.
    public nonisolated static let sharingReadRefs = 50

    /// The Inbox card of the file request `askId` (`Store.fileRequestCard`: every agent-written field gated against the stored
    /// values as its final display string, impersonation flagged). Nil when it is not one of this company's file requests, when
    /// there is no owner principal, or when the stored values can't be read (fail closed: the view shows no agent text).
    public func fileRequestCard(askId: String) async -> FileRequestCard? {
        guard let companyId = selectedCompanyId, owner != nil else { return nil }
        let store = self.store, vault = self.secretVault
        return try? await Task.detached {
            let known = try store.knownSecretValues(companyId: companyId, vault: vault)
            return try store.fileRequestCard(companyId: companyId, askId: askId, knownValues: known)
        }.value
    }

    /// The ACTIVITY panel's SHARING rows (collab design §4.7): the feed's share, access, export and show events and, with
    /// `reads` (the READS toggle), the recorded reads of the refs those events name (`Store.refReads`, newest
    /// `sharingReadsPerRef` of each of up to `sharingReadRefs` refs). Every string is gated by `SharingRows.make` with the stored
    /// values of the injected vault; throws when they can't be read (the view shows the refusal, never ungated rows).
    public func sharingRows(reads: Bool) async throws -> [SharingRow] {
        guard let companyId = selectedCompanyId else { return [] }
        guard owner != nil else { throw WorkError.forbidden(OwnerPrincipal.refusal) }
        let store = self.store, vault = self.secretVault, handles = self.handles, tz = ownerTimeZone
        let events = activity.filter { $0.companyId == companyId && ActivityFilter.sharing.includes($0.kind) }
        return try await Task.detached {
            let known = try store.knownSecretValues(companyId: companyId, vault: vault)
            var readRows: [RefRead]?
            if reads {
                // The refs the share events name, as the engine wrote them (`<who> shared <ref> @<sha7>, <ref> with <to>`):
                // each without its pinned-revision suffix (a read records the rev apart), deduplicated.
                var canonicals: [String] = []
                outer: for row in SharingRows.make(events: events, reads: nil, handles: handles, timeZone: tz, knownValues: known) where !row.ref.isEmpty {
                    for piece in row.ref.components(separatedBy: ", ") {
                        let c = Self.withoutPinnedRev(piece)
                        guard !c.isEmpty, !canonicals.contains(c) else { continue }
                        canonicals.append(c)
                        if canonicals.count >= Self.sharingReadRefs { break outer }
                    }
                }
                var all: [RefRead] = []
                for c in canonicals { all += try store.refReads(companyId: companyId, canonical: c, limit: Self.sharingReadsPerRef) }
                readRows = all
            }
            return SharingRows.make(events: events, reads: readRows, handles: handles, timeZone: tz, knownValues: known)
        }.value
    }

    /// `src/a.ts:1-20 @682186b` → `src/a.ts:1-20` (the share line's pinned revision, 7–40 hex digits after ` @`).
    nonisolated static func withoutPinnedRev(_ shown: String) -> String {
        guard let r = shown.range(of: #" @[0-9a-f]{7,40}$"#, options: .regularExpression) else { return shown }
        return String(shown[..<r.lowerBound])
    }

    /// "Open in chat": the conversation of message `messageId` selected, loaded back to it and the message highlighted. A
    /// message this company doesn't have is the generic refusal (`Store.refUnavailable`) and nothing changes.
    public func openInChat(messageId: String) async {
        guard let companyId = selectedCompanyId, let owner = ownerOrRefuse() else { return }
        let store = self.store
        let message = (try? await Task.detached { try store.message(companyId: companyId, id: messageId, owner: owner) }.value) ?? nil
        guard companyId == selectedCompanyId else { return }
        guard let message else {
            errorMessage = Store.refUnavailable
            return
        }
        select(.channel(id: message.channelId))
        guard let chat else { return }
        await chat.refresh()
        await chat.ensureLoaded(messageId: message.id)
        highlightedMessageId = message.id
    }
}
