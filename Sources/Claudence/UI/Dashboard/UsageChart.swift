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
/// The design grows the columns from the baseline, once per series, and that is
/// what `growth` drives. `Canvas` does not interpolate the state its closure
/// reads, so the number reaches the drawing through `ColumnCanvas`, which
/// conforms to `Animatable` and therefore does get re-evaluated per frame.
///
/// The per-frame redraw is the reason this is a one-shot and never a repeat.
/// `MenuBarExtra(style: .window)` keeps its content mounted after the popover is
/// dismissed, so a repeating animation would drive that redraw at the refresh
/// rate for the life of the process, against a 0.5% idle budget. Firing once
/// when the series changes means an idle chart costs nothing by construction,
/// not because a visibility flag happened to be right. Reduce Motion and the
/// Live indicators preference both leave `growth` settled at 1, which is also
/// its initial value, so a chart that never animates is simply drawn.
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
    let title: Phrase
    /// The quiet line under the title, where the design says what the figures
    /// were measured from. Nil leaves the chart's own summary there.
    let caption: Phrase?
    /// What to print on the final column's axis cell in place of its own label.
    ///
    /// The chart cannot prove that the last bucket is the current day: it is
    /// handed labels, not dates. So the word arrives from the caller that built
    /// the series and knows, and a caller that does not know passes nothing and
    /// gets the label it supplied.
    let latestLabel: Phrase?
    let unavailableMessage: Phrase
    let unavailableReason: Phrase?
    let height: CGFloat

    @State private var selectedIndex: Int?
    /// How far the columns have grown out of the baseline, 0 to 1.
    ///
    /// Starts settled rather than at zero. A chart that will not animate at all
    /// (Reduce Motion, Live indicators off, or a preview that never runs its
    /// task) then draws its real heights on the first pass instead of drawing an
    /// empty plot and waiting for something to move it.
    @State private var growth: Double = 1
    @FocusState private var isFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.liveIndicators) private var liveIndicators
    @Environment(\.appLanguage) private var language

    init(
        points: [ChartPoint],
        outputTokens: [String: Double] = [:],
        title: Phrase = Strings.defaultTitle,
        caption: Phrase? = nil,
        latestLabel: Phrase? = nil,
        unavailableMessage: Phrase = Strings.noUsageHistory,
        unavailableReason: Phrase? = nil,
        height: CGFloat = DashboardMetrics.chartHeight
    ) {
        self.points = points
        self.outputTokens = outputTokens
        self.title = title
        self.caption = caption
        self.latestLabel = latestLabel
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

    /// Identity of the series, and the only thing that restarts the growth.
    ///
    /// The ids and the count, not the values: a range the reader switched to is
    /// a new chart and earns the sweep, where the same range ticking up as
    /// tokens are spent is the same chart and must not replay it. The count is
    /// carried explicitly so that two different series whose ids happen to
    /// concatenate to the same string still differ.
    private var seriesKey: String {
        "\(points.count):" + points.map(\.id).joined(separator: "|")
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
                    // The design gives every metric an explanation on hover and
                    // the text for this one was already written; nothing was
                    // attached to it, so the chart was the one card on the
                    // dashboard that could not say where its figures came from.
                    // Only while no column is selected: with one selected this
                    // line is that column's readout, which the tip does not
                    // describe.
                    .tooltip(selectedPoint == nil ? TooltipText.tip("chart") : nil)
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
            legendKey(Strings.legendInput, color: Theme.Chart.inputBandLatest)
            // The legend takes the band's own colour, not the emphasis the
            // most recent column is painted in: a key drawn in the Today
            // column's ink was naming a colour that appears on one column.
            legendKey(Strings.legendOutput, color: Theme.Chart.outputBand)
        }
    }

    private func legendKey(_ label: Phrase, color: Color) -> some View {
        HStack(spacing: Theme.Space.xs) {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(color)
                .frame(width: ColumnMetrics.legendSwatch, height: ColumnMetrics.legendSwatch)
            PhraseText(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var readoutPrimary: String {
        guard let point = selectedPoint else { return title.string(in: language) }
        guard !point.isMissing else {
            return Strings.noDataRecorded.format(in: language, point.label)
        }
        var text = Strings.pointTokens.format(
            in: language,
            point.label,
            Format.tokens(Int(point.value.rounded()))
        )
        if let split = split(for: point) {
            text += Strings.pointSplit.format(
                in: language,
                Format.tokens(Int(split.input.rounded())),
                Format.tokens(Int(split.output.rounded()))
            )
        }
        return text
    }

    private var readoutSecondary: String {
        if selectedPoint != nil { return Strings.keyboardHint.string(in: language) }
        var parts: [String] = []
        if let caption { parts.append(caption.string(in: language)) }
        parts.append(Strings.dayCount.format(in: language, "\(points.count)"))
        if let peak = measured.max(by: { $0.value < $1.value }) {
            parts.append(
                Strings.peakOn.format(
                    in: language,
                    Format.tokens(Int(peak.value.rounded())),
                    peak.label
                )
            )
        }
        if missingCount > 0 {
            parts.append(
                missingCount == 1
                    ? Strings.oneGap.string(in: language)
                    : Strings.gapCount.format(in: language, "\(missingCount)")
            )
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
            ColumnCanvas(
                points: points,
                splits: outputTokens,
                geometry: geometry,
                latest: latestMeasuredIndex,
                latestLabel: latestLabel?.string(in: language),
                selected: selectedIndex,
                growth: growth
            )
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
        .task(id: seriesKey) { await grow() }
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

    /// Runs the columns out of the baseline, once, whenever the series changes.
    ///
    /// The reset to zero is deliberately committed as its own frame before the
    /// animated change is made. Setting 0 and 1 in the same run loop turn would
    /// collapse into a single transaction whose starting value is already the
    /// final one, and the columns would appear at full height with no sweep at
    /// all. Yielding is not enough on its own to guarantee a rendered frame, so
    /// this waits roughly one of them.
    ///
    /// Nothing here loops. The task is bound to `seriesKey`, so it runs when the
    /// series it draws is replaced and not otherwise.
    private func grow() async {
        // Both preferences fully still the chart, and stillness means the real
        // heights, not a zero that never leaves the floor.
        guard Theme.valueAnimation(reduceMotion: reduceMotion, liveIndicators: liveIndicators) != nil
        else {
            growth = 1
            return
        }
        growth = 0
        try? await Task.sleep(for: .milliseconds(16))
        guard !Task.isCancelled else { return }
        withAnimation(Theme.Motion.chartGrow) { growth = 1 }
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
        var parts = [
            Strings.spokenTitleDayCount.format(in: language, title.string(in: language), "\(points.count)")
        ]
        if let latest = points.last {
            parts.append(
                latest.isMissing
                    ? Strings.spokenLatestMissing.format(in: language, latest.label)
                    : Strings.spokenLatest.format(
                        in: language,
                        latest.label,
                        Format.tokens(Int(latest.value.rounded()))
                    )
            )
        }
        if let peak = measured.max(by: { $0.value < $1.value }) {
            parts.append(
                Strings.spokenPeak.format(
                    in: language,
                    Format.tokens(Int(peak.value.rounded())),
                    peak.label
                )
            )
        }
        if hasSplit {
            parts.append(Strings.spokenSplitExplainer.string(in: language))
        }
        if missingCount > 0 {
            parts.append(
                missingCount == 1
                    ? Strings.spokenOneGap.string(in: language)
                    : Strings.spokenGapCount.format(in: language, "\(missingCount)")
            )
        }
        parts.append(Strings.spokenArrowHint.string(in: language))
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
        guard !point.isMissing else {
            return Strings.spokenPointMissing.format(in: language, point.label)
        }
        var text = Strings.spokenPointTokens.format(
            in: language,
            point.label,
            Format.tokens(Int(point.value.rounded()))
        )
        if let split = split(for: point) {
            text += Strings.spokenPointSplit.format(
                in: language,
                Format.tokens(Int(split.input.rounded())),
                Format.tokens(Int(split.output.rounded()))
            )
        }
        return text
    }
}

// MARK: - Strings

private enum Strings {
    static let defaultTitle = Phrase(en: "Usage over time", th: "การใช้งานตามเวลา")
    static let noUsageHistory = Phrase(en: "No usage history", th: "ยังไม่มีประวัติการใช้งาน")

    static let legendInput = Phrase.untranslated("input")
    static let legendOutput = Phrase.untranslated("output")

    static let noDataRecorded = Phrase(en: "%@ · no data recorded", th: "%@ · ไม่มีข้อมูลบันทึกไว้")
    static let pointTokens = Phrase(en: "%@ · %@ tokens", th: "%@ · %@ token")
    static let pointSplit = Phrase(en: " · %@ in / %@ out", th: " · %@ เข้า / %@ ออก")
    static let keyboardHint = Phrase(
        en: "Arrow keys to move, Escape to clear",
        th: "ใช้ปุ่มลูกศรเพื่อเลื่อน กด Escape เพื่อล้าง"
    )
    static let dayCount = Phrase(en: "%@ days", th: "%@ วัน")
    static let peakOn = Phrase(en: "peak %@ on %@", th: "สูงสุด %@ เมื่อ %@")
    static let oneGap = Phrase(en: "1 gap", th: "ขาดข้อมูล 1 จุด")
    static let gapCount = Phrase(en: "%@ gaps", th: "ขาดข้อมูล %@ จุด")

    static let spokenTitleDayCount = Phrase(en: "%@. %@ days.", th: "%@ %@ วัน")
    static let spokenLatestMissing = Phrase(
        en: "Latest day %@, no data recorded.",
        th: "วันล่าสุด %@ ไม่มีข้อมูลบันทึกไว้"
    )
    static let spokenLatest = Phrase(
        en: "Latest %@, %@ tokens.",
        th: "ล่าสุด %@ จำนวน %@ token"
    )
    static let spokenPeak = Phrase(
        en: "Peak %@ tokens on %@.",
        th: "สูงสุด %@ token เมื่อ %@"
    )
    static let spokenSplitExplainer = Phrase(
        en: "Each column is split into input below and output above.",
        th: "แต่ละแท่งแบ่งเป็น input ด้านล่างและ output ด้านบน"
    )
    static let spokenOneGap = Phrase(
        en: "1 day has no recorded data and is drawn as a gap.",
        th: "มี 1 วันที่ไม่มีข้อมูลบันทึกไว้ และวาดเป็นช่องว่าง"
    )
    static let spokenGapCount = Phrase(
        en: "%@ days have no recorded data and are drawn as gaps.",
        th: "มี %@ วันที่ไม่มีข้อมูลบันทึกไว้ และวาดเป็นช่องว่าง"
    )
    static let spokenArrowHint = Phrase(
        en: "Use left and right arrow keys to read each day.",
        th: "ใช้ปุ่มลูกศรซ้ายและขวาเพื่ออ่านข้อมูลแต่ละวัน"
    )

    static let spokenPointMissing = Phrase(en: "%@, no data recorded", th: "%@ ไม่มีข้อมูลบันทึกไว้")
    static let spokenPointTokens = Phrase(en: "%@, %@ tokens", th: "%@ จำนวน %@ token")
    static let spokenPointSplit = Phrase(
        en: ", %@ input, %@ output",
        th: ", input %@, output %@"
    )
}

// MARK: - Drawing surface

/// The chart's `Canvas`, wrapped so the growth can actually be interpolated.
///
/// `Canvas` hands its drawing closure a `GraphicsContext`, and that closure is
/// not an animatable attribute: under `withAnimation` SwiftUI would swap one
/// closure for another and the columns would jump from the floor to full height
/// in a single frame. Conforming the view that carries the number to
/// `Animatable` is what turns `growth` into a per-frame driver, because SwiftUI
/// interpolates `animatableData` and re-evaluates this body at every step.
///
/// A separate view rather than `UsageChart` itself conforming: `Animatable`
/// re-runs the body it is attached to at the refresh rate while the animation
/// lasts, and the chart's body also builds the readout, the legend and the
/// accessibility children, none of which move. Only the surface that redraws
/// should pay for the redraw.
private struct ColumnCanvas: View, Animatable {
    let points: [ChartPoint]
    let splits: [String: Double]
    let geometry: ChartGeometry
    let latest: Int?
    let latestLabel: String?
    let selected: Int?
    var growth: Double

    /// `nonisolated` because `View` carries main actor isolation onto everything
    /// declared here, while `Animatable` does not: the interpolation is a plain
    /// read and write of one `Double` on a value type, and the conformance will
    /// not compile under Swift 6 without saying so.
    nonisolated var animatableData: Double {
        get { growth }
        set { growth = newValue }
    }

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            UsageChart.render(
                points: points,
                splits: splits,
                geometry: geometry,
                latest: latest,
                latestLabel: latestLabel,
                selected: selected,
                growth: growth,
                in: &context
            )
        }
    }
}

// MARK: - Column metrics
//
// Geometry the chart owns and nothing else needs. `DashboardMetrics` holds the
// plot's frame; these are the shape of a single column inside it.

private enum ColumnMetrics {
    /// The design gives a column 74.6 pt of a 90 pt band, so a sixth of the
    /// band is air: `1 - 74.6 / 90`, not the fifth an earlier rounding used.
    static let gapRatio: CGFloat = 0.17
    /// A column wider than the design's own stops reading as a column and
    /// starts reading as a slab, which happens as soon as the series is short.
    static let maximumWidth: CGFloat = 74
    static let topRadius: CGFloat = Theme.Radius.ChartColumn.top
    static let bottomRadius: CGFloat = Theme.Radius.ChartColumn.bottom
    /// Outline drawn around the column under the pointer.
    static let selectionStroke: CGFloat = 1.5
    /// The ring on the most recent column: a gap punched in the card colour,
    /// then a hairline outside it.
    static let ringGap: CGFloat = 2
    static let ringStroke: CGFloat = 1
    static let legendSwatch: CGFloat = 9
}

// MARK: - Rendering

extension UsageChart {

    /// All drawing lives here, off the view's isolation, taking only values.
    ///
    /// `growth` runs 0 to 1: 0 leaves every column flat on the floor, 1 draws
    /// the measured heights. It is a drawing instruction and nothing else, so no
    /// figure the chart reports is affected by it.
    fileprivate static func render(
        points: [ChartPoint],
        splits: [String: Double],
        geometry: ChartGeometry,
        latest: Int?,
        latestLabel: String?,
        selected: Int?,
        growth: Double,
        in context: inout GraphicsContext
    ) {
        guard geometry.plot.width > 0, geometry.plot.height > 0 else { return }
        // The frame the chart is measured against does not move: the grid, the
        // floor, the gap markers and the axis are drawn at full strength from
        // the first frame, so the columns grow into a scale that is already
        // readable rather than into an empty rectangle.
        drawGrid(geometry, in: &context)
        drawBaseline(points: points, geometry: geometry, in: &context)
        drawMissingMarkers(points: points, geometry: geometry, selected: selected, in: &context)
        drawColumns(
            points: points,
            splits: splits,
            geometry: geometry,
            latest: latest,
            selected: selected,
            growth: growth,
            in: &context
        )
        drawXLabels(
            points: points,
            geometry: geometry,
            latest: latest,
            latestLabel: latestLabel,
            in: &context
        )
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
        growth: Double,
        in context: inout GraphicsContext
    ) {
        for (index, point) in points.enumerated() where !point.isMissing {
            let total = max(0, point.value)
            // A measured zero sits on the floor and draws nothing. Giving it a
            // stub would make it look like a small day; the unbroken baseline
            // already says it was measured.
            guard total > 0, let full = geometry.columnRect(index, value: total) else { continue }

            // A column that has not started yet draws nothing at all, exactly
            // like the measured zero above. A hairline waiting on the floor
            // would be indistinguishable from a real, very small day for as
            // long as it sat there.
            let progress = columnProgress(index, count: points.count, growth: growth)
            guard progress > 0 else { continue }
            let rect = grown(full, to: progress, baseline: geometry.plot.maxY)

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

    /// How far one column has travelled, given how far the whole sweep has.
    ///
    /// The columns do not arrive together. Each one starts a little after the
    /// one to its left, which walks the eye across the range in the direction
    /// the axis is read: oldest day first, most recent day last, so the column
    /// the reader is looking for is the one that lands under their attention.
    /// Landing them simultaneously says nothing about the order of the days.
    ///
    /// `chartGrowStagger` is the share of the sweep spent handing out those
    /// start times; what is left, `1 - stagger`, is how long any single column
    /// takes. So the last column starts at `stagger` and finishes exactly with
    /// the animation, and no column is still moving after the sweep is over.
    ///
    /// A single point has no left-to-right to express and takes the sweep whole.
    static func columnProgress(_ index: Int, count: Int, growth: Double) -> Double {
        guard count > 1 else { return growth }
        let stagger = Theme.Motion.chartGrowStagger
        // A stagger of 1 would leave a column no time to travel in, and the
        // division below no denominator. Guarded rather than assumed, because
        // the value is a token somebody may reasonably retune.
        guard stagger < 1 else { return growth >= 1 ? 1 : 0 }
        let start = stagger * Double(index) / Double(count - 1)
        return min(1, max(0, (growth - start) / (1 - stagger)))
    }

    /// The column as drawn part way through its growth.
    ///
    /// Scaled from the baseline rather than from the top, so the column rises
    /// out of the floor instead of sliding down onto it. Everything keyed off
    /// `rect.height` follows for free: the output band keeps its share of a
    /// shorter column, and the ring on the most recent day is drawn around the
    /// height the column actually has, so it never hangs in the air above one
    /// that has not arrived.
    private static func grown(
        _ rect: CGRect,
        to progress: Double,
        baseline: CGFloat
    ) -> CGRect {
        guard progress < 1 else { return rect }
        let height = rect.height * CGFloat(progress)
        return CGRect(x: rect.minX, y: baseline - height, width: rect.width, height: height)
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
        latestLabel: String?,
        in context: inout GraphicsContext
    ) {
        let y = geometry.plot.maxY + Theme.Space.xs
        for index in labelledIndices(count: points.count) {
            let isLatest = index == latest
            // The design's final cell reads `Today`. This view cannot verify
            // that the series ends today, so it prints the word only when the
            // caller supplied it and prints the point's own label otherwise.
            let text = isLatest ? (latestLabel ?? points[index].label) : points[index].label
            var label = context.resolve(
                Text(text).font(
                    isLatest ? Theme.Typography.microEmphasis : Theme.Typography.micro
                )
            )
            // The most recent day is the one the eye is looking for, so its
            // label is inked rather than muted.
            label.shading = .color(isLatest ? Theme.textPrimary : Theme.textQuaternary)
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
