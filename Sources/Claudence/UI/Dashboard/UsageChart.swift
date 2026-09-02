import SwiftUI
import ClaudenceCore

/// Usage over time, drawn by hand.
///
/// The chart answers one question — "am I using more than usual?" — so it is
/// a single line over a soft area, four gridlines at most, and sparse date
/// labels. No legend, no second series, no dual axis.
///
/// The one rule it will not bend: **a missing bucket is a gap, not a zero.**
/// A day with no activity is a measured zero and sits on the floor; a day the
/// store could not answer for breaks the line and is marked with a dashed
/// rule. Drawing both the same way would report an outage as idleness.
///
/// Drawn with `Path` and `Canvas` rather than a charting framework, so it has
/// no dependency to resolve and every pixel is accounted for here.
struct UsageChart: View {
    let points: [ChartPoint]
    /// What the series measures, spoken in the accessibility summary.
    let title: String
    let unavailableMessage: String
    let unavailableReason: String?
    let height: CGFloat

    @State private var selectedIndex: Int?
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        points: [ChartPoint],
        title: String = "Usage over time",
        unavailableMessage: String = "No usage history",
        unavailableReason: String? = nil,
        height: CGFloat = DashboardMetrics.chartHeight
    ) {
        self.points = points
        self.title = title
        self.unavailableMessage = unavailableMessage
        self.unavailableReason = unavailableReason
        self.height = height
    }

    // MARK: - Derived state

    private var measured: [ChartPoint] { points.filter { !$0.isMissing } }
    private var missingCount: Int { points.count - measured.count }

    /// A series with no measured point at all is not a flat chart, it is an
    /// absence. Rendering axes around nothing would imply we looked and found
    /// zero.
    private var hasAnythingToDraw: Bool { !measured.isEmpty }

    private var selectedPoint: ChartPoint? {
        guard let selectedIndex, points.indices.contains(selectedIndex) else { return nil }
        return points[selectedIndex]
    }

    var body: some View {
        if hasAnythingToDraw {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                readout
                plot
            }
        } else {
            UnavailableView(unavailableMessage, reason: unavailableReason)
                .frame(height: height, alignment: .top)
        }
    }

    // MARK: - Readout
    //
    // Fixed height so selecting a point never reflows the sections below it.

    private var readout: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(readoutPrimary)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.m)
            Text(readoutSecondary)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .accessibilityHidden(true)
    }

    private var readoutPrimary: String {
        guard let point = selectedPoint else { return title }
        guard !point.isMissing else { return "\(point.label) · no data recorded" }
        return "\(point.label) · \(Format.tokens(Int(point.value.rounded()))) tokens"
    }

    private var readoutSecondary: String {
        if selectedPoint != nil { return "Arrow keys to move, Escape to clear" }
        var parts = ["\(points.count) days"]
        if let peak = measured.max(by: { $0.value < $1.value }) {
            parts.append("peak \(Format.tokens(Int(peak.value.rounded()))) on \(peak.label)")
        }
        if missingCount > 0 {
            parts.append(missingCount == 1 ? "1 gap" : "\(missingCount) gaps")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Plot

    private var plot: some View {
        GeometryReader { geo in
            let geometry = ChartGeometry(size: geo.size, points: points)
            ZStack(alignment: .topLeading) {
                Canvas(rendersAsynchronously: false) { context, _ in
                    UsageChart.render(points: points, geometry: geometry, in: &context)
                }
                selectionMarker(geometry)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    // Hover only steers the selection while the chart is not
                    // being driven from the keyboard.
                    if !isFocused { selectedIndex = geometry.index(atX: location.x) }
                case .ended:
                    if !isFocused { selectedIndex = nil }
                }
            }
        }
        .frame(height: height)
        .focusable()
        .focused($isFocused)
        .onMoveCommand { move($0) }
        .onExitCommand { selectedIndex = nil }
        .onChange(of: isFocused) { _, focused in
            // Taking focus lands on the most recent point, so a keyboard user
            // never has to guess where the cursor is.
            if focused, selectedIndex == nil { selectedIndex = points.indices.last }
            if !focused { selectedIndex = nil }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: DashboardMetrics.focusRingWidth)
                .opacity(isFocused ? 1 : 0)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spokenSummary)
        .accessibilityChildren { pointElements }
    }

    private func move(_ direction: MoveCommandDirection) {
        guard !points.isEmpty else { return }
        let current = selectedIndex ?? points.count - 1
        switch direction {
        case .left:
            selectedIndex = max(0, current - 1)
        case .right:
            selectedIndex = min(points.count - 1, current + 1)
        default:
            break
        }
    }

    @ViewBuilder
    private func selectionMarker(_ geometry: ChartGeometry) -> some View {
        if let index = selectedIndex, points.indices.contains(index) {
            let point = points[index]
            let x = geometry.x(index)
            ZStack(alignment: .topLeading) {
                // The rule alone marks a missing bucket: there is no value to
                // put a dot on, and inventing one is the whole thing we avoid.
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: DashboardMetrics.chartGridStroke, height: geometry.plot.height)
                    .position(x: x, y: geometry.plot.midY)
                if !point.isMissing {
                    Circle()
                        .fill(Theme.accent)
                        .frame(
                            width: DashboardMetrics.chartPointRadius * 2,
                            height: DashboardMetrics.chartPointRadius * 2
                        )
                        .position(x: x, y: geometry.y(point.value))
                }
            }
            .allowsHitTesting(false)
            .animation(
                Theme.animation(Theme.Motion.valueChange, reduceMotion: reduceMotion),
                value: selectedIndex
            )
        }
    }

    // MARK: - Accessibility
    //
    // A chart nobody can read is decoration. It gets a spoken summary, and
    // every point is its own element so the series can be walked in order.

    private var spokenSummary: String {
        var parts = ["\(title). \(points.count) days."]
        if let latest = points.last {
            parts.append(
                latest.isMissing
                    ? "Latest day \(latest.label), no data recorded."
                    : "Latest \(latest.label), \(Format.tokens(Int(latest.value.rounded()))) tokens."
            )
        }
        if let peak = measured.max(by: { $0.value < $1.value }) {
            parts.append("Peak \(Format.tokens(Int(peak.value.rounded()))) tokens on \(peak.label).")
        }
        if missingCount > 0 {
            parts.append(
                missingCount == 1
                    ? "1 day has no recorded data and is drawn as a gap."
                    : "\(missingCount) days have no recorded data and are drawn as gaps."
            )
        }
        parts.append("Use left and right arrow keys to read each day.")
        return parts.joined(separator: " ")
    }

    /// Synthetic elements, never rendered, so VoiceOver can walk the series.
    private var pointElements: some View {
        HStack(spacing: 0) {
            ForEach(points) { point in
                Rectangle()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.spokenPoint(point))
            }
        }
    }

    private static func spokenPoint(_ point: ChartPoint) -> String {
        point.isMissing
            ? "\(point.label), no data recorded"
            : "\(point.label), \(Format.tokens(Int(point.value.rounded()))) tokens"
    }
}

