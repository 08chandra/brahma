import SwiftUI
import BrahmaAppModel

/// The team band's card (top right of the map): title, lead, counts, members and open seats. Strings come from the cleaned
/// `MapTeamCard`; `Text(verbatim:)` throughout.
struct MapTeamCardView: View {
    static let width: CGFloat = 260
    let card: MapTeamCard
    let onSelect: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            HStack(alignment: .firstTextBaseline, spacing: BrahmaTheme.spaceS) {
                CapsLabel(card.title, font: BrahmaTheme.panelTitle, color: BrahmaTheme.text0)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(BrahmaTheme.text1)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel(Text("Close team card"))
            }
            HStack(spacing: 6) {
                CapsLabel("Lead")
                Text(verbatim: card.lead).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text0).lineLimit(1)
            }
            CountChips(counts: card.counts)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(card.members.enumerated()), id: \.element.id) { index, member in
                        Button { onSelect(member.id) } label: {
                            HStack(spacing: 6) {
                                Circle().fill(BrahmaTheme.statusColor(for: member.state)).frame(width: 6, height: 6)
                                Text(verbatim: member.handle).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text0).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(verbatim: member.label).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2).lineLimit(1)
                            }
                            .tableRow(index: index, height: BrahmaTheme.denseRowHeight)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: member.handle + ", " + member.label))
                    }
                }
            }
            .frame(maxHeight: 176)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                CapsLabel("Vacancies")
                MonoChip(text: "\(card.vacancies)", color: card.vacancies > 0 ? BrahmaTheme.warning : BrahmaTheme.text1)
            }
        }
        .padding(BrahmaTheme.spaceS)
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.bg3))
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.line, lineWidth: 1))
    }
}
