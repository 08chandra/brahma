import SwiftUI
import BrahmaCore
import BrahmaAppModel
import BrahmaMapKit

/// The org chart panel (Plan 4b Task 10a): the header (find, follow, fit, former, vacancy, replay, pop-out), the chart with
/// its overlays, and the replay bar.
///
/// It reads `model.mapController` on every render and never stores it: a company switch or a store restore replaces the
/// controller, and a panel holding the old one would draw a dead map. It also works standalone (the pop-out window and
/// `--map-demo` mount it with `isWindow: true`).
struct AgentMapPanel: View {
    /// The pop-out window's id (Task 10b declares the window).
    static let windowId = "map"

    let model: AppModel
    /// True in the pop-out window: no pop-out button, and the panel never shows the "open in window" placeholder.
    var isWindow = false

    @Environment(\.openWindow) private var openWindow
    @State private var query = ""

    var body: some View {
        let controller = model.mapController
        Panel(title: "Agent map", padded: false, accessory: {
            if let controller {
                MapHeader(model: model, controller: controller, query: $query, isWindow: isWindow, onPopOut: popOut)
            }
        }, content: {
            content(controller)
        })
        .overlayPreferenceValue(MapSearchAnchor.self) { anchor in
            GeometryReader { proxy in
                if let anchor, let controller, !query.trimmingCharacters(in: .whitespaces).isEmpty, !poppedOutHere {
                    let field = proxy[anchor]
                    MapSearchResults(controller: controller, onPick: { pick($0, in: controller) })
                        .offset(x: field.minX, y: field.maxY + 2)
                }
            }
        }
        .onAppear(perform: startMap)
        .onChange(of: model.mapController.map(ObjectIdentifier.init)) { startMap() }
        .onChange(of: model.mapPoppedOut) { startMap() }
        .onDisappear {
            // `stop()`, not `invalidate()`: an open vacancy sheet keeps working while the panel is off screen. A popped-out
            // map keeps running for its window; the window's own panel stops it when the window closes.
            if isWindow ? model.mapPoppedOut : !model.mapPoppedOut { model.mapController?.stop() }
        }
    }

    private var poppedOutHere: Bool { model.mapPoppedOut && !isWindow }

    @ViewBuilder private func content(_ controller: MapController?) -> some View {
        if poppedOutHere {
            ZStack {
                GridBackground()
                VStack(spacing: BrahmaTheme.spaceM) {
                    MonoEmptyState("Map open in window").fixedSize()
                    Button("Bring back") { model.mapPoppedOut = false }
                        .buttonStyle(.brahma)
                }
            }
        } else if controller?.isSynthetic != true && model.snapshot.agents.isEmpty {
            ZStack {
                GridBackground()
                VStack(spacing: BrahmaTheme.spaceM) {
                    MonoEmptyState("No agents yet.").fixedSize()
                    Button("Hire Agent") { model.presentedSheet = .hire }
                        .buttonStyle(.brahma)
                }
            }
        } else if let controller {
            MapBody(model: model, controller: controller)
        } else {
            ZStack {
                GridBackground()
                MonoEmptyState("Map unavailable").fixedSize()
            }
        }
    }

    private func startMap() {
        model.ensureMapController()?.start()
    }

    private func popOut() {
        model.mapPoppedOut = true
        openWindow(id: Self.windowId)
    }

    private func pick(_ id: String, in controller: MapController) {
        controller.jump(to: id)
        query = ""
        controller.search("")
    }
}

// MARK: - Body