// MARK: - Rendering

extension UsageChart {

    /// All drawing lives here, off the view's isolation, taking only values.
    fileprivate static func render(
        points: [ChartPoint],
        geometry: ChartGeometry,
        in context: inout GraphicsContext
    ) {
        guard geometry.plot.width > 0, geometry.plot.height > 0 else { return }
        drawGrid(geometry, in: &context)
        drawMissingMarkers(points: points, geometry: geometry, in: &context)
        drawSeries(points: points, geometry: geometry, in: &context)
        drawXLabels(points: points, geometry: geometry, in: &context)
    }

    // MARK: Grid and y axis

    private static func drawGrid(_ geometry: ChartGeometry, in context: inout GraphicsContext) {
        for tick in geometry.ticks {
            let y = geometry.y(tick)
            var line = Path()
            line.move(to: CGPoint(x: geometry.plot.minX, y: y))
            line.addLine(to: CGPoint(x: geometry.plot.maxX, y: y))
            // The zero line is the floor a measured zero rests on, so it reads
            // as a baseline rather than one gridline among four.
            let isBaseline = tick == 0
            context.stroke(
                line,
                with: .color(isBaseline ? Theme.separator : Theme.track),
                lineWidth: DashboardMetrics.chartGridStroke
            )

            var label = context.resolve(
                Text(Format.tokens(Int(tick.rounded()))).font(Theme.Typography.caption)
            )
            label.shading = .color(Theme.textTertiary)
            context.draw(
                label,
                at: CGPoint(x: geometry.plot.minX - Theme.Space.s, y: y),
                anchor: .trailing
            )
        }
    }

