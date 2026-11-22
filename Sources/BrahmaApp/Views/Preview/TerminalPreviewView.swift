import SwiftUI
import BrahmaAppModel

/// A ran CLI demo (Plan 4a Task 9a): its sealed output on `bg0` in mono, styled only by the basic SGR colors `AnsiText`
/// keeps, under a `monoTiny` footer (`exit <n> · <sha7>`, engine-written). The output is agent-controlled: every span is
/// `Text(verbatim:)`, and the parse runs under `RendererCaps.parse` like every other renderer's. New output keeps the tail
/// in view.
struct TerminalPreviewView: View {
    let lines: [String]
    let footer: String

    var body: some View {
        VStack(spacing: 0) {
            AnsiLinesView(lines: lines, emptyTitle: "NO OUTPUT", followsTail: true)
            Hairline()
            HStack(spacing: BrahmaTheme.spaceS) {
                Text(verbatim: footer)
                    .font(BrahmaTheme.monoTiny)
                    .foregroundStyle(BrahmaTheme.text2)
                    .lineLimit(1)
                Spacer(minLength: 0)
                MonoChip(text: "\(lines.count)", color: BrahmaTheme.text2, fill: BrahmaTheme.bg3)
                    .help("Lines of output kept")
            }
            .padding(.horizontal, BrahmaTheme.spaceS)
            .frame(height: BrahmaTheme.denseRowHeight)
            .background(BrahmaTheme.bg2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ANSI lines

/// Terminal-style lines (a demo's output, a backend's log tail) rendered through `AnsiText`: only SGR bold and the 16
/// basic colors apply, mapped to theme tokens (Global Constraints "Color tokens"); everything else in the text is dropped
/// by the parser. The parse runs off-main under `RendererCaps.parse`; past its timeout the body says so instead.
struct AnsiLinesView: View {
    let lines: [String]
    var emptyTitle = "NO OUTPUT"
    /// Scroll to the last line on appear and whenever the tail changes.
    var followsTail = false
    @State private var parsed: Parsed?

    private enum Parsed: Equatable {
        case lines([[AnsiSpan]])
        case timedOut
    }

    var body: some View {
        Group {
            switch parsed {
            case nil:
                Color.clear
            case .timedOut?:
                MonoEmptyState(PreviewBodies.cantShowTitle, detail: PreviewBodies.tookTooLong)
            case .lines(let rows)? where rows.isEmpty:
                MonoEmptyState(emptyTitle)
            case .lines(let rows)?:
                ScrollViewReader { proxy in
                    // Vertical only: a long line wraps (it is already cut at 4 KB), so the output stays at the left edge.
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, spans in
                                Self.line(spans)
                                    .font(BrahmaTheme.monoSmall)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Color.clear.frame(height: 1).id("ansi-end")
                        }
                        .padding(BrahmaTheme.spaceS)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onAppear { if followsTail { proxy.scrollTo("ansi-end", anchor: .bottom) } }
                    .onChange(of: rows.count) { _, _ in if followsTail { proxy.scrollTo("ansi-end", anchor: .bottom) } }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrahmaTheme.bg0)
        .task(id: lines) {
            let text = lines.joined(separator: "\n")
            do {
                let rows = try await RendererCaps.parse { AnsiText.parse(text) }
                parsed = .lines(rows)
            } catch is CancellationError {
                return
            } catch {
                parsed = .timedOut
            }
        }
    }

    /// One line as a single `Text`: the spans concatenated, each in its token color, bold where the SGR said so. An empty
    /// line keeps its height.
    static func line(_ spans: [AnsiSpan]) -> Text {
        guard !spans.isEmpty else { return Text(verbatim: " ") }
        return spans.reduce(Text(verbatim: "")) { acc, span in
            var t = Text(verbatim: span.text).foregroundColor(color(span.color))
            if span.bold { t = t.bold() }
            return acc + t
        }
    }

    /// The token map: red `danger`, green `success`, yellow `warning`, blue `ready`, magenta `series[3]`, cyan `series[4]`,
    /// white and no color `text0`, black and bright black `text2`. Bright variants share their base color's token.
    static func color(_ c: AnsiColor?) -> Color {
        switch c {
        case nil, .white?, .brightWhite?: BrahmaTheme.text0
        case .black?, .brightBlack?: BrahmaTheme.text2
        case .red?, .brightRed?: BrahmaTheme.danger
        case .green?, .brightGreen?: BrahmaTheme.success
        case .yellow?, .brightYellow?: BrahmaTheme.warning
        case .blue?, .brightBlue?: BrahmaTheme.ready
        case .magenta?, .brightMagenta?: BrahmaTheme.series[3]
        case .cyan?, .brightCyan?: BrahmaTheme.series[4]
        }
    }
}
