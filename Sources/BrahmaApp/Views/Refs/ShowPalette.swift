import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// ⌘K (collab design §2.1): the Show bar's field, filter chips and results centered as an overlay over any view. Opening a hit
/// shows it in the OPENED slot, or in chat's inspector when the main preview is hidden (`AppModel.perform`). It takes focus as
/// it opens (the owner pressed ⌘K); Escape or a click outside closes it.
struct ShowPalette: View {
    let model: AppModel

    private var bar: ShowBarModel { model.showBar }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { bar.close() }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                ShowQueryField(model: model, presentation: .overlay, takesFocus: true)
                    .padding(BrahmaTheme.spaceS)
                if !bar.filterChips.isEmpty {
                    ShowFilterChips(model: model)
                        .padding(.horizontal, BrahmaTheme.spaceS)
                        .padding(.bottom, BrahmaTheme.spaceS)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Hairline()
                ShowResultsList(model: model)
                    .frame(minHeight: 60, maxHeight: 440)
                Hairline()
                HStack(spacing: BrahmaTheme.spaceM) {
                    Text(verbatim: "↑↓ MOVE · ↩ OPEN · ⌘↩ ASK · ⌥↩ OPEN ALL · ⇥ WHO · ⎋ CLOSE")
                        .font(BrahmaTheme.monoTiny)
                        .foregroundStyle(BrahmaTheme.text2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, BrahmaTheme.spaceS)
                .frame(height: BrahmaTheme.denseRowHeight)
                .background(BrahmaTheme.bg3)
            }
            .frame(width: 660)
            .background(BrahmaTheme.bg2)
            .clipShape(RoundedRectangle(cornerRadius: BrahmaTheme.radiusLarge))
            .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radiusLarge).strokeBorder(BrahmaTheme.lineStrong, lineWidth: 1))
            .padding(.top, 72)
        }
    }
}

extension View {
    /// The ⌘K palette over this view while the Show bar is open as an overlay.
    func showPaletteHost(model: AppModel) -> some View {
        overlay {
            if model.showBar.isOpen, model.showBar.presentation == .overlay {
                ShowPalette(model: model)
            }
        }
    }
}
