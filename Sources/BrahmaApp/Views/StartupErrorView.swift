import SwiftUI
import BrahmaCore

struct StartupErrorView: View {
    let error: BootError
    @State private var phase: Phase = .idle
    @State private var confirming = false

    private enum Phase: Equatable {
        case idle, working
        case restored(String)
        case failed(String)
    }

    var body: some View {
        Panel(title: error.integrityProblem == nil ? "Startup error" : "DATABASE CHECK FAILED") {
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                HStack(spacing: BrahmaTheme.spaceS) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(error.integrityProblem == nil ? BrahmaTheme.warning : BrahmaTheme.danger)
                    Text(verbatim: error.integrityProblem == nil
                         ? "Brahma couldn't open its database."
                         : "Brahma's database failed its integrity check and was not opened.")
                        .font(BrahmaTheme.bodyLarge.weight(.semibold))
                        .foregroundStyle(BrahmaTheme.text0)
                }
                KeyValueGrid(rows: [
                    KeyValueRow(label: "Path", value: error.path, mono: true),
                    KeyValueRow(label: error.integrityProblem == nil ? "Error" : "Check", value: error.integrityProblem ?? error.message,
                                mono: true, valueColor: BrahmaTheme.text1),
                ])
                switch phase {
                case .idle, .working: EmptyView()
                case .restored(let name):
                    StatusChip(label: "restored", color: BrahmaTheme.success)
                    Text(verbatim: "Restored from \(name). Your previous database was kept next to it as brahma.sqlite.pre-restore-…")
                        .font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text1)
                case .failed(let message):
                    StatusChip(label: "restore failed", color: BrahmaTheme.danger)
                    Text(verbatim: message).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text1)
                }
                HStack {
                    Spacer()
                    if error.integrityProblem != nil, case .restored = phase {
                        Button("Relaunch") { relaunch() }
                            .buttonStyle(.brahmaPrimary)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        if error.integrityProblem != nil {
                            Button("Restore latest good backup…") { confirming = true }
                                .buttonStyle(.brahmaPrimary)
                                .disabled(phase == .working)
                        }
                        Button("Quit") { NSApp.terminate(nil) }
                            .buttonStyle(error.integrityProblem == nil ? .brahmaPrimary : .brahma)
                            .keyboardShortcut(error.integrityProblem == nil ? .defaultAction : .cancelAction)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 560)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrahmaTheme.bg0)
        .confirmationDialog("Restore the latest good backup?", isPresented: $confirming) {
            Button("Restore") { restore() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: "The newest snapshot that passes its integrity check replaces the database. The current file is kept next to it. Work done after that snapshot is lost from the database; git repositories are not touched.")
        }
    }

    private func restore() {
        phase = .working
        let paths = BrahmaPaths.fromEnvironment()
        Task {
            let result: Phase = await Task.detached {
                let service = BackupService(paths: paths)
                guard let latest = service.latestGood() else { return .failed("No snapshot passes its integrity check.") }
                // B9 (Ruling S-c1, S5 fix 3): the store never opened, so nothing installed the tools the restore's git needs.
                _ = service.installRestoreTools(paths: paths, snapshot: latest.url)
                do {
                    try service.restore(try service.planRestore(snapshot: latest.url))
                    return .restored(latest.name)
                } catch { return .failed("\(error)") }
            }.value
            phase = result
        }
    }

    /// Starts a fresh copy of the app and quits this one.
    private func relaunch() {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", Bundle.main.bundleURL.path]
        try? open.run()
        NSApp.terminate(nil)
    }
}
