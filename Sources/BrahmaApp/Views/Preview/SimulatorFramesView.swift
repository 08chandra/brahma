import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// A running iOS app (Plan 4a Task 9b): the Simulator device's screen, polled through `SimulatorScreenshotSource` (`xcrun
/// simctl io <udid> screenshot`, every 500 ms, one capture at a time) from appear to disappear. Each PNG is decoded with
/// ImageIO's thumbnail path (`ImagePreviewView.decode`: properties first, at most 4096 px) under `RendererCaps.parse`; the
/// decode is sequential, and only the newest pending capture waits for it. `WAITING FOR SIMULATOR` shows before the first frame.
struct SimulatorFramesView: View {
    let udid: String
    @State private var frame: Frame?

    /// A decoded frame, handed from the decode to the main actor.
    struct Frame: @unchecked Sendable {
        let image: CGImage
        let width: Int
        let height: Int
    }

    var body: some View {
        Group {
            if let frame {
                VStack(spacing: 0) {
                    Image(decorative: frame.image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(BrahmaTheme.spaceS)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel(Text("Simulator screen"))
                    Hairline()
                    HStack(spacing: BrahmaTheme.spaceS) {
                        MonoChip(text: "\(frame.width) × \(frame.height)", color: BrahmaTheme.text2, fill: BrahmaTheme.bg3)
                        MonoChip(text: "SIMULATOR · " + String(udid.prefix(8)).uppercased(), color: BrahmaTheme.text2, fill: BrahmaTheme.bg3)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, BrahmaTheme.spaceS)
                    .frame(height: BrahmaTheme.denseRowHeight)
                    .background(BrahmaTheme.bg2)
                }
            } else {
                MonoEmptyState("WAITING FOR SIMULATOR")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrahmaTheme.bg0)
        .task(id: udid) {
            frame = nil
            let source = SimulatorScreenshotSource(udid: udid)
            let (captures, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(1))
            source.start { data in continuation.yield(data) }
            defer {
                source.stop()
                continuation.finish()
            }
            for await data in captures {
                guard let decoded = try? await RendererCaps.parse({ try ImagePreviewView.decode(data) }), !Task.isCancelled else { continue }
                if case .image(let image, let width, let height) = decoded {
                    frame = Frame(image: image, width: width, height: height)
                }
            }
        }
    }
}

/// `open -a Simulator --args -CurrentDeviceUDID <udid>` for the pane's "Open Simulator" button. The udid is the engine's; only
/// a device id (`SimulatorScreenshotSource.isDeviceId`) reaches `open`, with a fixed argv and no stdio.
enum SimulatorLauncher {
    static func open(udid: String) {
        guard SimulatorScreenshotSource.isDeviceId(udid) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Simulator", "--args", "-CurrentDeviceUDID", udid]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
