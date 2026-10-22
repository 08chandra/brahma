import SwiftUI
import BrahmaAppModel

/// Shown above the detail pane when the engine is not simply running in this app.
struct EngineBanner: View {
    let engine: EngineHost?
    var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            if let notice {
                bar(color: BrahmaTheme.warning, icon: "exclamationmark.triangle.fill") { Text(verbatim: notice) }
            }
            engineBar
        }
    }

    @ViewBuilder private var engineBar: some View {
        if let engine {
            switch engine.status {
            case .external:
                bar(color: BrahmaTheme.ready, icon: "terminal") {
                    Text(verbatim: "Engine running in terminal (brahma run). Brahma shows live state and your messages still go through; scheduling happens in the terminal. Brahma takes over when it stops.")
                }
            case .failed(let message):
                bar(color: BrahmaTheme.warning, icon: "exclamationmark.triangle.fill") {
                    Text(verbatim: message)
                    Spacer(minLength: 12)
                    Button("Retry") {
                        Task { @MainActor in await engine.start(tools: EngineSetup.resolveTools()) }
                    }
                    .buttonStyle(.brahma)
                }
            case .stopping:
                bar(color: BrahmaTheme.text1, icon: nil) {
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
            if let icon { Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color) }
            content()
        }
        .font(BrahmaTheme.body)
        .foregroundStyle(BrahmaTheme.text0)
        .padding(.horizontal, BrahmaTheme.spaceM)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: BrahmaTheme.panelHeaderHeight, alignment: .leading)
        .background(color.opacity(0.15))
        .background(BrahmaTheme.bg0)
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 2) }
        .overlay(alignment: .bottom) { Hairline() }
    }
}
