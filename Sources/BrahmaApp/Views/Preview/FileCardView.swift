import SwiftUI
import AppKit
import BrahmaCore
import BrahmaAppModel

/// A file the app does not render (Plan 4a Task 9a, A6): CAD, and models too large to read in process. A `Panel` with the
/// name, kind (`CAD`), size and who published it, and "Open in…", which hands the owner's default app a vetted copy of the
/// file through `OpenInHandoff` (Task 9c): the entry is opened without following links at click time, refused when it is a
/// link, a bundle, executable or of a launch-capable type, and otherwise copied from that descriptor into the engine-only
/// `<home>/run/open-in` folder; `NSWorkspace` only ever sees the copy. A refusal shows under the button, engine-written.
/// The name is agent-controlled (`Text(verbatim:)` through `KeyValueGrid`).
struct FileCardView: View {
    let name: String
    let kind: ArtifactKind
    let bytes: Int64
    let publishedBy: String
    let url: URL
    /// Why the last "Open in…" was refused (engine-written), or nil.
    @State private var refusal: String?
    @State private var opening = false

    var body: some View {
        Panel(title: "File") {
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                KeyValueGrid(rows: [
                    KeyValueRow(label: "Name", value: name, mono: true),
                    KeyValueRow(label: "Kind", value: kind.rawValue.uppercased(), mono: true),
                    KeyValueRow(label: "Size", value: ByteCount.string(bytes), mono: true),
                    KeyValueRow(label: "Published by", value: publishedBy.isEmpty ? "—" : publishedBy),
                ])
                HStack(spacing: BrahmaTheme.spaceS) {
                    Button { openInDefaultApp() } label: {
                        Label("Open in…", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.brahma)
                    .disabled(opening)
                    .help("Open a vetted copy with the default app for this file")
                    Text(verbatim: "Not rendered here")
                        .font(BrahmaTheme.monoTiny)
                        .foregroundStyle(BrahmaTheme.text2)
                    Spacer(minLength: 0)
                }
                if let refusal {
                    Text(verbatim: refusal)
                        .font(BrahmaTheme.monoTiny)
                        .foregroundStyle(BrahmaTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(BrahmaTheme.spaceL)
        .frame(maxWidth: 420, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The copy is made off the main actor; `NSWorkspace` is given the copy on it. The data home is the process's
    /// (`BrahmaPaths.fromEnvironment()`, as the app's boot resolved it).
    private func openInDefaultApp() {
        guard !opening else { return }
        opening = true
        refusal = nil
        let folder = OpenInHandoff.folder(paths: BrahmaPaths.fromEnvironment())
        let url = self.url
        Task { @MainActor in
            let result = await OpenInHandoff.openCopy(url, into: folder) { NSWorkspace.shared.open($0) }
            if case .failure(let why) = result { refusal = OpenInHandoff.message(why) }
            opening = false
        }
    }
}
