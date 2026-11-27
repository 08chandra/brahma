import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// A diff (collab design §1.3; C7c makes the CHANGES tab's richer view): a file list with stat bars, unified hunks with a
/// per-file collapse, added and deleted lines tinted `success`/`danger` at 15 %, a `HIDDEN CHARACTERS` chip when the model
/// found any, `LIVE · UNCOMMITTED` and `updated <n> s ago` for live diffs.
///
/// Every path drawn is the model's gated `displayPath`/`displayOldPath` (never `path`); a hunk header is drawn as its numbers
/// only (`DiffAnchoring.headerRange`: never the agent's function context); line text is `Text(verbatim:)` through the model's
/// highlighter with hidden characters as `warning` markers; nothing in the diff is clickable.
struct DiffView: View {
    let diff: DiffModel
    var live = false
    /// The live target is the item's worktree (`LIVE · UNCOMMITTED`).
    var uncommitted = false
    /// When the shown snapshot was computed (`updated <n> s ago`, ticking); else `updatedText` as given.
    var updatedAt: Date?
    var updatedText: String?

    @State private var collapsed: Set<Int> = []
    /// Per file, per hunk, per line: the highlighted spans (made off the main actor; markers only until then).
    @State private var spans: [[[[CodeSpan]]]] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if diff.files.isEmpty {
                MonoEmptyState("No changes", detail: diff.truncated ? "The diff was cut at \(DiffModel.defaultMaxLines) lines." : nil)
            } else {
                ScrollViewReader { proxy in
                    HStack(spacing: 0) {
                        fileList(proxy).frame(width: 170)
                        Hairline(axis: .vertical)
                        hunks
                    }
                }
            }
        }
        .background(BrahmaTheme.bg0)
        .task(id: diff) {
            let d = diff
            let made = await Task.detached(priority: .userInitiated) { Self.highlight(d) }.value
            guard !Task.isCancelled else { return }
            spans = made
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: BrahmaTheme.spaceS) {
            Text(verbatim: diff.statLine).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1).lineLimit(1)
            if live {
                RefChipView(chip: RefChip(text: uncommitted ? "LIVE · UNCOMMITTED" : "LIVE", tone: .busy))
            }
            if diff.hasHidden { WarningChip(label: "Hidden characters") }
            if diff.truncated { WarningChip(label: "Truncated") }
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

    private func fileList(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.files.enumerated()), id: \.offset) { i, file in
                    Button { withAnimation(BrahmaTheme.fast) { proxy.scrollTo("file-\(i)", anchor: .top) } } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: file.displayPath)
                                .font(BrahmaTheme.monoSmall)
                                .foregroundStyle(BrahmaTheme.text0)
                                .lineLimit(1)
                                .truncationMode(.head)
                            HStack(spacing: 6) {
                                Self.counts(added: file.added, removed: file.removed)
                                StatBar(added: file.added, removed: file.removed)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .tableRow(index: i, height: 38)
                    .help(Text(verbatim: file.displayOldPath.map { "\($0) → \(file.displayPath)" } ?? file.displayPath))
                }
            }
        }
        .background(BrahmaTheme.bg2)
    }

    static func counts(added: Int, removed: Int) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: "+\(added)").foregroundStyle(BrahmaTheme.success)
            Text(verbatim: "\u{2212}\(removed)").foregroundStyle(BrahmaTheme.danger)
        }
        .font(BrahmaTheme.monoTiny)
    }

    // MARK: Hunks

    private var hunks: some View {
        GeometryReader { geo in
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.files.enumerated()), id: \.offset) { f, file in
                    fileHeader(f, file).id("file-\(f)")
                    if !collapsed.contains(f) {
                        ForEach(Array(file.hunks.enumerated()), id: \.offset) { h, hunk in
                            Text(verbatim: DiffAnchoring.headerRange(hunk.header) ?? "@@ -\(hunk.oldStart) +\(hunk.newStart) @@")
                                .font(BrahmaTheme.monoSmall)
                                .foregroundStyle(BrahmaTheme.accent)
                                .padding(.horizontal, BrahmaTheme.spaceS)
                                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                                .background(BrahmaTheme.accent.opacity(0.08))
                            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { n, line in
                                DiffLineRow(line: line, spans: lineSpans(f, h, n, line))
                            }
                        }
                    }
                }
            }
            // A two-axis scroll view centers narrower content: pin the rows to the leading edge, at least the pane wide.
            .frame(minWidth: geo.size.width, alignment: .leading)
        }
        }
        .background(BrahmaTheme.bg0)
    }

    private func fileHeader(_ f: Int, _ file: DiffFile) -> some View {
        let isCollapsed = collapsed.contains(f)
        return Button {
            withAnimation(BrahmaTheme.fast) { if isCollapsed { collapsed.remove(f) } else { collapsed.insert(f) } }
        } label: {
            HStack(spacing: BrahmaTheme.spaceS) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(BrahmaTheme.text2)
                    .frame(width: 10)
                if let old = file.displayOldPath {
                    Text(verbatim: old).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2).lineLimit(1)
                    Text(verbatim: "→").font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                }
                Text(verbatim: file.displayPath).font(BrahmaTheme.monoSmall.weight(.semibold)).foregroundStyle(BrahmaTheme.text0).lineLimit(1)
                Self.counts(added: file.added, removed: file.removed)
                StatBar(added: file.added, removed: file.removed)
                Spacer(minLength: BrahmaTheme.spaceL)
            }
            .padding(.horizontal, BrahmaTheme.spaceS)
            .frame(maxWidth: .infinity, minHeight: BrahmaTheme.rowHeight, alignment: .leading)
            .background(BrahmaTheme.bg3)
            .overlay(alignment: .bottom) { Hairline() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: (isCollapsed ? "Expand " : "Collapse ") + file.displayPath))
    }

    private func lineSpans(_ f: Int, _ h: Int, _ n: Int, _ line: DiffLine) -> [CodeSpan] {
        if spans.indices.contains(f), spans[f].indices.contains(h), spans[f][h].indices.contains(n) { return spans[f][h][n] }
        return InvisibleMarkers.mark(line.text).spans
    }

    /// Every file's lines through the model's highlighter (`DiffModel.highlighted`, markers included), split back per hunk; a
    /// line past the highlighter's cap keeps its markers only.
    nonisolated static func highlight(_ diff: DiffModel) -> [[[[CodeSpan]]]] {
        diff.files.indices.map { f in
            let rows = diff.highlighted(file: f)
            var next = 0
            return diff.files[f].hunks.map { hunk in
                hunk.lines.map { line -> [CodeSpan] in
                    defer { next += 1 }
                    return next < rows.count ? rows[next] : InvisibleMarkers.mark(line.text).spans
                }
            }
        }
    }
}

