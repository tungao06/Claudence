import AppKit
import SwiftUI

/// Keeps the menu bar popover centred on the status item while its width
/// changes, instead of letting it grow in one direction.
///
/// ## Why this is needed at all
///
/// The popover is not one width. The session list is laid out at 420 pt, the
/// design's width for it, and the session detail at 760, because a two-column
/// detail squeezed into 420 gives each column 187 pt and truncates every metric
/// row. So opening a detail changes the window's width by 340 pt.
///
/// AppKit sizes that window to its content and leaves the origin where it was,
/// which means the left edge stays put and the whole extra width appears on the
/// right. The panel visibly lurches sideways out from under the status item it
/// belongs to. What is wanted is the panel staying put and opening out both
/// ways.
///
/// ## Why the anchor is the status item and not the previous frame
///
/// Remembering where the window was before the resize works exactly once. The
/// popover keeps `detailSessionID` across a dismissal, so reopening it can go
/// straight to the detail width, with no narrow frame beforehand to remember.
/// The status item, on the other hand, is where the popover belongs at every
/// width and however it was opened.
///
/// It is found by class name rather than by owning the `NSStatusItem`, because
/// `MenuBarExtra` creates that item and hands nothing back. `NSApp.windows`
/// holds only this process's windows, so there is exactly one status bar window
/// in it: ours. If the lookup ever fails, the frame the popover first appeared
/// at is used instead, and if that is missing too the window is left alone --
/// this is a placement refinement, and refusing to guess is cheaper than
/// putting the panel somewhere wrong.
///
/// ## Cost
///
/// One notification observer on one window, fired only when that window
/// actually resizes. Nothing polls, nothing runs while the popover sits idle,
/// which is the standing requirement for anything mounted for the life of the
/// process.
struct PopoverAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        AnchorView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class AnchorView: NSView {
    /// Where the popover first appeared. The fallback anchor, used only when
    /// the status item cannot be found.
    private var openedCentreX: CGFloat?
    private var observer: NSObjectProtocol?
    /// Guards against reacting to the resize notification our own `setFrame`
    /// would provoke.
    private var isAdjusting = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        openedCentreX = nil

        guard let window else { return }
        openedCentreX = window.frame.midX
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recentre()
            }
        }
    }

    // No `deinit` teardown. AppKit calls `viewDidMoveToWindow` with a nil
    // window when the view leaves one, and that path removes the observer
    // before returning, so the only observer that can exist belongs to the
    // window this view is currently in.

    @MainActor
    private func recentre() {
        guard !isAdjusting, let window, let centre = anchorCentreX else { return }

        var frame = window.frame
        let wanted = (centre - frame.width / 2).rounded()
        let placed = clamped(wanted, width: frame.width, on: window.screen)

        // A half point of drift is not worth a frame change, and setting the
        // frame to what it already is would still post another notification.
        guard abs(frame.origin.x - placed) > 0.5 else { return }

        frame.origin.x = placed
        isAdjusting = true
        window.setFrame(frame, display: true)
        isAdjusting = false
    }

    /// The centre of the status item, or of wherever the popover first opened.
    @MainActor
    private var anchorCentreX: CGFloat? {
        if let status = NSApp.windows.first(where: {
            $0.className.contains("StatusBarWindow")
        }) {
            return status.frame.midX
        }
        return openedCentreX
    }

    /// Keeps the panel on screen. A wide popover under a status item near the
    /// right edge would otherwise be centred half way off the display, which is
    /// a worse failure than the off-centre growth this fixes.
    @MainActor
    private func clamped(_ x: CGFloat, width: CGFloat, on screen: NSScreen?) -> CGFloat {
        guard let visible = screen?.visibleFrame else { return x }
        let highest = visible.maxX - width
        guard highest > visible.minX else { return visible.minX }
        return min(max(x, visible.minX), highest)
    }
}
