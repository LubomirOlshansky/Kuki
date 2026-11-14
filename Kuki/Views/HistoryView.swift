import Accessibility
import Charts
import SwiftData
import SwiftUI

/// 記録 — how the air changed, and how the places compare.
struct HistoryView: View {
    @Environment(Recorder.self) private var recorder
    @Environment(AppNav.self) private var nav
    @Environment(\.modelContext) private var context

    var body: some View {
        @Bindable var nav = nav
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageTitle(kanji: "記録", title: "History") { shareMenu }
                    .padding(.top, 12)

                Picker("Range", selection: $nav.historyRange) {
                    ForEach(ChartRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                HistoryBody(range: nav.historyRange, metric: $nav.historyMetric, limit: recorder.co2Limit,
                            intervalMinutes: recorder.intervalMinutes, filter: recorder.sensorFilter)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .paperBackground()
    }

    /// Share what the chart shows: the same period, as a spreadsheet or as a
    /// brief for an AI assistant.
    private var shareMenu: some View {
        Menu {
            ShareLink(item: file(.csv), preview: SharePreview("Kūki air log (CSV)")) {
                Label("Spreadsheet (CSV)", systemImage: "tablecells")
            }
            ShareLink(item: file(.markdown), preview: SharePreview("Kūki air log (Markdown)")) {
                Label("For Claude or ChatGPT", systemImage: "doc.text")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.title3)
                .foregroundStyle(Ink.ink)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .quietHover(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(QuietButtonStyle())
        .menuIndicator(.hidden)
        .accessibilityLabel("Share the \(nav.historyRange.spokenTitle)")
        .help("Share the \(nav.historyRange.spokenTitle) as a file")
    }

    private func file(_ kind: ExportFile.Kind) -> ExportFile {
        ExportFile(kind: kind, since: nav.historyRange.start, limit: recorder.co2Limit, sensor: recorder.sensorName,
                   filter: recorder.sensorFilter, container: context.container,
                   reportRange: nav.historyRange.rawValue)
    }
}

enum ChartRange: String, CaseIterable, Identifiable, Sendable {
    case hours3, day, week, month
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hours3: "3 h"
        case .day: "24 h"
        case .week: "7 d"
        case .month: "30 d"
        }
    }
    var seconds: Double {
        switch self {
        case .hours3: 3 * 3600
        case .day: 24 * 3600
        case .week: 7 * 24 * 3600
        case .month: 30 * 24 * 3600
        }
    }
    var start: Date { .now.addingTimeInterval(-seconds) }
    var spokenTitle: String {
        switch self {
        case .hours3: "last 3 hours"
        case .day: "last 24 hours"
        case .week: "last 7 days"
        case .month: "last 30 days"
        }
    }
    /// Short axis labels that never collide: hours for a day, days for longer.
    var axisFormat: Date.FormatStyle {
        switch self {
        case .hours3: .dateTime.hour().minute()
        case .day: .dateTime.hour()
        case .week: .dateTime.weekday(.abbreviated)
        case .month: .dateTime.day().month(.abbreviated)
        }
    }
    /// How a selected moment is written in the chart's readout.
    var readoutFormat: Date.FormatStyle {
        switch self {
        case .hours3, .day: .dateTime.hour().minute()
        case .week, .month: .dateTime.weekday(.abbreviated).hour().minute()
        }
    }
    /// Bucket size that keeps the chart around a few hundred points.
    var bucketMinutes: Int {
        switch self {
        case .hours3: 1
        case .day: 5
        case .week: 30
        case .month: 120
        }
    }
}

/// Everything the History screen draws, computed off the main actor from
/// `Exporter.fetchRows` (tens of thousands of rows over 30 days).
struct HistoryModel: Sendable, Equatable {
    struct Series: Sendable, Equatable, Identifiable {
        let key: String
        let name: String
        var id: String { key }
    }

    /// What the model was built for — a new key crossfades the chart.
    struct Key: Hashable, Sendable {
        let range: ChartRange
        let metric: Metric
    }

    var key = Key(range: .day, metric: .co2)
    var points: [HistoryBody.ChartPoint] = []
    /// Stretches where nothing was recorded at all.
    var gaps: [HistoryBody.Gap] = []
    var series: [Series] = []
    var stats: [PlaceStats] = []
    var rowCount = 0

    static func build(_ rows: [Row], range: ChartRange, metric: Metric, limit: Double, intervalMinutes: Int) -> HistoryModel {
        let downsampled = Exporter.downsample(rows, minutes: range.bucketMinutes)
        let gap = HistoryBody.segmentGap(bucketMinutes: range.bucketMinutes, intervalMinutes: intervalMinutes)
        let points = HistoryBody.segments(downsampled, gap: gap, metric: metric)
        return HistoryModel(key: Key(range: range, metric: metric), points: points,
                            gaps: HistoryBody.gaps(points, threshold: gap), series: orderedSeries(rows),
                            stats: PlaceStats.compute(rows, limit: limit), rowCount: rows.count)
    }

    /// Places in order of first appearance, keyed by place (not name), with
    /// names made unique — a deleted "Bedroom" and a new one stay apart.
    static func orderedSeries(_ rows: [Row]) -> [Series] {
        var seen: [String: String] = [:]
        var order: [String] = []
        for r in rows {
            if seen[r.placeKey] == nil { order.append(r.placeKey) }
            seen[r.placeKey] = r.place // the latest name wins
        }
        var used = Set<String>()
        return order.map { key in
            var name = seen[key] ?? ""
            var n = 2
            while used.contains(name) { name = "\(seen[key] ?? "") (\(n))"; n += 1 }
            used.insert(name)
            return Series(key: key, name: name)
        }
    }

    /// The plotted point closest in time to `time`.
    func nearest(to time: Date) -> HistoryBody.ChartPoint? {
        Self.nearest(in: points, to: time)
    }

    /// Binary search over time-ordered points.
    static func nearest(in points: [HistoryBody.ChartPoint], to time: Date) -> HistoryBody.ChartPoint? {
        guard !points.isEmpty else { return nil }
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].time < time { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(points[lo - 1].time.timeIntervalSince(time)) <= abs(points[lo].time.timeIntervalSince(time)) {
            return points[lo - 1]
        }
        return points[lo]
    }
}

struct HistoryBody: View {
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let range: ChartRange
    @Binding var metric: Metric
    let limit: Double
    let intervalMinutes: Int
    let filter: SensorFilter

    @State private var model: HistoryModel?
    /// The moment under the finger (or, on the Mac, the pointer).
    @State private var selectedTime: Date?

    private struct LoadKey: Hashable {
        let range: ChartRange, metric: Metric, limit: Double, interval: Int, filter: SensorFilter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            VStack(alignment: .leading, spacing: 8) {
                metricMenu
                if let model, model.rowCount >= 2 {
                    // The chart's takeaway, in words (HIG › Charting data).
                    Text(Self.headline(model.stats, metric: model.key.metric, limit: limit))
                        .font(Typeface.title)
                        .foregroundStyle(Ink.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(model.key)
                        .transition(.opacity)
                }
            }

            if let model {
                if model.rowCount < 2 {
                    Text(emptyText)
                        .font(Typeface.body)
                        .foregroundStyle(Ink.inkSoft)
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    chart(model)
                        .frame(height: 280)
                        .id(model.key)
                        .transition(.opacity)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("By place").kukiLabel()
                        Text("Settling minutes after each move are left out.")
                            .font(.caption)
                            .foregroundStyle(Ink.inkSoft)
                    }
                    VStack(spacing: 0) {
                        let scale = model.stats.compactMap { $0.average(model.key.metric) }.max() ?? 1
                        ForEach(model.stats) { s in
                            let index = seriesIndex(s.key, in: model)
                            PlaceStatRow(stats: s, metric: model.key.metric, limit: limit,
                                         color: Ink.series[index % Ink.series.count],
                                         symbol: differentiateWithoutColor ? Self.symbols[index % Self.symbols.count] : nil,
                                         scaleMax: scale)
                            Hairline()
                        }
                    }
                }
            } else {
                ProgressView()
                    .tint(Ink.inkSoft)
                    .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .task(id: LoadKey(range: range, metric: metric, limit: limit, interval: intervalMinutes, filter: filter)) {
            // Re-read every minute; `since` moves with the clock each time.
            let container = context.container
            let (range, metric, limit, interval, filter) = (range, metric, limit, intervalMinutes, filter)
            while !Task.isCancelled {
                let since = range.start
                let built = await Task.detached(priority: .userInitiated) {
                    let rows = (try? Exporter.fetchRows(container: container, since: since, filter: filter)) ?? []
                    return HistoryModel.build(rows, range: range, metric: metric, limit: limit, intervalMinutes: interval)
                }.value
                if Task.isCancelled { break }
                if built != model {
                    if built.key != model?.key {
                        // A different question: crossfade, never morph one
                        // metric's line into another's.
                        selectedTime = nil
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { model = built }
                    } else {
                        model = built // the minute's refresh: no animation
                    }
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Which value the page is about — CO₂, temperature, humidity or PM2.5 —
    /// as visible buttons: a menu hid them too well.
    private var metricMenu: some View {
        Picker("Value", selection: $metric) {
            ForEach(Metric.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Value shown")
        .help("Choose which value the chart shows")
    }

    private var emptyText: String {
        let every = intervalMinutes <= 1 ? "every minute" : "every \(intervalMinutes) minutes"
        #if targetEnvironment(macCatalyst)
        // On the Mac, Kūki records from the menu bar, window open or not.
        return "Nothing recorded in this period yet. Kūki records \(every) while it's in the menu bar."
        #else
        return "Nothing recorded in this period yet. Keep Kūki open — it records \(every)."
        #endif
    }

    private func seriesIndex(_ key: String, in model: HistoryModel) -> Int {
        model.series.firstIndex { $0.key == key } ?? 0
    }

    struct Gap: Identifiable, Sendable, Equatable {
        let id: Int
        let from: ChartPoint
        let to: ChartPoint
        var middle: Date { from.time.addingTimeInterval(to.time.timeIntervalSince(from.time) / 2) }
        /// Both ends are the same place: its line breaks here, and the
        /// faint dashed "no data" bridge stands in for it. Between two
        /// places nothing is drawn across — that would join them.
        var isBridged: Bool { from.placeKey == to.placeKey }
    }

    /// Stretches longer than `threshold` seconds in which *nothing* was
    /// recorded, at any place. (A place's line also breaks where the sensor
    /// was somewhere else for that long, but that isn't "no data".)
    nonisolated static func gaps(_ points: [ChartPoint], threshold: TimeInterval) -> [Gap] {
        let sorted = points.sorted { $0.time < $1.time }
        var out: [Gap] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) where b.time.timeIntervalSince(a.time) > threshold {
            out.append(Gap(id: out.count, from: a, to: b))
        }
        return out
    }

    /// Padding around non-CO₂ values so a steady temperature isn't a flat
    /// line glued to the frame.
    nonisolated static func domain(for values: [Double]) -> ClosedRange<Double> {
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let pad = max((hi - lo) * 0.2, max(abs(hi) * 0.02, 0.5))
        return (lo - pad)...(hi + pad)
    }

    static let symbols: [BasicChartSymbolShape] = [.circle, .square, .triangle, .diamond, .pentagon, .cross]
    /// A stretch of one reading: a small dot, the same in every mode (with
    /// the place's shape when colour alone mustn't carry it).
    static let loneSymbolSize: CGFloat = 20
    static let dashes: [[CGFloat]] = [[], [6, 3], [1.5, 3], [8, 3, 1.5, 3], [3, 3], [10, 4]]

    private func chart(_ model: HistoryModel) -> some View {
        let metric = model.key.metric
        let range = model.key.range
        let names = Dictionary(uniqueKeysWithValues: model.series.map { ($0.key, $0.name) })
        let domain = model.series.map(\.name)
        let selected = selectedTime.flatMap { model.nearest(to: $0) }
        let values = model.points.map(\.value)
        let co2Scale = TraceScale(values: values, limit: limit)
        return Chart {
            if metric == .co2 && co2Scale.showsLimit {
                RuleMark(y: .value("Limit", limit))
                    .foregroundStyle(Ink.shu.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 0.75, dash: [3, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("limit \(Metric.co2.format(limit))").font(.caption2).foregroundStyle(Ink.shu)
                    }
            }
            // One line per stretch of a place: colour says which place, and
            // a place's line breaks wherever *its* readings pause for longer
            // than the range's gap (`segmentGap`), so a line never bridges
            // time that wasn't observed. The series is a string unique to
            // that stretch — never a bare number, which Charts may not treat
            // as a category, joining every stretch of a place into one curve.
            // `.monotone` can't overshoot past the readings the way
            // Catmull-Rom does. A stretch of one point is a dot.
            ForEach(model.points) { p in
                let place = names[p.placeKey] ?? p.place
                let index = seriesIndex(p.placeKey, in: model)
                if p.isSingle {
                    PointMark(x: .value("Time", p.time), y: .value(metric.title, p.value))
                        .foregroundStyle(by: .value("Place", place))
                        .symbol(by: .value("Place", place))
                        .symbolSize(Self.loneSymbolSize)
                } else if differentiateWithoutColor {
                    // Shape and dash carry the place too, not colour alone.
                    LineMark(x: .value("Time", p.time), y: .value(metric.title, p.value),
                             series: .value("Line", p.series))
                        .foregroundStyle(by: .value("Place", place))
                        .lineStyle(StrokeStyle(lineWidth: 1.4, dash: Self.dashes[index % Self.dashes.count]))
                        .interpolationMethod(.monotone)
                        .symbol(by: .value("Place", place))
                        .symbolSize(14)
                } else {
                    LineMark(x: .value("Time", p.time), y: .value(metric.title, p.value),
                             series: .value("Line", p.series))
                        .foregroundStyle(by: .value("Place", place))
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                        .interpolationMethod(.monotone)
                }
            }

            // Stretches with no readings at all (the app was closed, or not
            // in front): a place's line resumes after a faint dashed bridge,
            // labelled when the gap is wide enough. Never drawn from one
            // place to another.
            ForEach(model.gaps) { gap in
                if gap.isBridged {
                    LineMark(x: .value("Time", gap.from.time), y: .value(metric.title, gap.from.value),
                             series: .value("Line", "gap-\(gap.id)"))
                        .foregroundStyle(Ink.inkFaint)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    LineMark(x: .value("Time", gap.to.time), y: .value(metric.title, gap.to.value),
                             series: .value("Line", "gap-\(gap.id)"))
                        .foregroundStyle(Ink.inkFaint)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                }
                if gap.to.time.timeIntervalSince(gap.from.time) > range.seconds * 0.12 {
                    PointMark(x: .value("Time", gap.middle), y: .value(metric.title, (gap.from.value + gap.to.value) / 2))
                        .opacity(0)
                        .annotation(position: .top, spacing: 2) {
                            Text("no data").font(.caption2).foregroundStyle(Ink.inkSoft)
                        }
                }
            }

            // The readout: a hairline at the chosen moment and what the air was.
            if let selected {
                let place = names[selected.placeKey] ?? selected.place
                RuleMark(x: .value("Selected", selected.time))
                    .foregroundStyle(Ink.inkFaint)
                    .lineStyle(StrokeStyle(lineWidth: 0.75))
                    .annotation(position: .top, alignment: .center, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        ChartReadout(value: "\(metric.format(selected.value)) \(metric.unit)",
                                     detail: "\(place) · \(selected.time.formatted(range.readoutFormat))")
                    }
                PointMark(x: .value("Selected", selected.time), y: .value(metric.title, selected.value))
                    .foregroundStyle(Ink.ink)
                    .symbolSize(36)
            }
        }
        .chartForegroundStyleScale(domain: domain, range: domain.indices.map { Ink.series[$0 % Ink.series.count] })
        // Shapes in the legend only when they also mark the lines; otherwise plain dots.
        .chartSymbolScale(domain: domain, range: domain.indices.map {
            differentiateWithoutColor ? Self.symbols[$0 % Self.symbols.count] : BasicChartSymbolShape.circle
        })
        .chartYScale(domain: metric == .co2 ? co2Scale.domain : Self.domain(for: values))
        .chartLegend(position: .bottom, alignment: .leading, spacing: 14)
        .chartXAxis {
            // `.aligned` keeps the last label inside the plot instead of
            // clipping it at the trailing edge.
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Ink.hairline)
                AxisValueLabel(format: range.axisFormat).foregroundStyle(Ink.inkSoft)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Ink.hairline)
                // The limit line carries its own label; don't say 1,000 twice.
                if !(metric == .co2 && value.as(Double.self) == limit) {
                    AxisValueLabel().foregroundStyle(Ink.inkSoft)
                }
            }
        }
        #if targetEnvironment(macCatalyst)
        // On the Mac the readout follows the pointer.
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot = proxy.plotFrame else { return }
                            let x = location.x - geo[plot].origin.x
                            selectedTime = x >= 0 && x <= geo[plot].width ? proxy.value(atX: x, as: Date.self) : nil
                        case .ended:
                            selectedTime = nil
                        }
                    }
            }
        }
        #else
        .chartXSelection(value: $selectedTime)
        #endif
        .accessibilityLabel("\(metric.longTitle), \(range.spokenTitle), by place")
        .accessibilityChartDescriptor(HistoryChartDescriptor(model: model, names: names, limit: limit))
    }

    /// The chart's takeaway, written to be read: "Bedroom was over the limit
    /// 82% of the time."
    nonisolated static func headline(_ stats: [PlaceStats], metric: Metric, limit: Double) -> String {
        if metric == .co2 {
            let over = stats.filter { ($0.shareOverLimit ?? 0) > 0 }
                .max { ($0.shareOverLimit ?? 0) < ($1.shareOverLimit ?? 0) }
            if let over, let share = over.shareOverLimit {
                return "\(over.place) was over the limit \(Int((share * 100).rounded()))% of the time."
            }
            if let worst = stats.first, let avg = worst.avgCO2 {
                return "Every place stayed under \(Metric.co2.format(limit)) ppm. \(worst.place) averaged \(Metric.co2.format(avg))."
            }
            return "No CO₂ readings in this period."
        }
        guard let top = stats.filter({ $0.average(metric) != nil })
            .max(by: { ($0.average(metric) ?? 0) < ($1.average(metric) ?? 0) }),
              let value = top.average(metric) else { return "No \(metric.longTitle.lowercased()) readings in this period." }
        let v = metric.format(value)
        switch metric {
        case .temperature: return "\(top.place) was the warmest, \(v) °C on average."
        case .humidity: return "\(top.place) was the most humid, \(v) % on average."
        case .pm25: return "\(top.place) had the most fine particles, \(v) µg/m³ on average."
        case .co2: return ""
        }
    }

    /// One sentence a VoiceOver user can take away instead of the chart.
    nonisolated static func summary(_ stats: [PlaceStats], metric: Metric, limit: Double) -> String {
        if metric == .co2 {
            let over = stats.filter { ($0.shareOverLimit ?? 0) > 0 }
                .max { ($0.shareOverLimit ?? 0) < ($1.shareOverLimit ?? 0) }
            if let over, let share = over.shareOverLimit {
                return "\(over.place) was over the limit \(Int((share * 100).rounded()))% of the time."
            }
            if let worst = stats.first, let avg = worst.avgCO2 {
                return "No place reached the \(Metric.co2.format(limit)) ppm limit. \(worst.place) averaged highest, \(Metric.co2.spoken(avg))."
            }
            return "No CO₂ readings in this period."
        }
        guard let top = stats.filter({ $0.average(metric) != nil })
            .max(by: { ($0.average(metric) ?? 0) < ($1.average(metric) ?? 0) }),
              let value = top.average(metric) else { return "No \(metric.longTitle.lowercased()) readings in this period." }
        return "\(top.place) averaged highest, \(metric.spoken(value))."
    }

    /// How far round a place's small ensō reaches: CO₂ on the same scale as
    /// the big one; other values relative to the highest place.
    nonisolated static func ensoFraction(metric: Metric, average: Double?, scaleMax: Double) -> Double {
        guard let average else { return 0.06 }
        if metric == .co2 { return EnsoRing.fraction(for: average) }
        return min(0.94, max(0.06, 0.06 + 0.88 * average / max(scaleMax, 0.01)))
    }

    struct ChartPoint: Identifiable, Sendable, Equatable {
        /// Place and moment — stable across the minute's reloads, so Charts
        /// matches the same reading to itself (never an array position).
        let id: String
        let time: Date
        let value: Double
        let placeKey: String
        let place: String
        /// Which stretch of its place this point is on: 0, 1, 2 … per place.
        let segment: Int
        /// The line this point is drawn on — unique to (place, stretch).
        var series: String { "\(placeKey)#\(segment)" }
        /// The only point of its stretch — drawn as a dot.
        var isSingle: Bool

        static func id(placeKey: String, time: Date) -> String {
            "\(placeKey)|\(Int(time.timeIntervalSince1970.rounded()))"
        }
    }

    /// The longest pause that still counts as one stretch: three buckets,
    /// but never less than three recording intervals — at 10-minute logging
    /// a 1-minute bucket would otherwise break every sample into its own
    /// line. 3 h: 3 min, 24 h: 15 min, 7 d: 90 min, 30 d: 6 h (at 1-minute
    /// logging).
    nonisolated static func segmentGap(bucketMinutes: Int, intervalMinutes: Int) -> TimeInterval {
        Double(max(bucketMinutes, intervalMinutes)) * 60 * 3
    }

    /// Split each place's readings into stretches: a new one wherever two
    /// consecutive readings *of that place* are more than `gap` seconds
    /// apart. Other places' readings in between don't break it. Rows without
    /// a value for `metric` are skipped. The result stays in time order.
    nonisolated static func segments(_ rows: [Row], gap: TimeInterval, metric: Metric = .co2) -> [ChartPoint] {
        var out: [ChartPoint] = []
        struct Open { var index: Int; var time: Date; var segment: Int; var count: Int }
        var open: [String: Open] = [:]
        for r in rows.sorted(by: { $0.time < $1.time }) {
            guard let v = r.value(metric) else { continue }
            let key = r.placeKey
            var segment = 0
            var count = 0
            if let o = open[key] {
                if r.time.timeIntervalSince(o.time) > gap {
                    if o.count == 1 { out[o.index].isSingle = true }
                    segment = o.segment + 1
                } else {
                    segment = o.segment
                    count = o.count
                }
            }
            out.append(ChartPoint(id: ChartPoint.id(placeKey: key, time: r.time), time: r.time, value: v,
                                  placeKey: key, place: r.place, segment: segment, isSingle: false))
            open[key] = Open(index: out.count - 1, time: r.time, segment: segment, count: count + 1)
        }
        for o in open.values where o.count == 1 { out[o.index].isSingle = true }
        return out
    }
}

/// "812 ppm / Bedroom · 14:05" — floated over the chart at the chosen moment.
private struct ChartReadout: View {
    let value: String
    let detail: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.monospacedDigit()).foregroundStyle(Ink.ink)
            Text(detail).font(.caption2).foregroundStyle(Ink.inkSoft)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Ink.paperRaised))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Ink.hairline, lineWidth: 0.5))
    }
}

