import SwiftUI
import AppKit
import BrahmaCore

/// A file the app does not render (Plan 4a Task 9a, A6): CAD, and models too large to read in process. A `Panel` with the
/// name, kind (`CAD`), size and who published it, and "Open in…", which hands the file to the owner's default app through
/// `NSWorkspace`. Nothing of the file is read here. The name is agent-controlled (`Text(verbatim:)` through `KeyValueGrid`).
struct FileCardView: View {
    let name: String
    let kind: ArtifactKind
    let bytes: Int64
    let publishedBy: String
    let url: URL

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
                    Button { NSWorkspace.shared.open(url) } label: {
                        Label("Open in…", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.brahma)
                    .help("Open with the default app for this file")
                    Text(verbatim: "Not rendered here")
                        .font(BrahmaTheme.monoTiny)
                        .foregroundStyle(BrahmaTheme.text2)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(BrahmaTheme.spaceL)
        .frame(maxWidth: 420, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
