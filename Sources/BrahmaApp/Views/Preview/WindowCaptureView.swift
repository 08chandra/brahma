import SwiftUI
import AppKit
import ScreenCaptureKit
import CoreImage
import CoreMedia
import BrahmaCore
import BrahmaAppModel

/// A running macOS app (Plan 4a Task 9b): its largest on-screen window, streamed by ScreenCaptureKit
/// (`SCContentFilter(desktopIndependentWindow:)`, at most `maxFPS`, no cursor) from appear to disappear.
///
/// **Permission.** On first appear `CGPreflightScreenCaptureAccess()` is read; it never prompts. Without the grant the body
/// says `SCREEN RECORDING NEEDED` with an "Allow…" button, whose `CGRequestScreenCaptureAccess()` is the only prompt. Nothing of
/// ScreenCaptureKit is touched before the grant is there.
///
/// **Capture.** `NO WINDOW YET` while the pid owns no on-screen window (looked up every `windowPoll`); a stream that ends (the
/// window closed) goes back to looking. On this engine macOS previews are `unavailable` (5-lite's GUI sandbox profile), so
/// this body is reached only once that lifts. The grant is tied to the app's code signature: an ad-hoc debug build gets a new
/// identity on each rebuild, so it may have to be re-granted; verify by hand on a release build.
struct WindowCaptureView: View {
    let pid: Int32
    /// nil before the first appear read it.
    @State private var permission: Bool?
    @State private var frame: CapturedFrame?
    @State private var failure: String?

    static let maxFPS: Int32 = 10
    static let windowPoll: Duration = .seconds(1)
    /// The longest side of a captured frame, in pixels.
    static let maxPixelSide = 2048

    private struct CaptureKey: Equatable {
        var pid: Int32
        var permission: Bool?
    }

    var body: some View {
        Group {
            switch permission {
            case nil:
                Color.clear
            case false?:
                VStack(spacing: BrahmaTheme.spaceM) {
                    MonoEmptyState("SCREEN RECORDING NEEDED", detail: "Brahma needs Screen Recording permission to show the app's live window.")
                        .fixedSize()
                    Button("Allow…") {
                        _ = CGRequestScreenCaptureAccess()
                        permission = CGPreflightScreenCaptureAccess()
                    }
                    .buttonStyle(.brahmaPrimary)
                    .help("Ask macOS for Screen Recording permission")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case true?:
                if let failure {
                    MonoEmptyState("CAN'T SHOW THIS WINDOW", detail: failure)
                } else if let frame {
                    VStack(spacing: 0) {
                        Image(decorative: frame.image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .padding(BrahmaTheme.spaceS)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityLabel(Text("App window"))
                        Hairline()
                        HStack(spacing: BrahmaTheme.spaceS) {
                            MonoChip(text: "\(frame.image.width) × \(frame.image.height)", color: BrahmaTheme.text2, fill: BrahmaTheme.bg3)
                            MonoChip(text: "PID \(pid)", color: BrahmaTheme.text2, fill: BrahmaTheme.bg3)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, BrahmaTheme.spaceS)
                        .frame(height: BrahmaTheme.denseRowHeight)
                        .background(BrahmaTheme.bg2)
                    }
                } else {
                    MonoEmptyState("NO WINDOW YET")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrahmaTheme.bg0)
        .onAppear {
            if permission == nil { permission = CGPreflightScreenCaptureAccess() }
        }
        .task(id: CaptureKey(pid: pid, permission: permission)) {
            guard permission == true else { return }
            await capture()
        }
    }

    /// Finds the window, streams it until the stream ends, and looks again; ends with the task.
    private func capture() async {
        frame = nil
        failure = nil
        let streamer = WindowStreamer(maxPixelSide: Self.maxPixelSide, fps: Self.maxFPS)
        defer { streamer.stop() }
        while !Task.isCancelled {
            let frames: AsyncStream<CapturedFrame>?
            do {
                frames = try await streamer.start(pid: pid)
            } catch {
                failure = "ScreenCaptureKit couldn't capture it: \(error.localizedDescription)"
                return
            }
            guard let frames else {
                frame = nil
                try? await Task.sleep(for: Self.windowPoll)
                continue
            }
            for await f in frames { frame = f }
            streamer.stop()
            frame = nil
        }
    }
}

/// A frame handed from the capture queue to the main actor.
struct CapturedFrame: @unchecked Sendable {
    let image: CGImage
}

/// The ScreenCaptureKit side: one `SCStream` of the pid's largest on-screen window, its complete frames converted to `CGImage`
/// on the capture queue and yielded (newest kept) to an `AsyncStream` that finishes when the stream stops.
final class WindowStreamer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let maxPixelSide: Int
    private let fps: Int32
    private let queue = DispatchQueue(label: "dev.brahma.window-capture")
    private let context = CIContext(options: nil)
    private let lock = NSLock()
    private var stream: SCStream?
    private var continuation: AsyncStream<CapturedFrame>.Continuation?

    init(maxPixelSide: Int, fps: Int32) {
        self.maxPixelSide = maxPixelSide
        self.fps = fps
    }

    /// Starts capturing the pid's largest on-screen window; nil when it owns none. The returned stream ends when the capture
    /// stops (the window went away) or `stop()` is called.
    func start(pid: Int32) async throws -> AsyncStream<CapturedFrame>? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let windows = content.windows.filter { $0.owningApplication?.processID == pid && $0.frame.width > 1 && $0.frame.height > 1 }
        guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }

        let config = SCStreamConfiguration()
        let scale: CGFloat = 2
        var width = window.frame.width * scale, height = window.frame.height * scale
        let longest = max(width, height)
        if longest > CGFloat(maxPixelSide) {
            let factor = CGFloat(maxPixelSide) / longest
            width *= factor
            height *= factor
        }
        config.width = max(Int(width.rounded()), 1)
        config.height = max(Int(height.rounded()), 1)
        config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 3

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        let (frames, continuation) = AsyncStream.makeStream(of: CapturedFrame.self, bufferingPolicy: .bufferingNewest(1))
        lock.withLock {
            self.stream = stream
            self.continuation = continuation
        }
        do {
            try await stream.startCapture()
        } catch {
            stop()
            throw error
        }
        return frames
    }

    /// Stops the capture (best effort) and ends the frame stream.
    func stop() {
        let (stream, continuation): (SCStream?, AsyncStream<CapturedFrame>.Continuation?) = lock.withLock {
            defer {
                self.stream = nil
                self.continuation = nil
            }
            return (self.stream, self.continuation)
        }
        continuation?.finish()
        stream?.stopCapture { _ in }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let continuation = lock.withLock { self.continuation }
        continuation?.yield(CapturedFrame(image: image))
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        stop()
    }
}
