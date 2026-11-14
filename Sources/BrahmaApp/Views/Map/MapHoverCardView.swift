import SwiftUI
import BrahmaAppModel

/// The card shown beside the pointer over an agent. Every string comes from the cleaned `MapHoverCard` (`MapModel.hoverCard`)
/// and is drawn with `Text(verbatim:)`. The card never takes the pointer, so the map keeps its hover.
struct MapHoverCardView: View {
    static let width: CGFloat = 240
    let card: MapHoverCard

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: card.handle)
                    .font(BrahmaTheme.bodyStrong)
                    .foregroundStyle(BrahmaTheme.text0)
                    .lineLimit(1)
                Text(verbatim: card.role)
                    .font(BrahmaTheme.body)
                    .foregroundStyle(BrahmaTheme.text1)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                StatusChip(label: card.stateLabel, color: BrahmaTheme.statusColor(for: card.state), pulse: card.state == .running)
                if let trust = card.trust {
                    MonoChip(text: trust.label, color: Self.trustColor(tier: trust.tier), fill: BrahmaTheme.bg4)
                        .help(Text(verbatim: trust.title))
                }
            }
            KeyValueGrid(rows: rows)
        }
        .padding(BrahmaTheme.spaceS)
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.bg3))
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.line, lineWidth: 1))
        .allowsHitTesting(false)
    }

    /// Plan 3b's tokens: tier 0 `warning`, 1 `text1`, 2 `success`, 3 `accent`.
    static func trustColor(tier: Int) -> Color {
        switch tier {
        case ...0: BrahmaTheme.warning
        case 1: BrahmaTheme.text1
        case 2: BrahmaTheme.success
        default: BrahmaTheme.accent
        }
    }

    private var rows: [KeyValueRow] {
        func text(_ s: String?) -> String { s.flatMap { $0.isEmpty ? nil : $0 } ?? "—" }
        var rows = [
            KeyValueRow(label: "Team", value: text(card.team)),
            KeyValueRow(label: "Manager", value: text(card.manager), mono: true),
            KeyValueRow(label: "Reports", value: "\(card.reports)", mono: true),
            KeyValueRow(label: "Item", value: text(card.item), mono: true),
            KeyValueRow(label: "Blocker", value: text(card.blocker),
                        valueColor: card.blocker.isEmpty ? BrahmaTheme.text0 : BrahmaTheme.blocked),
        ]
        if let meter = card.meter { rows.append(KeyValueRow(label: "Meter", value: meter.line, mono: true)) }
        if !card.perks.isEmpty { rows.append(KeyValueRow(label: "Perks", value: card.perks.joined(separator: ", "))) }
        return rows
    }
}
