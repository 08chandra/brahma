import SwiftUI
import AppKit

// Controls: dense table rows, buttons, fields, avatar, map grid, split divider.

// MARK: - Tables

/// Dense table row: 22–24 pt, zebra striping (`bg2` / #1D252E), hover `bg3`, selected `bg4` + 2 pt accent left bar.
struct TableRowStyle: ViewModifier {
    let index: Int
    let selected: Bool
    var height: CGFloat = BrahmaTheme.rowHeight
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, BrahmaTheme.spaceS)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .background(background)
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(BrahmaTheme.accent).frame(width: 2) }
            }
            .contentShape(Rectangle())
            .onHover { inside in withAnimation(BrahmaTheme.fast) { hovered = inside } }
    }

    private var background: Color {
        if selected { return BrahmaTheme.bg4 }
        if hovered { return BrahmaTheme.bg3 }
        return index.isMultiple(of: 2) ? BrahmaTheme.bg2 : BrahmaTheme.zebra
    }
}

extension View {
    /// Zebra-striped dense table row; `index` picks the stripe.
    func tableRow(index: Int, selected: Bool = false, height: CGFloat = BrahmaTheme.rowHeight) -> some View {
        modifier(TableRowStyle(index: index, selected: selected, height: height))
    }
}

/// Uppercase `text2` column header label for a `bg3` table header row.
/// With `sorted` set, the header shows an arrow for the direction (`true` = ascending); with `action` it is a button.
struct ColumnHeader: View {
    let title: String
    var sorted: Bool?
    var action: (() -> Void)?

    init(_ title: String, sorted: Bool? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.sorted = sorted
        self.action = action
    }

    var body: some View {
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "Sort by \(title)"))
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 3) {
            CapsLabel(title, color: sorted == nil ? BrahmaTheme.text2 : BrahmaTheme.text0)
            if let sorted {
                Image(systemName: sorted ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(BrahmaTheme.text0)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Segmented control

/// Segmented control (LOW | BALANCED | MAX, EVERYTHING | IMPORTANT | AUTO): uppercase labels, accent for the selected one.
struct Segmented<Value: Hashable>: View {
    let options: [(Value, String)]
    let selection: Value
    let label: String
    let select: (Value) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, entry in
                let (value, title) = entry
                let selected = value == selection
                if index > 0 { Hairline(axis: .vertical, color: BrahmaTheme.lineStrong) }
                Button { if !selected { select(value) } } label: {
                    Text(verbatim: title.uppercased())
                        .font(BrahmaTheme.label)
                        .tracking(BrahmaTheme.labelTracking)
                        .foregroundStyle(selected ? Color.white : BrahmaTheme.text1)
                        .padding(.horizontal, 9)
                        .frame(height: 20)
                        .background(selected ? BrahmaTheme.accent : BrahmaTheme.bg3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: title))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .fixedSize()
        .clipShape(RoundedRectangle(cornerRadius: BrahmaTheme.radius))
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.lineStrong, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: label))
        .help(label)
    }
}

// MARK: - Buttons and fields

/// Small bordered button; `primary` = accent fill.
struct BrahmaButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, primary: primary)
    }

    private struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        let primary: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 11, weight: .medium))
                .labelStyle(CompactLabelStyle())
                .foregroundStyle(primary ? Color.white : BrahmaTheme.text0)
                .padding(.horizontal, 10)
                .frame(minHeight: 22)
                .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius)
                    .strokeBorder(primary ? BrahmaTheme.accent : BrahmaTheme.lineStrong, lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { inside in withAnimation(BrahmaTheme.fast) { hovered = inside } }
        }

        private var fill: Color {
            if primary { return configuration.isPressed ? BrahmaTheme.accentDim : BrahmaTheme.accent }
            if configuration.isPressed { return BrahmaTheme.bg4 }
            return hovered && isEnabled ? BrahmaTheme.bg4 : BrahmaTheme.bg3
        }
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 9, weight: .bold))
            configuration.title
        }
    }
}

extension ButtonStyle where Self == BrahmaButtonStyle {
    static var brahma: BrahmaButtonStyle { BrahmaButtonStyle() }
    static var brahmaPrimary: BrahmaButtonStyle { BrahmaButtonStyle(primary: true) }
}

/// Bordered `bg2` input field (apply to a `TextField`).
struct FieldStyle: ViewModifier {
    var focused = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(BrahmaTheme.bodyLarge)
            .foregroundStyle(BrahmaTheme.text0)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.bg2))
            .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius)
                .strokeBorder(focused ? BrahmaTheme.accent : BrahmaTheme.lineStrong, lineWidth: 1))
    }
}

extension View {
    func brahmaField(focused: Bool = false) -> some View { modifier(FieldStyle(focused: focused)) }
}

// MARK: - Avatar and map grid

/// 20 pt monogram square, colored by role family.
struct MonogramAvatar: View {
    let monogram: String
    let color: Color
    var size: CGFloat = BrahmaTheme.avatar

    var body: some View {
        Text(verbatim: monogram)
            .font(.system(size: size * 0.45, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(color.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(color.opacity(0.6), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// Map placeholder background: `bg0` with `#18202A` grid lines every 24 pt.
struct GridBackground: View {
    var spacing: CGFloat = 24

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width { path.addRect(CGRect(x: x, y: 0, width: 1, height: size.height)); x += spacing }
            var y: CGFloat = 0
            while y <= size.height { path.addRect(CGRect(x: 0, y: y, width: size.width, height: 1)); y += spacing }
            context.fill(path, with: .color(BrahmaTheme.mapGrid))
        }
        .background(BrahmaTheme.bg0)
    }
}

// MARK: - Split divider

/// 1 px `line` divider with a wider invisible grab area; dragging resizes the pane before it
/// (`axis: .vertical` = side-by-side panes, `.horizontal` = stacked panes).
struct SplitDivider: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    var axis: Axis = .vertical
    @State private var start: CGFloat?

    init(width: Binding<CGFloat>, range: ClosedRange<CGFloat>, axis: Axis = .vertical) {
        _width = width
        self.range = range
        self.axis = axis
    }

    var body: some View {
        Hairline(axis: axis)
            .overlay {
                Color.clear
                    .frame(width: axis == .vertical ? 7 : nil, height: axis == .horizontal ? 7 : nil)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            let origin = start ?? width
                            start = origin
                            let delta = axis == .vertical ? drag.translation.width : drag.translation.height
                            width = min(range.upperBound, max(range.lowerBound, origin + delta))
                        }
                        .onEnded { _ in start = nil })
            }
            .zIndex(1)
            .accessibilityHidden(true)
    }
}
