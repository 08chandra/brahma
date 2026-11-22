import SwiftUI
import AVKit
import AVFoundation
import BrahmaCore
import BrahmaAppModel

/// A video artifact (Plan 4a Task 9b): an `AVPlayerView` with inline controls, started paused and muted, looping when the clip
/// is shorter than `loopUnder`. The player is made only for a file URL inside the artifact's copy
/// (`PreviewNavigationPolicy.allowsArtifact(url, root:)`) that is a regular file at that moment
/// (`RendererCaps.regularFileProblem`, the readers' `O_NOFOLLOW` opener: AVFoundation would follow a link swapped in);
/// anything else is `CAN'T SHOW THIS FILE`. The first video track's `naturalSize` and `preferredTransform` (loaded under
/// `RendererCaps.race`, so a load that ignores its cancellation still cannot hold the stage past `parseTimeout`) go through `VideoLayout`: a
/// phone clip sits in the theme's `PhoneFrame`, others play plain. The "PHONE FRAME" chip toggles that; the host keeps the
/// owner's choice (`AppModel.phoneFrameOverride`, through `onPhoneFrame`), or this view does when no host does.
struct VideoPreviewView: View {
    let url: URL
    let root: URL
    /// The host's kept choice (nil follows `VideoLayout`); read only when `onPhoneFrame` is set.
    var phoneFrameOverride: Bool? = nil
    /// Where the chip's new value goes; nil keeps the choice in this view alone.
    var onPhoneFrame: ((Bool) -> Void)? = nil

    @State private var player: AVPlayer?
    @State private var looper: AVPlayerLooper?
    @State private var clip: ClipInfo?
    @State private var localOverride: Bool?
    /// Why the entry could not be handed to AVFoundation (engine-written), or nil.
    @State private var refused: String?

    /// Clips shorter than this loop.
    static let loopUnder: Double = 60

    /// What the first video track says, after its preferred transform.
    struct ClipInfo: Equatable, Sendable {
        var width: Double
        var height: Double
        var rotationDegrees: Double
        var seconds: Double

        var layout: VideoLayout { VideoLayout.layout(width: width, height: height, rotationDegrees: rotationDegrees) }

        /// The size as shown: a quarter turn swaps the sides.
        var shown: (width: Double, height: Double) {
            abs(rotationDegrees.rounded().truncatingRemainder(dividingBy: 180)) == 90 ? (height, width) : (width, height)
        }

        var aspect: CGFloat? {
            let s = shown
            guard s.width > 0, s.height > 0, s.width.isFinite, s.height.isFinite else { return nil }
            return CGFloat(s.width / s.height)
        }

        var sizeTitle: String { "\(Int(shown.width.rounded())) × \(Int(shown.height.rounded()))" }
        var durationTitle: String { seconds >= 1 ? "\(Int(seconds.rounded())) S" : "\(Int((seconds * 1000).rounded())) MS" }
    }

    private var allowed: Bool { PreviewNavigationPolicy.allowsArtifact(url, root: root) }
    private var detected: VideoLayout { clip?.layout ?? .plain }
    private var framed: Bool { (onPhoneFrame == nil ? localOverride : phoneFrameOverride) ?? (detected == .phone) }

    var body: some View {
        Group {
            if !allowed {
                FileLoadFailure(title: PreviewBodies.cantShowTitle, detail: "the video isn't inside the artifact")
            } else if let refused {
                FileLoadFailure(title: PreviewBodies.cantShowTitle, detail: refused)
            } else {
                VStack(spacing: 0) {
                    stage.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Hairline()
                    footer
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrahmaTheme.bg0)
        .task(id: url) { await run() }
    }

    @ViewBuilder private var stage: some View {
        if let player {
            if framed {
                // A forced frame around a landscape clip keeps the phone's shape (the clip letterboxes inside it).
                PhoneFrame(aspect: detected == .phone ? (clip?.aspect ?? 9.0 / 16.0) : 9.0 / 16.0) {
                    PlayerView(player: player)
                }
            } else {
                PlayerView(player: player)
                    .padding(BrahmaTheme.spaceS)
            }
        } else {
            Color.clear
        }
    }

    private var footer: some View {
        HStack(spacing: BrahmaTheme.spaceS) {
            if let clip {
                MonoChip(text: clip.sizeTitle, color: BrahmaTheme.text2, fill: BrahmaTheme.bg3)
                MonoChip(text: clip.durationTitle, color: BrahmaTheme.text2, fill: BrahmaTheme.bg3)
            }
            Spacer(minLength: 0)
            Button { setFrame(!framed) } label: {
                MonoChip(text: "PHONE FRAME", color: framed ? BrahmaTheme.bg0 : BrahmaTheme.text1, fill: framed ? BrahmaTheme.accent : BrahmaTheme.bg3)
            }
            .buttonStyle(.plain)
            .help("Show the clip in a phone frame")
            .accessibilityLabel(Text("Phone frame"))
            .accessibilityAddTraits(framed ? .isSelected : [])
        }
        .padding(.horizontal, BrahmaTheme.spaceS)
        .frame(height: BrahmaTheme.denseRowHeight)
        .background(BrahmaTheme.bg2)
    }

    private func setFrame(_ on: Bool) {
        if let onPhoneFrame { onPhoneFrame(on) } else { localOverride = on }
    }

    /// Checks the entry is a regular file (no link followed), inspects the asset (bounded), then makes the player: a looping
    /// `AVQueuePlayer` for a short clip, a plain `AVPlayer` otherwise. Never plays by itself; the controls do.
    private func run() async {
        player?.pause()
        player = nil
        looper = nil
        clip = nil
        refused = nil
        guard allowed else { return }
        if let problem = RendererCaps.regularFileProblem(url) {
            refused = problem == .notRegular ? "it isn't a regular file" : "it couldn't be read"
            return
        }
        let box = AssetBox(AVURLAsset(url: url))
        let info = await Self.inspect(box)
        guard !Task.isCancelled else { return }
        clip = info
        let item = AVPlayerItem(asset: box.asset)
        if let info, info.seconds > 0, info.seconds < Self.loopUnder {
            let queue = AVQueuePlayer()
            looper = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
        } else {
            player = AVPlayer(playerItem: item)
        }
        player?.isMuted = true
    }

    /// The first video track's size, rotation and the asset's duration, or nil after `RendererCaps.parseTimeout` (the
    /// unstructured race of `RendererCaps.race`: a load that never honours its cancellation is left behind, not waited for)
    /// or when the asset has no video track (the player still shows, plain).
    nonisolated static func inspect(_ box: AssetBox) async -> ClipInfo? {
        try? await RendererCaps.race { try await Self.probe(box.asset) }
    }

    private enum ProbeFailure: Error { case noVideoTrack }

    nonisolated static func probe(_ asset: AVURLAsset) async throws -> ClipInfo {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ProbeFailure.noVideoTrack }
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let duration = try await asset.load(.duration)
        return ClipInfo(width: size.width, height: size.height,
                        rotationDegrees: VideoLayout.rotationDegrees(a: transform.a, b: transform.b),
                        seconds: duration.isNumeric ? duration.seconds : 0)
    }
}

/// An asset handed to the bounded probe and back; AVFoundation's loads are thread-safe.
final class AssetBox: @unchecked Sendable {
    let asset: AVURLAsset
    init(_ asset: AVURLAsset) { self.asset = asset }
}

/// `AVPlayerView` with inline controls and nothing else (no full-screen, sharing or picture-in-picture buttons). Paused and
/// released when the view goes.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.showsSharingServiceButton = false
        view.allowsPictureInPicturePlayback = false
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
