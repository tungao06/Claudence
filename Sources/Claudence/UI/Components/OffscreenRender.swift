import SwiftUI

/// The one seam the offscreen renderer needs in the view tree.
///
/// `ImageRenderer` draws nothing inside a `ScrollView` on this platform: the
/// header of a window renders and the entire scrolled body comes back blank.
/// Verified with a four-line probe before this existed, so the workaround is
/// not guesswork about why a shot was empty.
///
/// `RenderableScrollView` is therefore an ordinary `ScrollView` in the running
/// application and a plain stack when `--render-ui` is drawing. Nothing else
/// changes: same content, same padding, same widths, so a defect visible in a
/// shot is a defect in the shipped layout.
private struct OffscreenRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True only while `RenderShots` is drawing. Never set by the application.
    var isOffscreenRender: Bool {
        get { self[OffscreenRenderKey.self] }
        set { self[OffscreenRenderKey.self] = newValue }
    }
}

/// A vertical scroll view that flattens to its content while being rendered
/// offscreen.
struct RenderableScrollView<Content: View>: View {
    @Environment(\.isOffscreenRender) private var isOffscreenRender
    /// How tall the scroller may grow before it starts scrolling. Nil leaves it
    /// to the host, which is what a view already inside a sized window wants.
    var heightCap: CGFloat?
    @ViewBuilder let content: Content

    /// The measured height of the content, which is what lets a short panel
    /// stay short.
    ///
    /// A `ScrollView` has no ideal height: it takes whatever it is offered, and
    /// inside a `MenuBarExtra` popover, which sizes itself to its content, that
    /// negotiation resolves to almost nothing. The session detail therefore
    /// opened as a squeezed strip with everything below the first panel behind
    /// a scroll, on a screen with 900 pt free underneath it.
    ///
    /// `frame(maxHeight:)` does not fix that: a cap bounds the top and the
    /// scroller was already at the bottom. The height has to be *stated*, and
    /// stating a fixed one would leave a short detail sitting in an empty
    /// window. So the content is measured and the frame is the smaller of the
    /// measurement and the cap: short panels size to themselves, long ones stop
    /// at the cap and scroll from there.
    ///
    /// No feedback loop: the content's height is a function of the width, which
    /// this does not change.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        if isOffscreenRender {
            content
        } else if let heightCap {
            ScrollView(.vertical) {
                content.onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
            }
            // Before the first measurement arrives the cap is the honest
            // guess: a window that opens tall and settles shorter is far less
            // jarring than one that opens as a sliver and grows.
            .frame(height: contentHeight > 0 ? min(contentHeight, heightCap) : heightCap)
        } else {
            ScrollView(.vertical) { content }
        }
    }
}

extension View {

    /// The sheet's height cap, lifted while rendering offscreen.
    ///
    /// The cap is what makes the detail scroll inside a popover. Applied to a
    /// flattened stack it would clip the shot to 520 pt of a 2 000 pt view and
    /// centre it, which reads as a layout defect and is not one.
    @ViewBuilder
    func scrollHeightCap(_ maxHeight: CGFloat, isOffscreenRender: Bool) -> some View {
        if isOffscreenRender {
            self
        } else {
            frame(maxHeight: maxHeight)
        }
    }
}
