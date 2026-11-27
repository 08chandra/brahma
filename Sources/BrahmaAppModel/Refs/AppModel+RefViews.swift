import Foundation
import BrahmaCore

/// Plan C Task C7a: the owner-side seams the views draw from, each a thin call over an existing engine API. Every string they
/// return is the engine's gated final string (or built by a gated presentation such as `SharingRows.make`); the stored values
/// come from the injected vault, and a vault that can't be read refuses (nothing is shown ungated).
extension AppModel {
    /// How many recorded reads the SHARING filter's READS toggle loads (newest first).
    public nonisolated static let sharingReads = 500

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
    /// `reads` (the READS toggle), the company's newest `sharingReads` recorded reads as the engine stored them
    /// (`Store.recentRefReads`, owner only: structured rows, never canonicals parsed out of display text — fix round 1, M-6).
    /// Every string is gated by `SharingRows.make` with the stored values of the injected vault; throws when they can't be read
    /// (the view shows the refusal, never ungated rows).
    public func sharingRows(reads: Bool) async throws -> [SharingRow] {
        guard let companyId = selectedCompanyId else { return [] }
        guard let owner else { throw WorkError.forbidden(OwnerPrincipal.refusal) }
        let store = self.store, vault = self.secretVault, handles = self.handles, tz = ownerTimeZone
        let events = activity.filter { $0.companyId == companyId && ActivityFilter.sharing.includes($0.kind) }
        return try await Task.detached {
            let known = try store.knownSecretValues(companyId: companyId, vault: vault)
            let readRows = reads ? try store.recentRefReads(companyId: companyId, limit: Self.sharingReads, owner: owner) : nil
            return SharingRows.make(events: events, reads: readRows, handles: handles, timeZone: tz, knownValues: known)
        }.value
    }

    /// Fix round 1 (M-9): "Can't provide → reply" — the engine's decline of the file request `askId` (`Store.declineFileRequest`:
    /// answered `declined: <note>`, a DM that wakes the requester), owner only.
    @discardableResult
    public func declineFileRequest(askId: String, note: String) async -> Bool {
        guard let companyId = selectedCompanyId, ownerOrRefuse() != nil else { return false }
        let now = clock()
        return await ownerAct("decline the file request") { store, owner in
            _ = try store.declineFileRequest(companyId: companyId, askId: askId, note: note, now: now, owner: owner)
            return true
        } ?? false
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
