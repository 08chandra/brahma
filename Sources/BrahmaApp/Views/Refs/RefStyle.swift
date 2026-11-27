import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Plan C Task C7a: the shared look of every ref view — tone and token colors, code spans as one `Text`, agent text with its
/// invisible and bidi characters shown as `warning` markers, and the header chip. Every string drawn here is the model's (its
/// gated final display string); nothing is uppercased or otherwise changed after the gate (Ruling 55), and nothing becomes a link.
enum RefStyle {
    /// A model tone as a theme color (Global Constraints "Color tokens"): TAINTED/UNCOMMITTED/REDACTED `warning`, LIVE `running`,
    /// locked/PURGED/STALE `text2`, the OPENED chip `accent`.
    static func tone(_ t: PreviewTone) -> Color {
        switch t {
        case .good: BrahmaTheme.success
        case .busy: BrahmaTheme.running
        case .bad: BrahmaTheme.danger
        case .idle: BrahmaTheme.text2
        case .warn: BrahmaTheme.warning
        case .accent: BrahmaTheme.accent
        }
    }

    /// The highlighter's colors: keyword `series[0]`, string `series[1]`, number `series[2]`, type `series[3]`, comment `text2`.
    static func token(_ k: TokenKind) -> Color {
        switch k {
        case .keyword: BrahmaTheme.series[0]
        case .string: BrahmaTheme.series[1]
        case .number: BrahmaTheme.series[2]
        case .type: BrahmaTheme.series[3]
        case .comment: BrahmaTheme.text2
        case .plain: BrahmaTheme.text0
        }
    }

    /// One line of spans as a single `Text`: each span verbatim in its token color, a hidden-character marker (`⟦U+202E⟧`) in
    /// `warning`. An empty line keeps its height.
    static func text(_ spans: [CodeSpan], plain: Color? = nil) -> Text {
        guard !spans.isEmpty else { return Text(verbatim: " ") }
        return spans.reduce(Text(verbatim: "")) { acc, s in
            acc + Text(verbatim: s.text).foregroundStyle(s.hidden ? BrahmaTheme.warning : (plain ?? token(s.kind)))
        }
    }

    /// Agent-written text verbatim, every line through `InvisibleMarkers` (bidi controls, zero-width and other format characters
    /// as `warning` markers), never Markdown, never a link.
    static func marked(_ text: String, color: Color = BrahmaTheme.text0) -> Text {
        var out = Text(verbatim: "")
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if i > 0 { out = out + Text(verbatim: "\n") }
            out = out + Self.text(InvisibleMarkers.mark(String(line)).spans, plain: color)
        }
        return out
    }

    /// A ref as the owner reads it in a list: its canonical through the display pipeline (`TextGate.display`, the form the
    /// engine's gate checked when it kept the hit; C4a hits are dropped when that holds a value).
    static func shownCanonical(_ ref: WorkRef) -> String {
        if ref.kind == .commit { return "commit " + String(ref.id.prefix(7)) }
        return GlobalSearch.TextGate.display(ref.canonical, inert: false)
    }
}

/// A model chip (`RefChip`) in the status-chip look — the text exactly as the model gated it (not uppercased again); LIVE pulses.
struct RefChipView: View {
    let chip: RefChip
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color = RefStyle.tone(chip.tone)
        HStack(spacing: 5) {
            dot(color)
            Text(verbatim: chip.text)
                .font(BrahmaTheme.label)
                .tracking(BrahmaTheme.labelTracking)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .frame(height: BrahmaTheme.chipHeight)
        .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(color.opacity(0.15)))
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(color, lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func dot(_ color: Color) -> some View {
        let circle = Circle().fill(color).frame(width: 5, height: 5)
        if chip.tone == .busy && !reduceMotion {
            circle.phaseAnimator([false, true]) { view, dim in view.opacity(dim ? 0.3 : 1) } animation: { dim in
                dim ? .easeIn(duration: 0.2).delay(1.2) : .easeOut(duration: 0.2)
            }
        } else {
            circle
        }
    }
}

/// A row of model chips that wraps onto as many lines as it needs.
struct RefChipRow: View {
    let chips: [RefChip]

    var body: some View {
        FlowLayout(spacing: BrahmaTheme.spaceXS) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in RefChipView(chip: chip) }
        }
    }
}

/// Left-to-right rows that wrap (chips, filter chips, steps).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// The engine's refusal or an empty body: a small mono caption over the engine's words (verbatim, never uppercased).
struct RefUnavailableView: View {
    var caption = "UNAVAILABLE"
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Text(verbatim: caption)
                .font(BrahmaTheme.monoSmall.weight(.medium))
                .tracking(BrahmaTheme.labelTracking)
                .foregroundStyle(BrahmaTheme.text2)
            Text(verbatim: text)
                .font(BrahmaTheme.monoSmall)
                .foregroundStyle(BrahmaTheme.text2.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(BrahmaTheme.spaceL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
