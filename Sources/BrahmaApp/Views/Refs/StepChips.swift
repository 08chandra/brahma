import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// The steps of a multi-ref show answer (collab design §1.5): one mono chip per step (`1 PREVIEW`, `2 ARTIFACT`), the current
/// one underlined in `accent`; a click shows that step (`AppModel.step(to:)`). Under them, the answer's note strip — agent
/// text, `Text(verbatim:)` with markers — labelled `from @<handle>`.
struct StepChips: View {
    let chips: [String]
    let current: Int?
    let select: (Int) -> Void
    /// The answer's note (gated by the model) and who wrote it, when the steps came from a show answer.
    var note: String?
    var from: String?

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
            HStack(spacing: BrahmaTheme.spaceXS) {
                CapsLabel("Steps")
                ForEach(Array(chips.enumerated()), id: \.offset) { i, title in
                    let selected = i == current
                    Button { select(i) } label: {
                        Text(verbatim: title)
                            .font(BrahmaTheme.monoTiny)
                            .foregroundStyle(selected ? BrahmaTheme.text0 : BrahmaTheme.text1)
                            .padding(.horizontal, 6)
                            .frame(minHeight: BrahmaTheme.chipHeight)
                            .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(selected ? BrahmaTheme.bg4 : BrahmaTheme.bg3))
                            .overlay(alignment: .bottom) {
                                if selected { Rectangle().fill(BrahmaTheme.accent).frame(height: 2) }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            if let note, !note.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: BrahmaTheme.spaceS) {
                    Text(verbatim: "from " + (from ?? "agent")).font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2)
                    RefStyle.marked(note, color: BrahmaTheme.text1).font(BrahmaTheme.body).lineLimit(2)
                }
            }
        }
        .padding(.horizontal, BrahmaTheme.spaceS)
        .padding(.vertical, BrahmaTheme.spaceXS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrahmaTheme.bg2)
    }
}
