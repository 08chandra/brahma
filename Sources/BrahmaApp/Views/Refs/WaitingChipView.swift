import SwiftUI
import BrahmaAppModel

/// The owner's open show request (collab design §2.4): a mono chip with the model's waiting text (`ShowETA`: "@eng-1 · after its
/// current turn, ~4 min: …", gated as one string) and a cancel "×" (`AppModel.cancelShowRequest`).
struct WaitingChipView: View {
    let chip: WaitingChip
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
            Text(verbatim: chip.text)
                .font(BrahmaTheme.monoTiny)
                .foregroundStyle(BrahmaTheme.text1)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: cancel) {
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(BrahmaTheme.text2)
                    .frame(width: 12, height: 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cancel this request")
            .accessibilityLabel(Text("Cancel this request"))
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 18)
        .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.bg4))
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.lineStrong, lineWidth: 1))
        .frame(maxWidth: 360, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