/// The chart and its overlays. Owns the hover point, so a moving pointer re-renders this view and not the header.
private struct MapBody: View {
    let model: AppModel
    let controller: MapController
    @State private var hoverPoint: CGPoint?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                GridBackground()
                OrgView(controller: controller, appModel: model, hoverPoint: $hoverPoint,
                        onAddVacancy: { model.presentedSheet = .vacancy(managerHandle: $0) },
                        onFill: { model.presentedSheet = .fillVacancy(handle: $0) },
                        onMessage: { model.select(.dm(handle: $0)) })
                MapHoverHost(controller: controller, point: hoverPoint, bounds: geo.size)
                MapTeamHost(model: model, controller: controller)
                VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
                    Spacer(minLength: 0)
                    MapChipsOverlay(controller: controller)
                        .padding(.horizontal, BrahmaTheme.spaceS)
                        .padding(.bottom, controller.replay == nil ? BrahmaTheme.spaceS : 0)
                    MapScrubber(controller: controller, timeZone: model.ownerTimeZone)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .animation(BrahmaTheme.medium, value: controller.replay != nil)
    }
}

/// The hover card at the pointer. The card is read twice a second (and when the hovered agent changes), not on every frame.
private struct MapHoverHost: View {
    let controller: MapController
    let point: CGPoint?
    let bounds: CGSize
    @State private var card: MapHoverCard?
    @State private var size = CGSize(width: MapHoverCardView.width, height: 140)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let point, let card {
                let origin = MapOverlay.clamp(MapPoint2(x: point.x, y: point.y),
                                              size: MapPoint2(x: size.width, y: size.height),
                                              in: MapPoint2(x: bounds.width, y: bounds.height))
                MapHoverCardView(card: card)
                    .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { size = $0 })
                    .offset(x: origin.x, y: origin.y)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .task(id: controller.hoveredAgentId) {
            while !Task.isCancelled {
                refresh()
                try? await AwakeTime.sleep(for: .milliseconds(500))
            }
        }
    }

    private func refresh() {
        let next = controller.hoveredAgentId.flatMap { controller.model.hoverCard(agentId: $0) }
        guard next != card else { return }
        withAnimation(BrahmaTheme.fast) { card = next }
    }
}

/// The selected team's card, top right.
private struct MapTeamHost: View {
    let model: AppModel
    let controller: MapController
    @State private var card: MapTeamCard?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let card {
                MapTeamCardView(card: card,
                                onSelect: { controller.handle(.agent($0), appModel: model) },
                                onClose: { controller.selectedManagerId = nil })
                    .padding(BrahmaTheme.spaceS)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .task(id: controller.selectedManagerId) {
            while !Task.isCancelled {
                refresh()
                try? await AwakeTime.sleep(for: .milliseconds(500))
            }
        }
    }

    private func refresh() {
        let next = controller.selectedManagerId.flatMap { controller.model.teamCard(managerId: $0) }
        guard next != card else { return }
        withAnimation(BrahmaTheme.medium) { card = next }
    }
}

/// The status chips at the bottom left: aggregate rate, the followed agent, recent drops.
private struct MapChipsOverlay: View {
    let controller: MapController
    @State private var chips: [MapChip] = []

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                HStack(spacing: 4) {
                    Text(verbatim: chip.text)
                        .font(BrahmaTheme.monoTiny)
                        .foregroundStyle(chip.isWarning ? BrahmaTheme.warning : BrahmaTheme.text0)
                        .lineLimit(1)
                    if chip.dismissible {
                        Button { controller.follow(nil) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(BrahmaTheme.text1)
                                .frame(width: 12, height: 12).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Stop following")
                        .accessibilityLabel(Text("Stop following"))
                    }
                }
                .padding(.horizontal, 5)
                .frame(minHeight: 16)
                .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.bg3))
                .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius)
                    .strokeBorder(chip.isWarning ? BrahmaTheme.warning.opacity(0.6) : BrahmaTheme.line, lineWidth: 1))
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: ObjectIdentifier(controller)) {
            while !Task.isCancelled {
                refresh()
                try? await AwakeTime.sleep(for: .milliseconds(250))
            }
        }
    }

    private func refresh() {
        // The followed agent's cleaned handle; `chips` strips the "@" and cleans it once more.
        let handle = controller.follow.flatMap { controller.model.agents[$0]?.handle }
        let next = MapOverlay.chips(stats: controller.model.stats, followHandle: handle, now: controller.lastFrameTime ?? 0)
        guard next != chips else { return }
        withAnimation(BrahmaTheme.fast) { chips = next }
    }
}
