import Foundation
import BrahmaCore

/// What the owner types against a diff line before it is posted: an inline comment, or a revert request with an optional note
/// (collab design §1.6). Nothing is sent until `AppModel.submitReview`.
public struct ReviewDraft: Equatable, Sendable {
    /// The pinned comment length (`DiffReviewLimits.maxText`, 2000).
    public static let maxText = DiffReviewLimits.maxText

    public var anchor: DiffAnchor
    public var text: String
    public var isRevert: Bool

    public init(anchor: DiffAnchor, text: String = "", isRevert: Bool = false) {
        self.anchor = anchor; self.text = text; self.isRevert = isRevert
    }

    /// The problem with the draft, or nil when it can be posted: a comment needs text; nothing may exceed `maxText` characters.
    public func validate() -> String? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty && !isRevert { return "Write a comment first" }
        if body.count > Self.maxText { return "Keep the comment under \(Self.grouped(Self.maxText)) characters" }
        return nil
    }

    /// `2,000`.
    static func grouped(_ n: Int) -> String {
        let digits = Array(String(n))
        var out = ""
        for (i, d) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(d)
        }
        return out
    }
}

extension AppModel {
    /// Posts the owner's review on item `key`'s diff (`compare`): a comment through `Store.addDiffComment`, a revert request through
    /// `Store.requestHunkRevert` (the engine quotes the hunk for the holder and never touches the worktree). Ruling C6-3: both take
    /// the minted owner principal; without one the review is refused before any Store call. An invalid draft posts nothing.
    @discardableResult
    public func submitReview(_ draft: ReviewDraft, key: String, compare: CompareMode) async -> Bool {
        if let problem = draft.validate() {
            errorMessage = problem
            return false
        }
        guard let companyId = selectedCompanyId, let owner = ownerOrRefuse() else { return false }
        let vault = secretVault, now = clock()
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let posted: Bool? = await ownerWrite("post the review") { store in
            let known = try store.knownSecretValues(companyId: companyId, vault: vault)
            if draft.isRevert {
                try store.requestHunkRevert(companyId: companyId, key: key, compare: compare, anchor: draft.anchor, note: text.isEmpty ? nil : text,
                                            knownValues: known, now: now, owner: owner)
            } else {
                try store.addDiffComment(companyId: companyId, key: key, compare: compare, anchor: draft.anchor, text: text, knownValues: known, now: now,
                                         owner: owner)
            }
            return true
        }
        guard posted == true else { return false }
        // The item's comments (engine records, no git): the markers follow.
        if let changes, changes.selectedKey == key { await changes.refreshItem() }
        return true
    }
}

extension AppModel {
    /// C7c fix round 1 (I-1, m-5): posts the CHANGES model's review in progress (`ChangesTabModel.review`) as a comment or a revert
    /// request, against the key and compare it was started on, through `submitReview` (the owner principal's path). A problem or
    /// refusal stays on the draft with every typed character kept; the window's alert is put back only when the refusal is the
    /// one this post raised (an alert another task raised stays). Posted: the draft is done.
    @discardableResult
    public func postReview(isRevert: Bool) async -> Bool {
        guard let changes, var session = changes.review, !session.posting else { return false }
        session.draft.isRevert = isRevert
        if let problem = session.draft.validate() {
            changes.reviewFailed(problem)
            return false
        }
        changes.setReviewPosting(true)
        let before = errorMessage
        let posted = await submitReview(session.draft, key: session.key, compare: session.compare)
        if posted {
            if changes.review?.draft.anchor == session.draft.anchor { changes.review = nil }
            return true
        }
        let current = errorMessage
        let message = current.flatMap { $0 != before ? $0 : nil } ?? "Couldn't post the review"
        if current != before { errorMessage = Self.alertAfterReview(current: current, ours: message, before: before) }
        changes.reviewFailed(message)
        return false
    }

    /// m-5: the alert after a refused review post — what was there before when the current alert is the one the post raised,
    /// else the current one untouched.
    public nonisolated static func alertAfterReview(current: String?, ours: String, before: String?) -> String? {
        current == ours ? before : current
    }
}
