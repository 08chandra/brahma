import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// A file or a line range (collab design §1.3): line numbers in mono `text2`, the shared range on `bg4` with an accent left bar
/// and scrolled into view, mono spans colored by token kind (`CodeHighlighter`), and hidden characters (`⟦U+202E⟧`) as `warning`
/// markers. The spans are the model's (the bytes came through `Store.renderRef`, gated); every span is `Text(verbatim:)` and
/// nothing in the code is clickable. The header (path, branch, rev and chips) is `RefBodyView`'s `RefHeaderView`.
struct CodeView: View {
    let lines: [[CodeSpan]]
    var firstLine = 1
    var highlight: LineRange?
    var hasHidden = false

    private var gutterWidth: CGFloat {
        let digits = String(firstLine + max(lines.count - 1, 0)).count
        return CGFloat(max(digits, 2)) * 7.5 + 6
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasHidden || highlight != nil { strip; Hairline() }
            GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, spans in
                            row(number: firstLine + i, spans: spans).id(firstLine + i)
                        }
                    }
                    .padding(.vertical, BrahmaTheme.spaceXS)
                    // Pinned to the leading edge (a two-axis scroll view centers narrower content), at least the pane wide.
                    .frame(minWidth: geo.size.width, alignment: .leading)
                }
                .onAppear { scrollToRange(proxy) }
                .onChange(of: highlight) { _, _ in scrollToRange(proxy) }
            }
            }
        }
        .background(BrahmaTheme.bg0)
    }

    /// The range and the hidden-characters warning above the code.
    private var strip: some View {
        HStack(spacing: BrahmaTheme.spaceS) {
            if let highlight {
                Text(verbatim: highlight.start == highlight.end ? "LINE \(highlight.start)" : "LINES \(highlight.start)–\(highlight.end)")
                    .font(BrahmaTheme.monoTiny)
                    .foregroundStyle(BrahmaTheme.accent)
            }
            if hasHidden { WarningChip(label: "Hidden characters") }
            Spacer(minLength: 0)
            Text(verbatim: "\(lines.count) LINES").font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2)
        }
        .padding(.horizontal, BrahmaTheme.spaceS)
        .frame(height: BrahmaTheme.denseRowHeight)
        .background(BrahmaTheme.bg2)
    }

    private func row(number: Int, spans: [CodeSpan]) -> some View {
        let inRange = highlight.map { number >= $0.start && number <= $0.end } ?? false
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: "\(number)")
                .font(BrahmaTheme.monoSmall)
                .foregroundStyle(inRange ? BrahmaTheme.text1 : BrahmaTheme.text2)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, BrahmaTheme.spaceS)
            RefStyle.text(spans)
                .font(BrahmaTheme.mono)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
            Spacer(minLength: BrahmaTheme.spaceL)
        }
        .padding(.vertical, 1)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(inRange ? BrahmaTheme.bg4 : Color.clear)
        .overlay(alignment: .leading) {
            if inRange { Rectangle().fill(BrahmaTheme.accent).frame(width: 2) }
        }
    }

    private func scrollToRange(_ proxy: ScrollViewProxy) {
        guard let highlight, highlight.start > firstLine + 3 else { return }
        // A few lines of context above the range.
        proxy.scrollTo(max(firstLine, highlight.start - 3), anchor: .top)
    }
}
