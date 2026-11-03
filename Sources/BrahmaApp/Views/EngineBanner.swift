import SwiftUI
import BrahmaAppModel

/// Shown above the detail pane when the engine is not simply running in this app.
struct EngineBanner: View {
    let engine: EngineHost?
    var notice: String?
    /// The engine hold (offline, logged out, CLI changed, disk low), in `danger`.
    var hold: String?
    /// An account or CLI hold has something to retry.
    var canRetryHold = false
    var retryHold: () -> Void = {}
    /// Agents are paused until the secrets load; the button asks the owner (a Keychain prompt may follow).
    var secrets: String?
    var loadSecrets: () -> Void = {}
    /// "Sandbox check failed or pending for claude <v> — see Inbox", while that engine alert waits in the Inbox.
    var sandbox: String?
    var openInbox: () -> Void = {}
    /// The owner's emergency stop (Task 7c), in `danger`, with Resume.
    var stopped: String?
    var resume: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            if let stopped {
                bar(color: BrahmaTheme.danger, icon: "stop.circle.fill") {
                    Text(verbatim: stopped)
                    Spacer(minLength: 12)
                    Button("Resume", action: resume).buttonStyle(.brahmaPrimary)
                }
            }
            if let notice {
                bar(color: BrahmaTheme.warning, icon: "exclamationmark.triangle.fill") { Text(verbatim: notice) }
            }
            if let sandbox {
                bar(color: BrahmaTheme.danger, icon: "shield.lefthalf.filled") {
                    Text(verbatim: sandbox)
                    Spacer(minLength: 12)
                    Button("Open Inbox", action: openInbox).buttonStyle(.brahma)
                }
            }
            if let secrets {
                bar(color: BrahmaTheme.danger, icon: "key.fill") {
                    Text(verbatim: secrets)
                    Spacer(minLength: 12)
                    Button("Load secrets", action: loadSecrets).buttonStyle(.brahma)
                }
            }
            if let hold {
                bar(color: BrahmaTheme.danger, icon: "exclamationmark.octagon.fill") {
                    Text(verbatim: hold)
                    Spacer(minLength: 12)
                    if canRetryHold { Button("Retry", action: retryHold).buttonStyle(.brahma) }
                }
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