    // MARK: Gaps
    //
    // A dashed vertical rule where a bucket has no answer. Shape, not colour:
    // the dashes are what distinguishes a gap, and the readout and the
    // accessibility label both say so in words.

    private static func drawMissingMarkers(
        points: [ChartPoint],
        geometry: ChartGeometry,
        in context: inout GraphicsContext
    ) {
        var marks = Path()
        for (index, point) in points.enumerated() where point.isMissing {
            let x = geometry.x(index)
            marks.move(to: CGPoint(x: x, y: geometry.plot.minY))
            marks.addLine(to: CGPoint(x: x, y: geometry.plot.maxY))
        }
        guard !marks.isEmpty else { return }
        context.stroke(
            marks,
            with: .color(Theme.textTertiary),
            style: StrokeStyle(
                lineWidth: DashboardMetrics.chartGridStroke,
                dash: DashboardMetrics.chartMissingDash
            )
        )
    }

    // MARK: Series

    private static func drawSeries(
        points: [ChartPoint],
        geometry: ChartGeometry,
        in context: inout GraphicsContext
    ) {
        for run in contiguousRuns(in: points) {
            if run.count == 1 {
                // One measured day between two gaps still has to be visible;
                // a one-point line would draw nothing at all.
                let index = run[0]
                let centre = CGPoint(x: geometry.x(index), y: geometry.y(points[index].value))
                let dot = Path(
                    ellipseIn: CGRect(
                        x: centre.x - DashboardMetrics.chartPointRadius,
                        y: centre.y - DashboardMetrics.chartPointRadius,
                        width: DashboardMetrics.chartPointRadius * 2,
                        height: DashboardMetrics.chartPointRadius * 2
                    )
                )
                context.fill(dot, with: .color(Theme.healthy))
                continue
            }

            var line = Path()
            for (offset, index) in run.enumerated() {
                let point = CGPoint(x: geometry.x(index), y: geometry.y(points[index].value))
                if offset == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }

            var area = line
            area.addLine(to: CGPoint(x: geometry.x(run[run.count - 1]), y: geometry.plot.maxY))
            area.addLine(to: CGPoint(x: geometry.x(run[0]), y: geometry.plot.maxY))
            area.closeSubpath()
            context.fill(
                area,
                with: .color(Theme.healthy.opacity(DashboardMetrics.chartAreaOpacity))
            )

            context.stroke(
                line,
                with: .color(Theme.healthy),
                style: StrokeStyle(
                    lineWidth: DashboardMetrics.chartLineStroke,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
    }

    /// Indices grouped into runs of adjacent measured points. Every gap ends a
    /// run, which is what breaks the line.
    private static func contiguousRuns(in points: [ChartPoint]) -> [[Int]] {
        var runs: [[Int]] = []
        var current: [Int] = []
        for (index, point) in points.enumerated() {
            if point.isMissing {
                if !current.isEmpty { runs.append(current); current = [] }
            } else {
                current.append(index)
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    // MARK: X axis

    private static func drawXLabels(
        points: [ChartPoint],
        geometry: ChartGeometry,
        in context: inout GraphicsContext
    ) {
        let y = geometry.plot.maxY + Theme.Space.xs
        for index in labelledIndices(count: points.count) {
            var label = context.resolve(
                Text(points[index].label).font(Theme.Typography.caption)
            )
            label.shading = .color(Theme.textTertiary)
            // The first and last labels anchor inwards so neither runs off the
            // edge of the plot.
            let anchor: UnitPoint
            if index == 0 {
                anchor = .topLeading
            } else if index == points.count - 1 {
                anchor = .topTrailing
            } else {
                anchor = .top
            }
            context.draw(label, at: CGPoint(x: geometry.x(index), y: y), anchor: anchor)
        }
    }

    private static func labelledIndices(count: Int) -> [Int] {
        guard count > 1 else { return count == 1 ? [0] : [] }
        let stepSize = max(
            1,
            Int(ceil(Double(count) / Double(DashboardMetrics.chartMaximumXLabels)))
        )
        var indices = Array(stride(from: 0, to: count, by: stepSize))
        // Always end on the most recent day unless that would crowd the label
        // before it.
        if let last = indices.last, count - 1 - last >= stepSize / 2, last != count - 1 {
            indices.append(count - 1)
        }
        return indices
    }
}

// MARK: - Geometry

/// Plot rectangle and scales for one render pass. Pure arithmetic; it holds no
/// view state and can be reasoned about without running the app.
struct ChartGeometry: Equatable {
    let plot: CGRect
    let count: Int
    /// Value at the top gridline. Zero means every measured point is zero.
    let axisMax: Double
    let tickStep: Double

    init(size: CGSize, points: [ChartPoint]) {
        let width = max(
            0,
            size.width - DashboardMetrics.chartGutter - DashboardMetrics.chartRightInset
        )
        let height = max(
            0,
            size.height - DashboardMetrics.chartAxisHeight - DashboardMetrics.chartTopInset
        )
        plot = CGRect(
            x: DashboardMetrics.chartGutter,
            y: DashboardMetrics.chartTopInset,
            width: width,
            height: height
        )
        count = points.count
        let peak = points.filter { !$0.isMissing }.map(\.value).max() ?? 0
        let scale = ChartGeometry.scale(forPeak: peak)
        tickStep = scale.step
        axisMax = scale.max
    }

    /// Gridline values, bottom to top. Four at most, and only one when every
    /// measured value is zero: three more would all read zero.
    var ticks: [Double] {
        guard tickStep > 0 else { return [0] }
        return (0...DashboardMetrics.chartTickIntervals).map { tickStep * Double($0) }
    }

    func x(_ index: Int) -> CGFloat {
        guard count > 1 else { return plot.midX }
        return plot.minX + plot.width * CGFloat(index) / CGFloat(count - 1)
    }

    func y(_ value: Double) -> CGFloat {
        // With no scale there is nothing to divide by, and a measured zero
        // belongs on the floor.
        guard axisMax > 0 else { return plot.maxY }
        let fraction = min(1, max(0, value / axisMax))
        return plot.maxY - plot.height * CGFloat(fraction)
    }

    var step: CGFloat {
        count > 1 ? plot.width / CGFloat(count - 1) : plot.width
    }

    func index(atX x: CGFloat) -> Int {
        guard count > 1 else { return 0 }
        let raw = (x - plot.minX) / max(step, 1)
        return min(count - 1, max(0, Int(raw.rounded())))
    }

    /// Round tick values that always cover the peak.
    private static func scale(forPeak peak: Double) -> (step: Double, max: Double) {
        guard peak > 0, peak.isFinite else { return (0, 0) }
        let intervals = Double(DashboardMetrics.chartTickIntervals)
        let raw = peak / intervals
        let magnitude = pow(10, floor(log10(raw)))
        let normalised = raw / magnitude
        // Smallest candidate at or above the raw step, so `step * intervals`
        // is never below the peak and the line can never leave the plot.
        let candidates: [Double] = [1, 1.5, 2, 2.5, 3, 4, 5, 7.5, 10]
        let nice = candidates.first { $0 >= normalised - 1e-9 } ?? 10
        let step = nice * magnitude
        return (step, step * intervals)
    }
}
