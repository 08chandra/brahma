import SwiftUI
import BrahmaAppModel

/// Shown above the detail pane when the engine is not simply running in this app.
struct EngineBanner: View {
    let engine: EngineHost?

    var body: some View {
        if let engine {
            switch engine.status {
            case .external:
                bar(color: .blue, icon: "terminal") {
                    Text(verbatim: "Engine running in terminal (brahma run). Brahma shows live state and your messages still go through; scheduling happens in the terminal. Brahma takes over when it stops.")
                }
            case .failed(let message):
                bar(color: .orange, icon: "exclamationmark.triangle") {
                    Text(verbatim: message)
                    Spacer(minLength: 12)
                    Button("Retry") {
                        Task { @MainActor in await engine.start(tools: EngineSetup.resolveTools()) }
                    }
                }
            case .stopping:
                bar(color: .secondary, icon: nil) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: "Stopping agents…")
                }
            case .starting, .embedded, .stopped:
                EmptyView()
            }
        }
    }

    private func bar<Content: View>(color: Color, icon: String?, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).foregroundStyle(color) }
            content()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}
