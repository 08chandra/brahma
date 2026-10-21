import SwiftUI
import BrahmaCore
import BrahmaAppModel

// Reusable ops-console components. Every data value is taken as `String` and rendered with
// `Text(verbatim:)`: agent-controlled text never goes through LocalizedStringKey or Markdown.

// MARK: - Labels

/// Small uppercase tracked label (section headers, key-value labels, column headers).
struct CapsLabel: View {
    let text: String
    var font: Font = BrahmaTheme.label
    var color: Color = BrahmaTheme.text2

    init(_ text: String, font: Font = BrahmaTheme.label, color: Color = BrahmaTheme.text2) {
        self.text = text
        self.font = font
        self.color = color
    }

    var body: some View {
        Text(verbatim: text.uppercased())
            .font(font)
            .tracking(BrahmaTheme.labelTracking)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// Small monospace count chip (sidebar unread counts, table counters).
struct MonoChip: View {
    let text: String
    var color: Color = BrahmaTheme.text0
    var fill: Color = BrahmaTheme.bg4

    var body: some View {
        Text(verbatim: text)
            .font(BrahmaTheme.monoTiny)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 16)
            .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(fill))
    }
}

/// 1 px hairline in `line`.
struct Hairline: View {
    var axis: Axis = .horizontal
    var color: Color = BrahmaTheme.line

    var body: some View {
        Rectangle().fill(color)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
    }
}

// MARK: - Panels

/// 28 pt `bg3` strip: uppercase tracked title on the left, tiny actions/filters on the right.
struct PanelHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    init(title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: BrahmaTheme.spaceS) {
            CapsLabel(title, font: BrahmaTheme.panelTitle, color: BrahmaTheme.text1)
            Spacer(minLength: BrahmaTheme.spaceS)
            accessory
        }
        .padding(.horizontal, BrahmaTheme.panelPadding)
        .frame(height: BrahmaTheme.panelHeaderHeight)
        .frame(maxWidth: .infinity)
        .background(BrahmaTheme.bg3)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

extension PanelHeader where Accessory == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

/// `bg2` panel with a 1 px `line` border, an optional `PanelHeader` and 8 pt inner padding.
/// Pass `padded: false` for edge-to-edge content such as tables.
struct Panel<Accessory: View, Content: View>: View {
    let title: String?
    var padded: Bool
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(title: String? = nil, padded: Bool = true,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.padded = padded
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            if let title { PanelHeader(title: title) { accessory } }
            content
                .padding(padded ? BrahmaTheme.panelPadding : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(BrahmaTheme.bg2)
        .clipShape(RoundedRectangle(cornerRadius: BrahmaTheme.radius))
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.line, lineWidth: 1))
    }
}

extension Panel where Accessory == EmptyView {
    init(title: String? = nil, padded: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(title: title, padded: padded, accessory: { EmptyView() }, content: content)
    }
}

// MARK: - Status

/// 18 pt chip: 1 px status-color border, 15% fill, uppercase 10 pt label. Only `running` pulses.
struct StatusChip: View {
    let label: String
    let color: Color
    var pulse: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(label: String, color: Color, pulse: Bool = false) {
        self.label = label
        self.color = color
        self.pulse = pulse
    }

    init(state: AgentState) {
        self.init(label: state.rawValue, color: BrahmaTheme.statusColor(for: state), pulse: state == .running)
    }

    var body: some View {
        HStack(spacing: 5) {
            dot
            Text(verbatim: label.uppercased())
                .font(BrahmaTheme.label)
                .tracking(BrahmaTheme.labelTracking)
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(height: BrahmaTheme.chipHeight)
        .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(color.opacity(0.15)))
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(color, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var dot: some View {
        let circle = Circle().fill(color).frame(width: 5, height: 5)
        if pulse && !reduceMotion {
            circle.phaseAnimator([false, true]) { view, dim in
                view.opacity(dim ? 0.3 : 1)
            } animation: { dim in
                dim ? .easeIn(duration: 0.2).delay(1.2) : .easeOut(duration: 0.2)
            }
        } else {
            circle
        }
    }
}

/// `● 12 RUNNING  ● 30 READY  ● 2 BLOCKED  ● 1 SLEEPING` (killed agents are not counted, as in `StateCounts.line`).
struct CountChips: View {
    let counts: StateCounts

    var body: some View {
        HStack(spacing: BrahmaTheme.spaceM) {
            item(counts.running, .running)
            item(counts.ready, .ready)
            item(counts.blocked, .blocked)
            item(counts.sleeping, .sleeping)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: counts.line))
    }

    private func item(_ n: Int, _ state: AgentState) -> some View {
        let color = BrahmaTheme.statusColor(for: state)
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(verbatim: "\(n)").font(BrahmaTheme.mono.weight(.semibold)).foregroundStyle(n > 0 ? color : BrahmaTheme.text2)
            CapsLabel(state.rawValue, color: BrahmaTheme.text1)
        }
        .fixedSize()
    }
}

// MARK: - Key-value grid

struct KeyValueRow: Identifiable {
    var label: String
    var value: String
    var mono: Bool = false
    var valueColor: Color = BrahmaTheme.text0
    var id: String { label }
}

/// Inspector grid: labels `text2` uppercase 10 pt, values `text0` (mono for ids and numbers).
struct KeyValueGrid: View {
    let rows: [KeyValueRow]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: BrahmaTheme.spaceM, verticalSpacing: 6) {
            ForEach(rows) { row in
                GridRow {
                    CapsLabel(row.label).gridColumnAlignment(.leading)
                    Text(verbatim: row.value)
                        .font(row.mono ? BrahmaTheme.mono : BrahmaTheme.body)
                        .foregroundStyle(row.valueColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Empty state

/// Small mono `text2` uppercase text ("NO ACTIVE TURNS"), not an illustration.
struct MonoEmptyState: View {
    let title: String
    var detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(verbatim: title.uppercased())
                .font(BrahmaTheme.monoSmall.weight(.medium))
                .tracking(BrahmaTheme.labelTracking)
                .foregroundStyle(BrahmaTheme.text2)
            if let detail {
                Text(verbatim: detail)
                    .font(BrahmaTheme.monoSmall)
                    .foregroundStyle(BrahmaTheme.text2.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(BrahmaTheme.spaceL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
