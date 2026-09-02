import SwiftUI
import ClaudenceCore

/// Usage over time, drawn by hand.
///
/// One column per day, split into two bands: everything billable as input is
/// the body, output is the cap. Both come straight out of the day's own
/// `TokenUsage` — `billableInput + output == total` by the definition in
/// `CLAUDE.md` — so the split is a partition of the number already shown, not a
/// second measurement that could disagree with the first.
///
/// The one rule it will not bend: **a missing bucket is a gap, not a zero.**
/// A day with no activity is a measured zero, draws no column, and leaves the
/// baseline running underneath it. A day the store could not answer for breaks
/// the baseline and is marked with a dashed rule. Drawing both the same way
/// would report an outage as idleness, and a zero-height column would be
/// indistinguishable from either.
///
/// Drawn with `Path` and `Canvas` rather than a charting framework, so it has
/// no dependency to resolve and every pixel is accounted for here.
///
/// The design grows the columns from the baseline on first paint. That is a
/// one-shot and therefore permitted, but `Canvas` does not interpolate the
/// state its closure reads, so it would need a per-frame animatable driver
/// pushing redraws through a hand-drawn chart. In a process measured against a
/// 0.5% idle budget that is not a trade worth making for an effect seen once,
/// so the columns arrive at their height. Nothing here repeats, by construction
/// rather than by a flag being right.
struct UsageChart: View {
    let points: [ChartPoint]
    /// Output tokens per point, keyed by `ChartPoint.id`.
    ///
    /// A dictionary rather than a field on `ChartPoint` because the split is
    /// optional information: a caller that only has totals passes nothing and
    /// gets single-band columns, which is honest, where a defaulted zero would
    /// claim every day produced no output.
    let outputTokens: [String: Double]
    /// What the series measures, spoken in the accessibility summary.
    let title: String
    let unavailableMessage: String
    let unavailableReason: String?
    let height: CGFloat

    @State private var selectedIndex: Int?
    @FocusState private var isFocused: Bool

