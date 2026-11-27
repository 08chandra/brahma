import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Plan C Task C7c: the inline review popover (collab design §1.6), opened from the gutter "+" of a hovered line or hunk. The
/// owner's comment goes to the lease holder as an item comment ("Comment"), or asks the holder to revert the hunk ("Ask to
/// revert this hunk", the text as its note). Both post through `AppModel.postReview` → `submitReview` — the owner principal's
/// path; the engine quotes the hunk for the live reader set only and never touches the worktree. Errors show in `danger`.
///
/// Fix round 1 (I-1): the draft (anchor, text, error, posting) is the CHANGES model's `review`, and the popover hangs off the
/// CHANGES view, so live yields never lose it; while no verified diff of the draft's item and compare is shown, posting waits.
struct ReviewPopover: View {
    let session: ChangesTabModel.ReviewSession
    /// `@eng-1`.
    let holder: String?
    /// `ChangesTabModel.canPostReview`.
    let canPost: Bool
    @Binding var text: String
    let post: (_ revert: Bool) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            HStack(spacing: BrahmaTheme.spaceS) {
                CapsLabel("Review")
                // The engine's display path and the line number (gated by the engine; verbatim).
                Text(verbatim: "\(session.draft.anchor.path):\(session.draft.anchor.line)")
                    .font(BrahmaTheme.monoSmall)
                    .foregroundStyle(BrahmaTheme.text2)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            TextField("Comment", text: $text, prompt: Text("Your comment for the holder"), axis: .vertical)
                .lineLimit(3...8)
                .brahmaField()
                .disabled(session.posting)
            if text.count > ReviewDraft.maxText - 200 {
                Text(verbatim: "\(text.count) / \(ReviewDraft.maxText)")
                    .font(BrahmaTheme.monoTiny)
                    .foregroundStyle(text.count > ReviewDraft.maxText ? BrahmaTheme.danger : BrahmaTheme.text2)
            }
            if let error = session.error {
                Text(verbatim: error)
                    .font(BrahmaTheme.monoSmall)
                    .foregroundStyle(BrahmaTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !canPost && !session.posting {
                Text(verbatim: "Waiting for the diff to show again; your text is kept.")
                    .font(BrahmaTheme.monoSmall)
                    .foregroundStyle(BrahmaTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: BrahmaTheme.spaceS) {
                Button("Cancel", action: cancel)
                    .buttonStyle(.brahma)
                    .disabled(session.posting)
                Button("Ask to revert this hunk") { post(true) }
                    .buttonStyle(.brahma)
                    .disabled(!canPost)
                Spacer(minLength: 0)
                if session.posting { ProgressView().controlSize(.small) }
                Button("Comment") { post(false) }
                    .buttonStyle(.brahmaPrimary)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canPost)
            }
            Text(verbatim: "Sent to \(holder ?? "the holder") as an item comment. Brahma never edits their files.")
                .font(BrahmaTheme.monoTiny)
                .foregroundStyle(BrahmaTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(BrahmaTheme.spaceM)
        .frame(width: 380)
        .background(BrahmaTheme.bg1)
        .preferredColorScheme(.dark)
    }
}

/// The comments on one diff line (the marker's thread): kind, time and the owner's text as the engine returned it (gated),
/// with the TAINTED chip when the quoted hunk carried outside content.
struct DiffThreadPopover: View {
    let comments: [DiffComment]
    /// The owner's time zone (`AppModel.ownerTimeZone`, set on the CHANGES view).
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
                ForEach(Array(comments.enumerated()), id: \.offset) { i, c in
                    if i > 0 { Hairline() }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: BrahmaTheme.spaceS) {
                            CapsLabel(DiffThread.kindText(c), color: c.kind == DiffComment.revertRequest ? BrahmaTheme.warning : BrahmaTheme.accent)
                            Text(verbatim: Self.time(c.createdAt, timeZone)).font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2)
                            // m-6: the model's chips.
                            ForEach(Array(DiffThread.chips(for: c).enumerated()), id: \.offset) { _, chip in RefChipView(chip: chip) }
                            Spacer(minLength: 0)
                        }
                        if !c.text.isEmpty {
                            RefStyle.marked(c.text)
                                .font(BrahmaTheme.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(BrahmaTheme.spaceM)
        }
        .frame(width: 320)
        .frame(maxHeight: 280)
        .background(BrahmaTheme.bg1)
        .preferredColorScheme(.dark)
    }

    private static func time(_ date: Date, _ zone: TimeZone) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        f.timeZone = zone
        return f.string(from: date)
    }
}
