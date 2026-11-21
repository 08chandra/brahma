import SwiftUI
import ImageIO
import BrahmaCore
import BrahmaAppModel

/// An image the owner or the engine made (Plan 4a Task 9a; `FileBody.effectiveMode` sends every other image to Quick Look).
/// ImageIO reads the properties first: past `RendererCaps.maxImagePixels` (width × height) nothing is decoded and the file
/// card shows instead; otherwise `CGImageSourceCreateThumbnailAtIndex` decodes a thumbnail of at most 4096 px. The bytes come
/// from the hardened reader and the whole decode runs under `RendererCaps.parse`.
struct ImagePreviewView: View {
    let url: URL
    /// What shows for an image too large to decode in process.
    let card: FileCardView
    @State private var load: FileLoad<Decoded>?

    nonisolated static let maxThumbnailPixelSize = 4096

    /// A decoded image, or the pixel count that kept it from being decoded.
    enum Decoded: @unchecked Sendable {
        case image(CGImage, width: Int, height: Int)
        case tooLarge(width: Int, height: Int)
    }

    private enum DecodeFailure: Error { case undecodable }

    var body: some View {
        Group {
            switch load {
            case nil:
                Color.clear
            case .failed(let title, let detail)?:
                FileLoadFailure(title: title, detail: detail)
            case .ready(.tooLarge(let w, let h))?:
                VStack(spacing: BrahmaTheme.spaceS) {
                    card
                    Text(verbatim: "\(w) × \(h) px is more than this preview decodes")
                        .font(BrahmaTheme.monoSmall)
                        .foregroundStyle(BrahmaTheme.text2)
                }
            case .ready(.image(let cg, let w, let h))?:
                VStack(spacing: 0) {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(BrahmaTheme.spaceS)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel(Text(verbatim: url.lastPathComponent))
                    Hairline()
                    HStack {
                        MonoChip(text: "\(w) × \(h)", color: BrahmaTheme.text2, fill: BrahmaTheme.bg3)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, BrahmaTheme.spaceS)
                    .frame(height: BrahmaTheme.denseRowHeight)
                    .background(BrahmaTheme.bg2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrahmaTheme.bg0)
        .task(id: url) {
            load = nil
            let result = await FileLoad<Decoded>.load(url, maxBytes: ArtifactPolicy.maxFileBytes, Self.decode)
            if let result { load = result }
        }
    }

    /// Properties first, then the thumbnail; nothing else of the file is decoded.
    nonisolated static func decode(_ data: Data) throws -> Decoded {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, width > 0, height > 0 else {
            throw DecodeFailure.undecodable
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        if overflow || pixels > RendererCaps.maxImagePixels { return .tooLarge(width: width, height: height) }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxThumbnailPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw DecodeFailure.undecodable }
        return .image(image, width: width, height: height)
    }
}
