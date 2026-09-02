import AppKit
import SwiftUI
import ClaudenceCore

/// Draws the windows offscreen and writes them to disk.
///
/// There is no Xcode on this machine, so `#Preview` does not compile and a
/// `PreviewProvider` renders nowhere. The only way a layout could be inspected
/// was to launch the application and drive it by hand, which cannot reach a
/// sheet, an empty state, or the light appearance without a person clicking.
/// `--render-ui <dir>` renders the same views through `ImageRenderer` at a
/// height tall enough that nothing is cut by a scroll viewport, in both
/// appearances, and exits.
///
/// It draws fixtures, never live data: a shot of the real session list would
/// differ on every run and could carry a project path onto disk.
@MainActor
enum RenderShots {

    /// Tall enough for the whole dashboard column to draw without the scroll
    /// view cutting it. A shot that ended at the viewport would hide exactly
    /// the kind of defect this exists to find.
    private static let dashboardSize = CGSize(width: 1_120, height: 2_600)
    private static let detailSize = CGSize(width: Theme.Layout.sheetWidth, height: 1_600)
    private static let scale: CGFloat = 2

    static func run(directory: String) {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("cannot create \(root.path): \(error)\n".utf8))
            return
        }

        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let suffix = scheme == .dark ? "dark" : "light"

            write(
                name: "dashboard-\(suffix)",
                size: dashboardSize,
                scheme: scheme,
                into: root
            ) {
                DashboardView(
                    data: DashboardRenderFixture.populated,
                    now: DashboardRenderFixture.now,
                    onRefresh: {},
                    onSelectSession: { _ in }
                )
            }

            write(
                name: "dashboard-empty-\(suffix)",
                size: dashboardSize,
                scheme: scheme,
                into: root
            ) {
                DashboardView(
                    data: DashboardRenderFixture.empty,
                    now: DashboardRenderFixture.now,
                    onRefresh: {},
                    onSelectSession: { _ in }
                )
            }

            write(
                name: "dashboard-sliver-\(suffix)",
                size: dashboardSize,
                scheme: scheme,
                into: root
            ) {
                DashboardView(
                    data: DashboardRenderFixture.sliver,
                    now: DashboardRenderFixture.now,
                    onRefresh: {},
                    onSelectSession: { _ in }
                )
            }

            write(
                name: "detail-\(suffix)",
                size: detailSize,
                scheme: scheme,
                into: root
            ) {
                SessionDetailView(
                    session: DetailRenderFixture.session,
                    subagents: DetailRenderFixture.subagents,
                    tokenScaleMaximum: DetailRenderFixture.tokenScaleMaximum,
                    burnRatePerMinute: DetailRenderFixture.burnRatePerMinute,
                    burnHistory: DetailRenderFixture.burnHistory,
                    windowShare: DetailRenderFixture.windowShare,
                    now: DashboardRenderFixture.now,
                    onClose: {}
                )
                .detailSheetChrome()
            }

            // The subagent variant, which is the one whose title bar carries a
            // back button. It had no shot, which is part of why a back link
            // that scrolled out of reach was found by a user rather than here.
            if let subagent = DetailRenderFixture.subagents.first {
                write(
                    name: "detail-subagent-\(suffix)",
                    size: detailSize,
                    scheme: scheme,
                    into: root
                ) {
                    SubagentDetailView(
                        subagent: subagent,
                        parent: DetailRenderFixture.session,
                        parentTotal: DetailRenderFixture.session.combinedUsage.total,
                        costEstimator: CostEstimator(),
                        now: DashboardRenderFixture.now,
                        onBack: {},
                        onClose: {}
                    )
                    .detailSheetChrome()
                }
            }
        }
    }

    private static func write<Content: View>(
        name: String,
        size: CGSize?,
        scheme: ColorScheme,
        into root: URL,
        @ViewBuilder content: () -> Content
    ) {
        let sized = size.map { AnyView(content().frame(width: $0.width, height: $0.height, alignment: .top)) }
            ?? AnyView(content())
        let view = sized
            .environment(\.colorScheme, scheme)
            .environment(\.isOffscreenRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.cgImage else {
            FileHandle.standardError.write(Data("render failed: \(name)\n".utf8))
            return
        }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("encode failed: \(name)\n".utf8))
            return
        }
        let url = root.appendingPathComponent(name + ".png")
        do {
            try data.write(to: url)
            print("\(url.path)  \(image.width)x\(image.height)")
        } catch {
            FileHandle.standardError.write(Data("write failed: \(url.path): \(error)\n".utf8))
        }
    }
}
