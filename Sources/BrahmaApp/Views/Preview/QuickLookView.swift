import SwiftUI
import Quartz
import QuickLookThumbnailing
import BrahmaAppModel

/// Quick Look for the formats the app never parses itself (Plan 4a Task 9a): PDFs, Office documents and the 3D formats glTF
/// cannot read go to a `QLPreviewView` (rendered out of process by the system's Quick Look service); an agent's or an outside
/// image goes to `QLThumbnailGenerator` at 2048 px (`thumbnail: true`), so no untrusted image is decoded in this process.
struct QuickLookView: View {
    let url: URL
    var thumbnail = false

    var body: some View {
        Group {
            if thumbnail {
                QuickLookThumbnailView(url: url)
            } else {
                QLPreviewRepresentable(url: url)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrahmaTheme.bg0)
    }
}

/// `QLPreviewView` in the `normal` style, closed when the view goes.
private struct QLPreviewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

/// An NSImage handed back from Quick Look's completion queue to the main actor.
private struct SendableNSImage: @unchecked Sendable {
    let image: NSImage
}

/// The system's thumbnail of an image, at most 2048 px on a side, generated out of process.
private struct QuickLookThumbnailView: View {
    let url: URL
    @State private var load: FileLoad<SendableNSImage>?

    static let maxPixels: CGFloat = 2048

    var body: some View {
        Group {
            switch load {
            case nil:
                Color.clear
            case .failed(let title, let detail)?:
                FileLoadFailure(title: title, detail: detail)
            case .ready(let image)?:
                Image(nsImage: image.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(BrahmaTheme.spaceS)
                    .accessibilityLabel(Text(verbatim: url.lastPathComponent))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            load = nil
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: Self.maxPixels, height: Self.maxPixels),
                                                       scale: 1, representationTypes: .thumbnail)
            let image: SendableNSImage? = await withCheckedContinuation { continuation in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                    continuation.resume(returning: representation.map { SendableNSImage(image: $0.nsImage) })
                }
            }
            guard !Task.isCancelled else { return }
            load = image.map { .ready($0) } ?? .failed(title: PreviewBodies.cantShowTitle, detail: "Quick Look couldn't render it")
        }
    }
}
