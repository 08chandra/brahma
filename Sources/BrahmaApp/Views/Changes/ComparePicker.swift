import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Plan C Task C7c: what the live diff compares (collab design §1.6): VS MAIN · VS LAST COMMIT · VS LAST CHECK · REVISIONS…, and
/// for REVISIONS the from/to menus built from the item's revisions (`ChangesTabModel.revisions`: `base`, `r<n>`, `head`,
/// `worktree`). The choice is handed to the caller (`ChangesTabModel.setCompare`, or in the OPENED tab a new ref); the engine
/// checks access and the labels on every subscription.
struct ComparePicker: View {
    let compare: CompareMode
    let revisions: [ItemRevision]
    let choose: (CompareMode) -> Void

    enum Choice: Hashable { case main, head, check, revisions }

    private var current: Choice {
        switch compare {
        case .main: .main
        case .head: .head
        case .lastCheck: .check
        case .revisions: .revisions
        }
    }

    var body: some View {
        HStack(spacing: BrahmaTheme.spaceXS) {
            Segmented(options: [(Choice.main, "VS MAIN"), (.head, "VS LAST COMMIT"), (.check, "VS LAST CHECK"), (.revisions, "REVISIONS…")],
                      selection: current, label: "Compare", select: pick)
            if case .revisions(let from, let to) = compare {
                HStack(spacing: BrahmaTheme.spaceXS) {
                    menu("FROM", value: from, labels: fromLabels(including: from)) { choose(.revisions(from: $0, to: to)) }
                    Text(verbatim: "→").font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                    menu("TO", value: to, labels: toLabels(including: to)) { choose(.revisions(from: from, to: $0)) }
                }
            }
        }
    }

    private func pick(_ c: Choice) {
        switch c {
        case .main: choose(.main)
        case .head: choose(.head)
        case .check: choose(.lastCheck)
        case .revisions:
            // The oldest check revision to the live worktree (else the merge base to the item's last commit).
            let labels = revisions.map(\.label)
            let from = labels.first(where: Self.isRun) ?? "base"
            let to = labels.contains("worktree") ? "worktree" : "head"
            choose(.revisions(from: from, to: to))
        }
    }

    /// `base` and every `r<n>`.
    private func fromLabels(including current: String) -> [String] {
        let labels = revisions.map(\.label).filter { $0 == "base" || Self.isRun($0) }
        return labels.contains(current) ? labels : [current] + labels
    }

    /// Every `r<n>`, `head` and `worktree`.
    private func toLabels(including current: String) -> [String] {
        let labels = revisions.map(\.label).filter { $0 == "head" || $0 == "worktree" || Self.isRun($0) }
        return labels.contains(current) ? labels : labels + [current]
    }

    static func isRun(_ label: String) -> Bool {
        label.count > 1 && label.hasPrefix("r") && label.dropFirst().allSatisfy(\.isNumber)
    }

    /// `r1 · 1a2b3c4 · PASSED` (engine labels, a short sha and the check's status).
    private func title(_ label: String) -> String {
        guard let rev = revisions.first(where: { $0.label == label }) else { return label }
        var parts = [label]
        if let sha = rev.sha { parts.append(String(sha.prefix(7))) }
        if let status = rev.checkStatus { parts.append(status.uppercased()) }
        return parts.joined(separator: " · ")
    }

    private func menu(_ caption: String, value: String, labels: [String], pick: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(labels, id: \.self) { label in
                Button { if label != value { pick(label) } } label: { Text(verbatim: title(label)) }
            }
        } label: {
            MonoChip(text: "\(caption) \(value)", color: BrahmaTheme.text0, fill: BrahmaTheme.bg4)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(caption == "FROM" ? "Compare from this revision" : "Compare to this revision")
    }
}
