import SwiftUI

struct StartupErrorView: View {
    let error: BootError

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text(verbatim: "Brahma couldn't open its database at \(error.path).")
                .font(.headline)
            Text(verbatim: error.message)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
