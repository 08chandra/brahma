import SwiftUI
import AppKit
import BrahmaCore
import BrahmaAppModel

/// The ARTIFACTS tab (Plan 4a Task 9a): a header with the picker (`AR-<n> <title>`, the ref in mono), the kind chip, the
/// provenance chip (`BY @<handle>` or `BY YOU`) and "Reveal in Finder", then the artifact's `FileBodyView`. The body's URL
/// and root come from the model (`AppModel.fileBody(for:)`, the stat'd entry under the company's workspace); never from a
/// path built here. When the model says a pinned artifact was deleted (`artifactNotice`), that shows beside the picker,
/// with the list and picker still usable. Titles are agent-controlled (`Text(verbatim:)`).
struct ArtifactPreviewView: View {
    let artifact: Artifact
    let all: [Artifact]
    let model: AppModel

    private var fileBody: FileBody? {
        model.fileBody(for: artifact) ?? model.snapshot.preview.workspace.map { PreviewBodies.fileBody(artifact, workspace: $0) }
    }

    /// "@eng-1" for an agent's artifact, "you" for the owner's.
    private var byHandle: String {
        switch artifact.provenance {
        case .owner: "you"
        case .engine: "engine"
        case .agent(let id): "@" + (model.handles[id] ?? id)
        case .external(let detail): detail
        }
    }

    private var provenanceChip: String { artifact.provenance == .owner ? "BY YOU" : "BY " + byHandle }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if let fileBody {
                FileBodyView(body: fileBody, provenance: artifact.provenance, builtBy: byHandle, publishedBy: byHandle,
                             phoneFrameOverride: model.phoneFrameOverride[artifact.id],
                             onPhoneFrame: { model.setPhoneFrame($0, artifactId: artifact.id) })
                    .id(artifact.id)
            } else {
                MonoEmptyState("NO WORKSPACE", detail: "The company's workspace isn't known yet, so the artifact can't be opened.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    /// The full row when it fits the pane, else one without the chips' captions and the Finder button's title.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(compact: false)
            headerRow(compact: true)
        }
        .padding(.horizontal, BrahmaTheme.spaceS)
        .padding(.vertical, BrahmaTheme.spaceXS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrahmaTheme.bg2)
    }

    private func headerRow(compact: Bool) -> some View {
        HStack(spacing: BrahmaTheme.spaceS) {
            picker(compact: compact)
            StatusChip(label: artifact.kind.rawValue, color: BrahmaTheme.text2)
            StatusChip(label: provenanceChip, color: artifact.provenance == .owner ? BrahmaTheme.accent : BrahmaTheme.text1)
            if let notice = model.artifactNotice {
                WarningChip(label: AppModel.artifactDeletedTitle)
                if !compact {
                    Text(verbatim: notice).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let url = fileBody?.url {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Label("Reveal in Finder", systemImage: "folder").labelStyle(compact ? AnyLabelStyle.iconOnly : .titleAndIcon)
                }
                .buttonStyle(.brahma)
                .fixedSize()
                .help("Reveal in Finder")
            }
        }
    }

    /// The artifact list, newest first: `AR-<n>` in mono, then the title. A pick goes through `AppModel.selectArtifact`.
    private func picker(compact: Bool) -> some View {
        Menu {
            ForEach(all) { a in
                Button { model.selectArtifact(a) } label: {
                    HStack(spacing: BrahmaTheme.spaceS) {
                        if a.id == artifact.id { Image(systemName: "checkmark") }
                        Text(verbatim: a.ref).font(BrahmaTheme.mono) + Text(verbatim: "  " + a.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: artifact.ref).font(BrahmaTheme.mono.weight(.semibold)).foregroundStyle(BrahmaTheme.text0)
                if !compact {
                    Text(verbatim: artifact.title).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text0)
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: 260, alignment: .leading)
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(BrahmaTheme.text2)
            }
            .padding(.horizontal, 6)
            .frame(minHeight: BrahmaTheme.chipHeight)
            .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.bg4))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(verbatim: "\(artifact.ref) · \(artifact.title)"))
        .accessibilityLabel(Text(verbatim: "Artifact \(artifact.ref), \(artifact.title)"))
    }
}
