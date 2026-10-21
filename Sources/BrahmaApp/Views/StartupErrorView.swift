import SwiftUI

struct StartupErrorView: View {
    let error: BootError

    var body: some View {
        Panel(title: "Startup error") {
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                HStack(spacing: BrahmaTheme.spaceS) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(BrahmaTheme.warning)
                    Text(verbatim: "Brahma couldn't open its database.")
                        .font(BrahmaTheme.bodyLarge.weight(.semibold))
                        .foregroundStyle(BrahmaTheme.text0)
                }
                KeyValueGrid(rows: [
                    KeyValueRow(label: "Path", value: error.path, mono: true),
                    KeyValueRow(label: "Error", value: error.message, mono: true, valueColor: BrahmaTheme.text1),
                ])
                HStack {
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                        .buttonStyle(.brahmaPrimary)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 560)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrahmaTheme.bg0)
    }
}
