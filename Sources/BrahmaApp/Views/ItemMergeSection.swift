import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// The item inspector's MERGE section (Plan 4a Task 10): BRANCH, AHEAD / BEHIND, DIFF, VERIFIED and MERGE (the request's
/// chip, `M-<n>`, its queue position or what happened), plus the redacted tail of a failed check. A conflict keeps 3a's brief
/// to the holder: only the engine's conflict line shows here. File names and tails are agent-controlled: `Text(verbatim:)`.
struct ItemMergeSection: View {
    let detail: ItemMergeDetail?

    var body: some View {
        let d = detail ?? ItemMergeDetail()
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            KeyValueGrid(rows: [
                KeyValueRow(label: "Branch", value: d.branchLine, mono: true),
                KeyValueRow(label: "Ahead / behind", value: d.aheadBehind, mono: true),
                KeyValueRow(label: "Diff", value: d.diffLine, mono: true),
                KeyValueRow(label: "Verified", value: d.verifiedLine, mono: true),
            ])
            HStack(alignment: .firstTextBaseline, spacing: BrahmaTheme.spaceS) {
                CapsLabel("Merge")
                if let title = d.statusTitle, let tone = d.tone, let request = d.request, let line = d.mergeLine {
                    StatusChip(label: title, color: MergeQueueView.toneColor(tone), pulse: tone == .running)
                    Text(verbatim: request.ref).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text0)
                    Text(verbatim: line).font(BrahmaTheme.monoSmall)
                        .foregroundStyle(tone == .danger ? BrahmaTheme.danger : tone == .warning ? BrahmaTheme.warning : BrahmaTheme.text1)
                        .lineLimit(2)
                        .textSelection(.enabled)
                } else {
                    Text(verbatim: "—").font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text2)
                }
            }
            if let tail = d.failureTail { MonoBlock(text: tail) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Merge"))
    }
}