/// One diff line: old and new numbers (mono `text2`), the sign, the code; added `success` 15 %, deleted `danger` 15 %.
struct DiffLineRow: View {
    let line: DiffLine
    let spans: [CodeSpan]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            number(line.oldNo)
            number(line.newNo)
            Text(verbatim: sign)
                .font(BrahmaTheme.mono)
                .foregroundStyle(signColor)
                .frame(width: 16)
            RefStyle.text(spans)
                .font(BrahmaTheme.mono)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
            Spacer(minLength: BrahmaTheme.spaceL)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint)
    }

    private func number(_ n: Int?) -> some View {
        Text(verbatim: n.map(String.init) ?? "")
            .font(BrahmaTheme.monoSmall)
            .foregroundStyle(BrahmaTheme.text2)
            .frame(width: 40, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var sign: String {
        switch line.kind {
        case .add: "+"
        case .del: "\u{2212}"
        case .ctx: " "
        }
    }

    private var signColor: Color {
        switch line.kind {
        case .add: BrahmaTheme.success
        case .del: BrahmaTheme.danger
        case .ctx: BrahmaTheme.text2
        }
    }

    private var tint: Color {
        switch line.kind {
        case .add: BrahmaTheme.success.opacity(0.15)
        case .del: BrahmaTheme.danger.opacity(0.15)
        case .ctx: .clear
        }
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
