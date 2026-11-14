import Charts
import SwiftData
import SwiftUI

/// 記録 — how the air changed, and how the places compare.
struct HistoryView: View {
    @Environment(Recorder.self) private var recorder
    @State private var range: ChartRange = .day
    @State private var metric: Metric = .co2

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("記録").font(Typeface.mincho(24)).foregroundStyle(Ink.inkSoft)
                    Text("History").font(.system(.largeTitle).weight(.ultraLight)).foregroundStyle(Ink.ink)
                }
                .padding(.top, 12)

                Picker("Range", selection: $range) {
                    ForEach(ChartRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Value", selection: $metric) {
                    ForEach(Metric.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                HistoryBody(range: range, metric: metric, limit: recorder.co2Limit,
                            intervalMinutes: recorder.intervalMinutes, filter: recorder.sensorFilter)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .paperBackground()
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
        case .hours3, .day: .dateTime.hour()
        case .week: .dateTime.weekday(.abbreviated)
        case .month: .dateTime.day().month(.abbreviated)
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

    var points: [HistoryBody.ChartPoint] = []
    var series: [Series] = []
    var stats: [PlaceStats] = []
    var rowCount = 0

    static func build(_ rows: [Row], range: ChartRange, metric: Metric, limit: Double, intervalMinutes: Int) -> HistoryModel {
        let downsampled = Exporter.downsample(rows, minutes: range.bucketMinutes)
        let gap = HistoryBody.segmentGap(bucketMinutes: range.bucketMinutes, intervalMinutes: intervalMinutes)
        let points = HistoryBody.segments(downsampled, gap: gap, metric: metric)
        return HistoryModel(points: points, series: orderedSeries(rows), stats: PlaceStats.compute(rows, limit: limit),
                            rowCount: rows.count)
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
}

struct HistoryBody: View {
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let range: ChartRange
    let metric: Metric
    let limit: Double
    let intervalMinutes: Int
    let filter: SensorFilter

    @State private var model: HistoryModel?

    private struct LoadKey: Hashable {
        let range: ChartRange, metric: Metric, limit: Double, interval: Int, filter: SensorFilter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            if let model {
                if model.rowCount < 2 {
                    Text(emptyText)
                        .font(Typeface.body)
                        .foregroundStyle(Ink.inkSoft)
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    chart(model)
                        .frame(height: 280)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("By place").kukiLabel()
                        Text("Settling minutes after each move are left out.")
                            .font(.caption)
                            .foregroundStyle(Ink.inkSoft)
                    }
                    VStack(spacing: 0) {
                        let scale = model.stats.compactMap { $0.average(metric) }.max() ?? 1
                        ForEach(model.stats) { s in
                            let index = seriesIndex(s.key, in: model)
                            PlaceStatRow(stats: s, metric: metric, limit: limit,
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
                if built != model { model = built }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private var emptyText: String {
        let every = intervalMinutes <= 1 ? "every minute" : "every \(intervalMinutes) minutes"
        return "Nothing recorded in this period yet. Keep Kūki open — it records \(every)."
    }

    private func seriesIndex(_ key: String, in model: HistoryModel) -> Int {
        model.series.firstIndex { $0.key == key } ?? 0
    }

    static let symbols: [BasicChartSymbolShape] = [.circle, .square, .triangle, .diamond, .pentagon, .cross]
    static let dashes: [[CGFloat]] = [[], [6, 3], [1.5, 3], [8, 3, 1.5, 3], [3, 3], [10, 4]]

    private func chart(_ model: HistoryModel) -> some View {
        let names = Dictionary(uniqueKeysWithValues: model.series.map { ($0.key, $0.name) })
        let domain = model.series.map(\.name)
        return Chart {
            if metric == .co2 {
                RuleMark(y: .value("Limit", limit))
                    .foregroundStyle(Ink.shu.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 0.75, dash: [3, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("\(Metric.co2.format(limit)) ppm").font(.caption2).foregroundStyle(Ink.shu)
                    }
            }
            // One line per *visit*: colour says which place, but a new
            // segment starts whenever the sensor moved or the app was closed,
            // so lines never bridge hours that weren't observed. A visit of
            // a single point gets a dot, which a line can't draw.
            ForEach(model.points) { p in
                let place = names[p.placeKey] ?? p.place
                let index = seriesIndex(p.placeKey, in: model)
                if differentiateWithoutColor {
                    // Shape and dash carry the place too, not colour alone.
                    if p.isSingle {
                        PointMark(x: .value("Time", p.time), y: .value(metric.title, p.value))
                            .foregroundStyle(by: .value("Place", place))
                            .symbol(by: .value("Place", place))
                            .symbolSize(30)
                    } else {
                        LineMark(x: .value("Time", p.time), y: .value(metric.title, p.value),
                                 series: .value("Visit", p.segment))
                            .foregroundStyle(by: .value("Place", place))
                            .lineStyle(StrokeStyle(lineWidth: 1.4, dash: Self.dashes[index % Self.dashes.count]))
                            .interpolationMethod(.catmullRom)
                            .symbol(by: .value("Place", place))
                            .symbolSize(14)
                    }
                } else if p.isSingle {
                    PointMark(x: .value("Time", p.time), y: .value(metric.title, p.value))
                        .foregroundStyle(by: .value("Place", place))
                        .symbolSize(18)
                } else {
                    LineMark(x: .value("Time", p.time), y: .value(metric.title, p.value),
                             series: .value("Visit", p.segment))
                        .foregroundStyle(by: .value("Place", place))
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                        .interpolationMethod(.catmullRom)
                }
            }
        }
        .animation(.smooth(duration: 0.5), value: metric)
        .animation(.smooth(duration: 0.5), value: range)
        .chartForegroundStyleScale(domain: domain, range: domain.indices.map { Ink.series[$0 % Ink.series.count] })
        // Shapes in the legend only when they also mark the lines; otherwise plain dots.
        .chartSymbolScale(domain: domain, range: domain.indices.map {
            differentiateWithoutColor ? Self.symbols[$0 % Self.symbols.count] : BasicChartSymbolShape.circle
        })
        .chartYScale(domain: .automatic(includesZero: false))
        .chartLegend(position: .bottom, alignment: .leading, spacing: 14)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Ink.hairline)
                AxisValueLabel(format: range.axisFormat).foregroundStyle(Ink.inkSoft)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Ink.hairline)
                AxisValueLabel().foregroundStyle(Ink.inkSoft)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(metric.longTitle), \(range.spokenTitle), by place")
        .accessibilityValue(Self.summary(model.stats, metric: metric, limit: limit))
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

    struct ChartPoint: Identifiable, Sendable, Equatable {
        let id: Int
        let time: Date
        let value: Double
        let placeKey: String
        let place: String
        let segment: Int
        /// The only point of its visit — drawn as a dot.
        var isSingle: Bool
    }

    /// The longest pause that still counts as one visit: three buckets, but
    /// never less than three recording intervals — at 10-minute logging a
    /// 1-minute bucket would otherwise break every sample into its own visit.
    nonisolated static func segmentGap(bucketMinutes: Int, intervalMinutes: Int) -> TimeInterval {
        Double(max(bucketMinutes, intervalMinutes)) * 60 * 3
    }

    /// Split a time-ordered series into visits: a new segment on every place
    /// change or on any gap longer than `gap` seconds. Rows without a value
    /// for `metric` are skipped.
    nonisolated static func segments(_ rows: [Row], gap: TimeInterval, metric: Metric = .co2) -> [ChartPoint] {
        var out: [ChartPoint] = []
        var segment = 0
        var previous: Row?
        var countInSegment = 0
        for r in rows.sorted(by: { $0.time < $1.time }) {
            guard let v = r.value(metric) else { continue }
            if let p = previous, p.placeKey != r.placeKey || r.time.timeIntervalSince(p.time) > gap {
                if countInSegment == 1 { out[out.count - 1].isSingle = true }
                segment += 1
                countInSegment = 0
            }
            out.append(ChartPoint(id: out.count, time: r.time, value: v, placeKey: r.placeKey,
                                  place: r.place, segment: segment, isSingle: false))
            countInSegment += 1
            previous = r
        }
        if countInSegment == 1 { out[out.count - 1].isSingle = true }
        return out
    }
}

private struct PlaceStatRow: View {
    let stats: PlaceStats
    let metric: Metric
    let limit: Double
    let color: Color
    /// The chart's symbol for this place when colour alone mustn't carry it.
    let symbol: BasicChartSymbolShape?
    let scaleMax: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                if let symbol {
                    symbol.fill(color)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                } else {
                    Circle().fill(color).frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
                Text(stats.place).font(Typeface.body).foregroundStyle(Ink.ink)
                Spacer()
                Text("avg").kukiLabel()
                Text(metric.format(average))
                    .font(.system(.title3).weight(.light).monospacedDigit())
                    .foregroundStyle(Ink.ink)
                Text(metric.unit).font(.caption).foregroundStyle(Ink.inkSoft)
            }
            GeometryReader { geo in
                Capsule().fill(Ink.hairline)
                    .overlay(alignment: .leading) {
                        Capsule().fill(color.opacity(0.75))
                            .frame(width: geo.size.width * min(1, (average ?? 0) / max(scaleMax, 0.01)))
                    }
            }
            .frame(height: 3)
            HStack(spacing: 16) {
                Text(String(format: "%.1f h observed", stats.hours))
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
        .padding(.vertical, 16)
    }

    private var average: Double? { stats.average(metric) }
}