/// The History chart for VoiceOver's Audio Graph and Describe Chart: one
/// series per place.
private struct HistoryChartDescriptor: AXChartDescriptorRepresentable {
    let model: HistoryModel
    let names: [String: String]
    let limit: Double

    func makeChartDescriptor() -> AXChartDescriptor {
        let metric = model.key.metric
        let times = model.points.map { $0.time.timeIntervalSince1970 }
        let values = model.points.map(\.value)
        let lo = values.min() ?? 0
        let t0 = times.min() ?? 0
        let x = AXNumericDataAxisDescriptor(
            title: "Time", range: t0...(max(times.max() ?? 1, t0 + 1)), gridlinePositions: []
        ) { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) }
        let y = AXNumericDataAxisDescriptor(
            title: metric.longTitle, range: lo...(max(values.max() ?? 1, lo + 1)),
            gridlinePositions: metric == .co2 ? [limit] : []
        ) { "\(metric.format($0)) \(metric.spokenUnit)" }
        let grouped = Dictionary(grouping: model.points, by: \.placeKey)
        let series = model.series.compactMap { s -> AXDataSeriesDescriptor? in
            guard let points = grouped[s.key] else { return nil }
            return AXDataSeriesDescriptor(
                name: names[s.key] ?? s.name, isContinuous: true,
                dataPoints: points.map { AXDataPoint(x: $0.time.timeIntervalSince1970, y: $0.value) })
        }
        return AXChartDescriptor(title: "\(metric.longTitle), \(model.key.range.spokenTitle)",
                                 summary: HistoryBody.summary(model.stats, metric: metric, limit: limit),
                                 xAxis: x, yAxis: y, additionalAxes: [], series: series)
    }
}

