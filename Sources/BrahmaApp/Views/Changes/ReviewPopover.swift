import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Plan C Task C7c: the inline review popover (collab design §1.6), opened from the gutter "+" of a hovered line or hunk. The
/// owner's comment goes to the lease holder as an item comment ("Comment"), or asks the holder to revert the hunk ("Ask to
/// revert this hunk", the text as its note). Both post through `AppModel.submitReview` — the owner principal's path; the engine
/// quotes the hunk for the live reader set only and never touches the worktree. Errors show in `danger`.
struct ReviewPopover: View {
    /// The model's anchor of the line (nil when the line can't take a comment).
    let anchor: DiffAnchor?
    /// `@eng-1`.
    let holder: String?
    let submit: @MainActor (ReviewDraft) async -> String?
    let done: () -> Void

    @State private var text = ""
    @State private var error: String?
    @State private var posting = false

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            HStack(spacing: BrahmaTheme.spaceS) {
                CapsLabel("Review")
                if let anchor {
                    // The engine's display path and the line number (gated by the engine; verbatim).
                    Text(verbatim: "\(anchor.path):\(anchor.line)")
                        .font(BrahmaTheme.monoSmall)
                        .foregroundStyle(BrahmaTheme.text2)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            if anchor == nil {
                Text(verbatim: "This line can't take a comment.").font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.danger)
            } else {
                TextField("Comment", text: $text, prompt: Text("Your comment for the holder"), axis: .vertical)
                    .lineLimit(3...8)
                    .brahmaField()
                    .disabled(posting)
                if text.count > ReviewDraft.maxText - 200 {
                    Text(verbatim: "\(text.count) / \(ReviewDraft.maxText)")
                        .font(BrahmaTheme.monoTiny)
                        .foregroundStyle(text.count > ReviewDraft.maxText ? BrahmaTheme.danger : BrahmaTheme.text2)
                }
                if let error {
                    Text(verbatim: error)
                        .font(BrahmaTheme.monoSmall)
                        .foregroundStyle(BrahmaTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: BrahmaTheme.spaceS) {
                    Button("Ask to revert this hunk") { post(revert: true) }
                        .buttonStyle(.brahma)
                        .disabled(posting)
                    Spacer(minLength: 0)
                    if posting { ProgressView().controlSize(.small) }
                    Button("Comment") { post(revert: false) }
                        .buttonStyle(.brahmaPrimary)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(posting)
                }
            }
            Text(verbatim: "Sent to \(holder ?? "the holder") as an item comment. Brahma never edits their files.")
                .font(BrahmaTheme.monoTiny)
                .foregroundStyle(BrahmaTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(BrahmaTheme.spaceM)
        .frame(width: 360)
        .background(BrahmaTheme.bg1)
        .preferredColorScheme(.dark)
    }

    private func post(revert: Bool) {
        guard let anchor, !posting else { return }
        let draft = ReviewDraft(anchor: anchor, text: text, isRevert: revert)
        if let problem = draft.validate() {
            error = problem
            return
        }
        posting = true
        error = nil
        Task {
            let failure = await submit(draft)
            posting = false
            if let failure {
                error = failure
            } else {
                text = ""
                done()
            }
        }
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
                            CapsLabel(c.kind == DiffComment.revertRequest ? "Revert request" : "Comment",
                                      color: c.kind == DiffComment.revertRequest ? BrahmaTheme.warning : BrahmaTheme.accent)
                            Text(verbatim: Self.time(c.createdAt, timeZone)).font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2)
                            if c.tainted { RefChipView(chip: RefChip(text: "TAINTED", tone: .warn)) }
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
