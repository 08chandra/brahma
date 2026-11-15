import SwiftUI
import BrahmaAppModel

/// The replay bar at the bottom of the map: a slider over the replay window, play/pause, the speed, the replay time and LIVE.
/// It reads the controller's replay state each render and never stores the controller.
struct MapScrubber: View {
    let controller: MapController
    let timeZone: TimeZone

    var body: some View {
        if let replay = controller.replay {
            HStack(spacing: BrahmaTheme.spaceS) {
                Button {
                    controller.setPlaying(!replay.playing)
                } label: {
                    Image(systemName: replay.playing ? "pause.fill" : "play.fill")
                        .frame(width: 12)
                }
                .buttonStyle(.brahma)
                .help(replay.playing ? "Pause" : "Play")
                .accessibilityLabel(Text(replay.playing ? "Pause replay" : "Play replay"))

                Slider(value: Binding(get: { replay.time.timeIntervalSince1970 },
                                      set: { controller.scrub(to: Date(timeIntervalSince1970: $0)) }),
                       in: replay.timeline.start.timeIntervalSince1970...replay.timeline.end.timeIntervalSince1970)
                    .tint(BrahmaTheme.accent)
                    .controlSize(.small)
                    .accessibilityLabel(Text("Replay position"))

                Segmented(options: MapTimeline.speeds.map { ($0, Self.speedLabel($0)) }, selection: replay.speed,
                          label: "Replay speed") { controller.setSpeed($0) }

                Text(verbatim: Self.clock(replay.time, in: timeZone))
                    .font(BrahmaTheme.mono)
                    .foregroundStyle(BrahmaTheme.text0)
                    .monospacedDigit()
                    .fixedSize()

                if replay.timeline.truncated {
                    MonoChip(text: "TRUNCATED", color: BrahmaTheme.warning, fill: BrahmaTheme.bg4)
                        .help("The history is longer than the map can replay; the start of the hour is cut.")
                }
                Button("LIVE") { controller.exitReplay() }
                    .buttonStyle(.brahmaPrimary)
                    .help("Back to the live map")
            }
            .padding(.horizontal, BrahmaTheme.spaceS)
            .frame(height: 32)
            .frame(maxWidth: .infinity)
            .background(BrahmaTheme.bg3.opacity(0.96))
            .overlay(alignment: .top) { Hairline() }
        }
    }

    static func speedLabel(_ speed: Double) -> String { "\(Int(speed))×" }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// `HH:mm:ss` in `zone`.
    static func clock(_ date: Date, in zone: TimeZone) -> String {
        formatter.timeZone = zone
        return formatter.string(from: date)
    }
}
