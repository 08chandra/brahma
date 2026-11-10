import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// An agent's running turn (or its latest finished one) as log-style lines (L-3). Self-contained: the agent inspector embeds
/// it under `TURN`, and Collab's agent "now" body reuses it. Every line's text is agent-controlled (`Text(verbatim:)`).
struct TurnStreamView: View {
    let stream: (turnId: String?, running: Bool, lines: [TurnStreamLine])
    @State private var endY: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    /// The tail is in view (or nearly): new lines keep it there. Scrolled up: the view stays put.
    private var pinnedToBottom: Bool { viewportHeight == 0 || endY <= viewportHeight + 40 }

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
            header
            if stream.turnId == nil {
                MonoEmptyState("NO TURNS YET").frame(minHeight: 60)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(stream.lines) { line in
                                TurnLine(line: line).id(line.id)
                            }
                            // The end marker reports where it sits in the scroll view: the stream follows the tail only while
                            // the marker is within reach (the owner has not scrolled up).
                            GeometryReader { g in
                                Color.clear.preference(key: EndOffsetKey.self, value: g.frame(in: .named("turn-stream")).maxY)
                            }
                            .frame(height: 1)
                            .id("turn-stream-end")
                        }
                        .padding(BrahmaTheme.spaceS)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .coordinateSpace(name: "turn-stream")
                    .background(GeometryReader { g in Color.clear.preference(key: ViewportHeightKey.self, value: g.size.height) })
                    .onPreferenceChange(EndOffsetKey.self) { endY = $0 }
                    .onPreferenceChange(ViewportHeightKey.self) { viewportHeight = $0 }
                    .background(BrahmaTheme.bg0)
                    .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.line, lineWidth: 1))
                    .onChange(of: stream.lines.last?.id) { _, _ in
                        if pinnedToBottom { proxy.scrollTo("turn-stream-end", anchor: .bottom) }
                    }
                    .onAppear { proxy.scrollTo("turn-stream-end", anchor: .bottom) }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: BrahmaTheme.spaceS) {
            if stream.running {
                StatusChip(label: "TURN · LIVE", color: BrahmaTheme.running, pulse: true)
            } else if let last = stream.lines.last {
                CapsLabel("TURN · \(String(last.time.prefix(5))) · \(outcome)", color: BrahmaTheme.text1)
            } else {
                CapsLabel("TURN", color: BrahmaTheme.text1)
            }
            Spacer(minLength: 0)
            if !stream.lines.isEmpty { MonoChip(text: "\(stream.lines.count)", color: BrahmaTheme.text1) }
        }
    }

    /// What the stream's last event says the turn did: "FAILED" on an error, else "FINISHED".
    private var outcome: String {
        guard let last = stream.lines.last(where: { $0.kind == .turnFinished || $0.kind == .error }) else { return "FINISHED" }
        return last.kind == .error ? "FAILED" : "FINISHED"
    }
}

private struct EndOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct TurnLine: View {
    let line: TurnStreamLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: BrahmaTheme.spaceS) {
            Text(verbatim: line.time).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
            Image(systemName: ActivityRow.symbol(line.kind))
                .font(.system(size: 9))
                .foregroundStyle(ActivityRow.color(line.kind))
                .frame(width: 12)
            Text(verbatim: line.text)
                .font(BrahmaTheme.monoSmall)
                .foregroundStyle(line.kind == .error ? BrahmaTheme.danger : BrahmaTheme.text0)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
