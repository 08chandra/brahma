import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// A static diff (collab design §1.3): since C7c a thin wrapper over the CHANGES tab's `DiffPane` — a file list with stat bars,
/// unified hunks with folds and a per-file collapse, added and deleted lines tinted `success`/`danger` at 15 %, and
/// `updated <n> s ago` for live diffs. No review gutter and no markers (those are the CHANGES tab's). It draws no chip of its own
/// (C7a fix round 1, I-1): UNCOMMITTED, LIVE, TAINTED and HIDDEN CHARACTERS are the model's, in the ref header or passed in as
/// `chips`. Callers pass only a diff the model verified against the engine's sections (`RefBodies.verifiedDiff` →
/// `ChangesPatch.identity`, `ChangesTabModel.verify`); this wrapper changes nothing about that.
///
/// Every path drawn is the model's gated `displayPath`/`displayOldPath` (never `path`); a hunk header is drawn as its numbers
/// only (`DiffAnchoring.headerRange`: never the agent's function context); line text is `Text(verbatim:)` through the model's
/// highlighter with hidden characters as `warning` markers; nothing in the diff text is clickable.
struct DiffView: View {
    let diff: DiffModel
    /// The model's chips for this diff, drawn as they are (none when the ref header carries them).
    var chips: [RefChip] = []
    /// When the shown snapshot was computed (`updated <n> s ago`, ticking); else `updatedText` as given.
    var updatedAt: Date?
    var updatedText: String?

    @State private var jump: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if diff.files.isEmpty {
                MonoEmptyState("No changes", detail: diff.truncated ? "The diff was cut at \(DiffModel.defaultMaxLines) lines." : nil)
            } else {
                HStack(spacing: 0) {
                    fileList.frame(width: 170)
                    Hairline(axis: .vertical)
                    DiffPane(diff: diff, jump: $jump)
                }
            }
        }
        .background(BrahmaTheme.bg0)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: BrahmaTheme.spaceS) {
            Text(verbatim: diff.statLine).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1).lineLimit(1)
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in RefChipView(chip: chip) }
            if diff.truncated {
                Text(verbatim: "cut at \(DiffModel.defaultMaxLines) lines").font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2)
            }
            Spacer(minLength: 0)
            if let updatedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(verbatim: "updated \(max(0, Int(ctx.date.timeIntervalSince(updatedAt)))) s ago")
                        .font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2)
                }
            } else if let updatedText {
                Text(verbatim: updatedText).font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2)
            }
        }
        .padding(.horizontal, BrahmaTheme.spaceS)
        .frame(height: BrahmaTheme.rowHeight)
        .background(BrahmaTheme.bg2)
    }

    // MARK: File list

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.files.enumerated()), id: \.offset) { i, file in
                    Button { jump = "file-\(i)" } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: file.displayPath)
                                .font(BrahmaTheme.monoSmall)
                                .foregroundStyle(BrahmaTheme.text0)
                                .lineLimit(1)
                                .truncationMode(.head)
                            HStack(spacing: 6) {
                                DiffCounts(added: file.added, removed: file.removed)
                                StatBar(added: file.added, removed: file.removed)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .tableRow(index: i, height: 38)
                    // Fix round 1 (M-2): one gated string as the model made it, never two joined after the gate.
                    .help(Text(verbatim: file.displayPath))
                }
            }
        }
        .background(BrahmaTheme.bg2)
    }
}

/// A file's added/removed share as a 40 pt bar (`success` then `danger`).
struct StatBar: View {
    let added: Int
    let removed: Int
    var width: CGFloat = 40

    var body: some View {
        let total = max(added + removed, 1)
        let green = width * CGFloat(added) / CGFloat(total)
        HStack(spacing: 0) {
            Rectangle().fill(BrahmaTheme.success).frame(width: green)
            Rectangle().fill(added + removed == 0 ? BrahmaTheme.line : BrahmaTheme.danger).frame(width: width - green)
        }
        .frame(width: width, height: 4)
        .clipShape(RoundedRectangle(cornerRadius: 1))
        .accessibilityHidden(true)
    }
}
