import SwiftUI
import BrahmaAppModel

/// A native NSMenu (`.menuBarExtraStyle(.menu)`): the theme does not apply. Data lines are `Text(verbatim:)`
/// because company names are owner/agent-controlled.
struct MenuBarContent: View {
    let delegate: AppDelegate

    var body: some View {
        if let model = delegate.model {
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
                // Why nothing is running, under the company's name.
                if row.isRunning, let stall = row.stallLine { Text(verbatim: "    " + stall) }
            }
            if !summary.rows.isEmpty { Divider() }
        }
        if let model = delegate.model {
            // A native menu item: the theme does not reach an NSMenu, so there is nothing of BrahmaTheme to apply here.
            Toggle("Prevent sleep while agents run", isOn: Binding(
                get: { model.preventSleep },
                set: { value in Task { await model.setPreventSleep(value) } }))
        }
        Button("Open Brahma") { delegate.openMainWindowFromMenu() }
            .keyboardShortcut("o")
        // Same safe path as the signal handlers: terminate from a run-loop source, never a main-queue block.
        Button("Quit Brahma") { AppDelegate.requestQuit() }
            .keyboardShortcut("q")
    }
}
