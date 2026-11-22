import SwiftUI

/// A phone-shaped frame around any content (Plan 4a Task 9b; Collab §6.1 hosts L's `iphone` web viewport in it too). It
/// knows nothing of video or web: the content is held to `aspect` (width ÷ height, 9:16 by default) with `.fit`, clipped to
/// the inner radius (`deviceRadius − deviceBezel`), set in a `deviceBezel` bezel of `bg1` with a 1 px `lineStrong` outline at
/// the outer `deviceRadius`, and centered on `bg0` with `spaceL` padding. No notch, no brand mark.
struct PhoneFrame<Content: View>: View {
    let aspect: CGFloat
    @ViewBuilder var content: Content

    init(aspect: CGFloat = 9.0 / 16.0, @ViewBuilder content: () -> Content) {
        self.aspect = aspect
        self.content = content()
    }

    var body: some View {
        content
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: BrahmaTheme.deviceRadius - BrahmaTheme.deviceBezel, style: .continuous))
            .padding(BrahmaTheme.deviceBezel)
            .background(RoundedRectangle(cornerRadius: BrahmaTheme.deviceRadius, style: .continuous).fill(BrahmaTheme.bg1))
            .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.deviceRadius, style: .continuous).strokeBorder(BrahmaTheme.lineStrong, lineWidth: 1))
            .padding(BrahmaTheme.spaceL)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrahmaTheme.bg0)
    }
}
