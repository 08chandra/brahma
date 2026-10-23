import SwiftUI
import BrahmaAppModel

/// The org a new company would get: one mono line per seat, vacant seats dimmed and marked, with the seat counts above.
struct OrgPreviewView: View {
    let preview: OrgPreview?
    let agentCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
            CapsLabel("Org preview")
            if let preview {
                Text(verbatim: "\(preview.total) in the shape · \(preview.seated) hired now · \(preview.vacant) vacant until work calls for them")
                    .font(BrahmaTheme.monoSmall)
                    .foregroundStyle(BrahmaTheme.text1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(preview.lines.enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line)
                                .font(BrahmaTheme.monoSmall)
                                .foregroundStyle(line.localizedCaseInsensitiveContains("vacant") ? BrahmaTheme.text2 : BrahmaTheme.text0)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(BrahmaTheme.spaceS)
                }
                .frame(height: 150)
                .background(BrahmaTheme.bg0)
                .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.line, lineWidth: 1))
            } else {
                Text(verbatim: agentCount == 0 ? "An empty company: hire agents one at a time later." : "No preview for this size.")
                    .font(BrahmaTheme.monoSmall)
                    .foregroundStyle(BrahmaTheme.text2)
            }
        }
    }
}
