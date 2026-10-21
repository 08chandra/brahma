import SwiftUI
import BrahmaAppModel

/// A native NSMenu (`.menuBarExtraStyle(.menu)`): the theme does not apply. Data lines are `Text(verbatim:)`
/// because company names are owner/agent-controlled.
struct MenuBarContent: View {
    let delegate: AppDelegate

    var body: some View {
        if case .success(let model) = delegate.boot {
            let summary = model.menuBar
            Text(verbatim: summary.totals)
            Text(verbatim: summary.pending)
            Text(verbatim: summary.engine)
            Divider()
            ForEach(summary.rows) { row in
                Button {
                    Task { await model.setCompanyRunning(!row.isRunning, companyId: row.id) }
                } label: {
                    Text(verbatim: row.toggleTitle)
                }
            }
            if !summary.rows.isEmpty { Divider() }
        }
        Button("Open Brahma") { delegate.openMainWindowFromMenu() }
            .keyboardShortcut("o")
        // Same safe path as the signal handlers: terminate from a run-loop source, never a main-queue block.
        Button("Quit Brahma") { AppDelegate.requestQuit() }
            .keyboardShortcut("q")
    }
}