    init(
        points: [ChartPoint],
        outputTokens: [String: Double] = [:],
        title: String = "Usage over time",
        unavailableMessage: String = "No usage history",
        unavailableReason: String? = nil,
        height: CGFloat = DashboardMetrics.chartHeight
    ) {
        self.points = points
        self.outputTokens = outputTokens
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

    /// True only when at least one day actually carries a split. With no split
    /// anywhere the legend would name a band that is not drawn.
    private var hasSplit: Bool {
        points.contains { !$0.isMissing && outputTokens[$0.id] != nil }
    }

    private var selectedPoint: ChartPoint? {
        guard let selectedIndex, points.indices.contains(selectedIndex) else { return nil }
        return points[selectedIndex]
    }

    /// The most recent day that was actually measured. It gets the saturated
    /// pair and the ring, because it is the one column a reader is checking
    /// against the others.
    private var latestMeasuredIndex: Int? {
        points.lastIndex(where: { !$0.isMissing })
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
    // Two fixed rows, matching the design's card header: the reading, with the
    // legend opposite it, over a quieter summary line. Fixed height so selecting
    // a column never reflows the sections below it.

    private var readout: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(readoutPrimary)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.m)
                if hasSplit { legend }
            }
            Text(readoutSecondary)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textQuaternary)
                .lineLimit(1)
        }
        .accessibilityHidden(true)
    }

    /// Swatch plus word, never a swatch alone: the bands are only two steps
    /// apart in lightness and somebody who cannot separate them by hue still
    /// has to be able to read the chart.
    private var legend: some View {
        HStack(spacing: Theme.Space.m) {
            legendKey("input", color: Theme.Chart.inputBandLatest)
            legendKey("output", color: Theme.Chart.outputBandLatest)
        }
    }

    private func legendKey(_ label: String, color: Color) -> some View {
        HStack(spacing: Theme.Space.xs) {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(color)
                .frame(width: ColumnMetrics.legendSwatch, height: ColumnMetrics.legendSwatch)
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var readoutPrimary: String {
        guard let point = selectedPoint else { return title }
        guard !point.isMissing else { return "\(point.label) · no data recorded" }
        var text = "\(point.label) · \(Format.tokens(Int(point.value.rounded()))) tokens"
        if let split = split(for: point) {
            text += " · \(Format.tokens(Int(split.input.rounded()))) in"
            text += " / \(Format.tokens(Int(split.output.rounded()))) out"
        }
        return text
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

    /// The two bands for a point, or nil when the caller supplied no split.
    ///
    /// Clamped rather than trusted: the caller owns both numbers, and a cap
    /// taller than its own column would draw outside the chart.
    private func split(for point: ChartPoint) -> (input: Double, output: Double)? {
        guard !point.isMissing, let output = outputTokens[point.id] else { return nil }
        let total = max(0, point.value)
        let capped = min(max(0, output), total)
        return (input: total - capped, output: capped)
    }

    // MARK: - Plot

    private var plot: some View {
        GeometryReader { geo in
            let geometry = ChartGeometry(size: geo.size, points: points)
            Canvas(rendersAsynchronously: false) { context, _ in
                UsageChart.render(
                    points: points,
                    splits: outputTokens,
                    geometry: geometry,
                    latest: latestMeasuredIndex,
                    selected: selectedIndex,
                    in: &context
                )
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
        if hasSplit {
            parts.append("Each column is split into input below and output above.")
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
                    .accessibilityLabel(spokenPoint(point))
            }
        }
    }

    private func spokenPoint(_ point: ChartPoint) -> String {
        guard !point.isMissing else { return "\(point.label), no data recorded" }
        var text = "\(point.label), \(Format.tokens(Int(point.value.rounded()))) tokens"
        if let split = split(for: point) {
            text += ", \(Format.tokens(Int(split.input.rounded()))) input"
            text += ", \(Format.tokens(Int(split.output.rounded()))) output"
        }
        return text
    }
}

// MARK: - Column metrics
//
// Geometry the chart owns and nothing else needs. `DashboardMetrics` holds the
// plot's frame; these are the shape of a single column inside it.

private enum ColumnMetrics {
    /// The design gives a column 74.6 pt of a 90 pt band, so a fifth of the
    /// band is air.
    static let gapRatio: CGFloat = 0.2
    /// A column wider than the design's own stops reading as a column and
    /// starts reading as a slab, which happens as soon as the series is short.
    static let maximumWidth: CGFloat = 74
    static let topRadius: CGFloat = 10
    static let bottomRadius: CGFloat = 4
    /// Outline drawn around the column under the pointer.
    static let selectionStroke: CGFloat = 1.5
    /// The ring on the most recent column: a gap punched in the card colour,
    /// then a hairline outside it.
    static let ringGap: CGFloat = 2.5
    static let ringStroke: CGFloat = 1
    static let legendSwatch: CGFloat = 9
}

// MARK: - Rendering

extension UsageChart {

    /// All drawing lives here, off the view's isolation, taking only values.
    fileprivate static func render(
        points: [ChartPoint],
        splits: [String: Double],
        geometry: ChartGeometry,
        latest: Int?,
        selected: Int?,
        in context: inout GraphicsContext
    ) {
        guard geometry.plot.width > 0, geometry.plot.height > 0 else { return }
        drawGrid(geometry, in: &context)
        drawBaseline(points: points, geometry: geometry, in: &context)
        drawMissingMarkers(points: points, geometry: geometry, selected: selected, in: &context)
        drawColumns(
            points: points,
            splits: splits,
            geometry: geometry,
            latest: latest,
            selected: selected,
            in: &context
        )
        drawXLabels(points: points, geometry: geometry, latest: latest, in: &context)
    }

    // MARK: Grid and y axis

    private static func drawGrid(_ geometry: ChartGeometry, in context: inout GraphicsContext) {
        for tick in geometry.ticks {
            let y = geometry.y(tick)
            // The floor is drawn per band by `drawBaseline`, because whether it
            // runs under a given day is itself information.
            if tick != 0 {
                var line = Path()
                line.move(to: CGPoint(x: geometry.plot.minX, y: y))
                line.addLine(to: CGPoint(x: geometry.plot.maxX, y: y))
                context.stroke(
                    line,
                    with: .color(Theme.Chart.gridline),
                    lineWidth: DashboardMetrics.chartGridStroke
                )
            }

            var label = context.resolve(
                Text(Format.tokens(Int(tick.rounded()))).font(Theme.Typography.micro)
            )
            label.shading = .color(Theme.textQuaternary)
            context.draw(
                label,
                at: CGPoint(x: geometry.plot.minX - Theme.Space.s, y: y),
                anchor: .trailing
            )
        }
    }

    /// The floor, drawn one band at a time and skipped under a day the store
    /// could not answer for. A measured zero keeps its floor, so the break in
    /// the baseline is by itself the difference between "nothing happened" and
    /// "we do not know".
    private static func drawBaseline(
        points: [ChartPoint],
        geometry: ChartGeometry,
        in context: inout GraphicsContext
    ) {
        let y = geometry.plot.maxY
        var floor = Path()
        for index in points.indices where !points[index].isMissing {
            let band = geometry.band(index)
            floor.move(to: CGPoint(x: band.minX, y: y))
            floor.addLine(to: CGPoint(x: band.maxX, y: y))
        }
        guard !floor.isEmpty else { return }
        context.stroke(
            floor,
            with: .color(Theme.Chart.baseline),
            lineWidth: DashboardMetrics.chartGridStroke
        )
    }

    // MARK: Gaps
    //
    // A dashed vertical rule where a bucket has no answer. Shape, not colour:
    // the dashes are what distinguishes a gap, the broken floor confirms it,
    // and the readout and the accessibility label both say so in words.

    private static func drawMissingMarkers(
        points: [ChartPoint],
        geometry: ChartGeometry,
        selected: Int?,
        in context: inout GraphicsContext
    ) {
        for (index, point) in points.enumerated() where point.isMissing {
            let x = geometry.x(index)
            var mark = Path()
            mark.move(to: CGPoint(x: x, y: geometry.plot.minY))
            mark.addLine(to: CGPoint(x: x, y: geometry.plot.maxY))
            context.stroke(
                mark,
                with: .color(index == selected ? Theme.accent : Theme.textQuaternary),
                style: StrokeStyle(
                    lineWidth: DashboardMetrics.chartGridStroke,
                    dash: DashboardMetrics.chartMissingDash
                )
            )
        }
    }

    // MARK: Columns

    private static func drawColumns(
        points: [ChartPoint],
        splits: [String: Double],
        geometry: ChartGeometry,
        latest: Int?,
        selected: Int?,
        in context: inout GraphicsContext
    ) {
        for (index, point) in points.enumerated() where !point.isMissing {
            let total = max(0, point.value)
            // A measured zero sits on the floor and draws nothing. Giving it a
            // stub would make it look like a small day; the unbroken baseline
            // already says it was measured.
            guard total > 0, let rect = geometry.columnRect(index, value: total) else { continue }

            let isLatest = index == latest
            let body = columnPath(rect)
            context.drawLayer { layer in
                layer.clip(to: body)
                layer.fill(
                    Path(rect),
                    with: .color(isLatest ? Theme.Chart.inputBandLatest : Theme.Chart.inputBand)
                )
                if let output = splits[point.id] {
                    let share = min(1, max(0, output / total))
                    let capHeight = rect.height * share
                    guard capHeight > 0 else { return }
                    let cap = CGRect(
                        x: rect.minX,
                        y: rect.minY,
                        width: rect.width,
                        height: capHeight
                    )
                    layer.fill(
                        Path(cap),
                        with: .color(
                            isLatest ? Theme.Chart.outputBandLatest : Theme.Chart.outputBand
                        )
                    )
                }
            }

            if isLatest { drawLatestRing(rect, in: &context) }
            if index == selected {
                context.stroke(
                    body,
                    with: .color(Theme.accent),
                    lineWidth: ColumnMetrics.selectionStroke
                )
            }
        }
    }

    /// The design rings the most recent column with a gap in the card colour and
    /// a hairline outside it, so the emphasis survives whichever band happens to
    /// be on top. The ring never extends below the floor: a column that grew
    /// downwards would read as a negative day.
    private static func drawLatestRing(_ rect: CGRect, in context: inout GraphicsContext) {
        let gap = ColumnMetrics.ringGap
        func expanded(by amount: CGFloat) -> CGRect {
            CGRect(
                x: rect.minX - amount,
                y: rect.minY - amount,
                width: rect.width + amount * 2,
                height: rect.height + amount
            )
        }
        context.stroke(
            columnPath(expanded(by: gap)),
            with: .color(Theme.surfaceRaised),
            lineWidth: gap
        )
        context.stroke(
            columnPath(expanded(by: gap + ColumnMetrics.ringStroke)),
            with: .color(Theme.Chart.latestRing),
            lineWidth: ColumnMetrics.ringStroke
        )
    }

    /// A column: soft at the top where it ends, nearly square at the bottom
    /// where it meets the floor.
    private static func columnPath(_ rect: CGRect) -> Path {
        let limit = min(rect.width, rect.height) / 2
        let top = min(ColumnMetrics.topRadius, limit)
        let bottom = min(ColumnMetrics.bottomRadius, limit)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - bottom))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + top))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + top),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - bottom, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - bottom),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }

    // MARK: X axis

    private static func drawXLabels(
        points: [ChartPoint],
        geometry: ChartGeometry,
        latest: Int?,
        in context: inout GraphicsContext
    ) {
        let y = geometry.plot.maxY + Theme.Space.xs
        for index in labelledIndices(count: points.count) {
            var label = context.resolve(
                Text(points[index].label).font(Theme.Typography.micro)
            )
            // The most recent day is the one the eye is looking for, so its
            // label is inked rather than muted. The label itself stays whatever
            // the caller supplied: this view cannot verify that the series ends
            // today, so it does not write the word.
            label.shading = .color(index == latest ? Theme.textPrimary : Theme.textQuaternary)
            context.draw(label, at: CGPoint(x: geometry.x(index), y: y), anchor: .top)
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
///
/// Columns occupy bands rather than sitting on points: a day is an interval,
/// not an instant, so the first and last columns are inset from the edges of
/// the plot instead of straddling them.
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

    /// Width of one day's slot, air included.
    var bandWidth: CGFloat {
        count > 0 ? plot.width / CGFloat(count) : plot.width
    }

    /// The full slot for a day, used by the floor and by hit testing.
    func band(_ index: Int) -> CGRect {
        CGRect(
            x: plot.minX + bandWidth * CGFloat(index),
            y: plot.minY,
            width: bandWidth,
            height: plot.height
        )
    }

    /// Centre of a day's slot.
    func x(_ index: Int) -> CGFloat {
        guard count > 0 else { return plot.midX }
        return plot.minX + bandWidth * (CGFloat(index) + 0.5)
    }

    func y(_ value: Double) -> CGFloat {
        // With no scale there is nothing to divide by, and a measured zero
        // belongs on the floor.
        guard axisMax > 0 else { return plot.maxY }
        let fraction = min(1, max(0, value / axisMax))
        return plot.maxY - plot.height * CGFloat(fraction)
    }

    /// The drawn rectangle for a day, or nil when there is no scale to draw
    /// against. A non-zero day is floored to a visible height rather than
    /// rounding away, the same minimum-fill rule the power meter tubes use.
    func columnRect(_ index: Int, value: Double) -> CGRect? {
        guard axisMax > 0, plot.height > 0 else { return nil }
        let width = min(bandWidth * (1 - ColumnMetrics.gapRatio), ColumnMetrics.maximumWidth)
        guard width > 0 else { return nil }
        let floorHeight = plot.height * CGFloat(Theme.Bar.minimumVisibleFill)
        let height = max(plot.maxY - y(value), floorHeight)
        return CGRect(
            x: x(index) - width / 2,
            y: plot.maxY - height,
            width: width,
            height: height
        )
    }

    func index(atX x: CGFloat) -> Int {
        guard count > 1 else { return 0 }
        let raw = (x - plot.minX) / max(bandWidth, 1)
        return min(count - 1, max(0, Int(floor(raw))))
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