/// One place: a small ensō for its average — the same language as the big
/// one — its name, and the numbers behind it.
private struct PlaceStatRow: View {
    let stats: PlaceStats
    let metric: Metric
    let limit: Double
    let color: Color
    /// The chart's symbol for this place when colour alone mustn't carry it.
    let symbol: BasicChartSymbolShape?
    let scaleMax: Double

    @ScaledMetric(relativeTo: .body) private var ensoSize: CGFloat = 30
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // One line for name and average, or stacked when the text is too
        // large for that — the same switch as the Now page's MetricsRow.
        let large = dynamicTypeSize.isAccessibilitySize
        let headline = large
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
        let details = large
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 16))
        HStack(alignment: .center, spacing: 14) {
            EnsoRing(fraction: HistoryBody.ensoFraction(metric: metric, average: average, scaleMax: scaleMax),
                     color: color, lineWidth: 3, animated: false)
                .frame(width: ensoSize, height: ensoSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                headline {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let symbol {
                            symbol.fill(color)
                                .frame(width: 8, height: 8)
                                .accessibilityHidden(true)
                        }
                        Text(stats.place).font(Typeface.body).foregroundStyle(Ink.ink)
                    }
                    if !large { Spacer() }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("avg").kukiLabel()
                        Text(metric.format(average))
                            .font(.system(.title3).monospacedDigit())
                            .foregroundStyle(Ink.ink)
                        Text(metric.unit).font(.caption).foregroundStyle(Ink.inkSoft)
                    }
                }
                details {
                    Text("\(stats.hours.formatted(.number.precision(.fractionLength(1)))) h observed")
                    if metric == .co2 {
                        if let peak = stats.peakCO2 { Text("peak \(Metric.co2.format(peak))") }
                        if let share = stats.shareOverLimit {
                            Text("\(Int((share * 100).rounded()))% over \(Metric.co2.format(limit))")
                                .foregroundStyle(share > 0.2 ? Ink.shu : Ink.inkSoft)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(Ink.inkSoft)
            }
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

    private var average: Double? { stats.average(metric) }
}
