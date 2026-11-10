import SwiftUI

/// The height of the `AGENT-BUILT CONTENT` strip.
let agentBuiltStripHeight: CGFloat = 18

/// Wraps every web body of the preview: a 1 px `warning` border and an 18 pt top strip reading
/// `AGENT-BUILT CONTENT · <builtBy>`, drawn by the app outside the web view, so the page cannot cover or restyle it.
/// Secure fields, approvals and Inbox UI are never placed inside this frame.
struct AgentBuiltFrame<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(BrahmaTheme.warning)
                Text(verbatim: "AGENT-BUILT CONTENT · " + label)
                    .font(BrahmaTheme.monoTiny)
                    .tracking(BrahmaTheme.labelTracking)
                    .foregroundStyle(BrahmaTheme.warning)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, BrahmaTheme.spaceS)
            .frame(maxWidth: .infinity, minHeight: agentBuiltStripHeight, maxHeight: agentBuiltStripHeight)
            .background(BrahmaTheme.warning.opacity(0.12))
            .accessibilityLabel(Text(verbatim: "Agent-built content, by " + label))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(Rectangle().strokeBorder(BrahmaTheme.warning, lineWidth: 1))
    }
}
