import SwiftUI
import BrahmaCore
import BrahmaAppModel

// Small pieces shared by the backlog, board and Inbox. Agent-sourced strings are always `Text(verbatim:)`.

extension WorkItemStatus {
    /// backlog `text2`, ready `ready`, inProgress `running`, inReview `accent`, done `success`, blocked `danger`.
    var chipColor: Color {
        switch self {
        case .backlog: BrahmaTheme.text2
        case .ready: BrahmaTheme.ready
        case .inProgress: BrahmaTheme.running
        case .inReview: BrahmaTheme.accent
        case .done: BrahmaTheme.success
        case .blocked: BrahmaTheme.danger
        }
    }
}

struct ItemStatusChip: View {
    let status: WorkItemStatus

    var body: some View {
        StatusChip(label: status.title, color: status.chipColor)
    }
}

/// A `warning` chip: review flags, over-budget, ahead-of-pace, "changed since proposed", reserved matters, "unconfirmed".
struct WarningChip: View {
    let label: String

    var body: some View {
        StatusChip(label: label, color: BrahmaTheme.warning)
    }
}

/// An engine-hold style `danger` chip.
struct DangerChip: View {
    let label: String

    var body: some View {
        StatusChip(label: label, color: BrahmaTheme.danger)
    }
}

/// Mono block for check output and other tails; selectable, never interpreted.
struct MonoBlock: View {
    let text: String
    var maxHeight: CGFloat = 120

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(BrahmaTheme.monoSmall)
                .foregroundStyle(BrahmaTheme.text1)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(BrahmaTheme.spaceS)
        }
        .frame(maxHeight: maxHeight)
        .background(BrahmaTheme.bg0)
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.line, lineWidth: 1))
    }
}

/// Color for a check line: failures `danger`, pass `success`, everything else `text1`.
func checkColor(_ label: String) -> Color {
    if label.contains("failed") || label.contains("timed out") || label.contains("error") { return BrahmaTheme.danger }
    if label.contains("(flaky)") || label.contains("inconclusive") { return BrahmaTheme.warning }
    if label.contains("passed") { return BrahmaTheme.success }
    return BrahmaTheme.text1
}
