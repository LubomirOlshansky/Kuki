import SwiftUI
import WidgetKit

// MARK: - Timeline

struct AirEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct AirProvider: TimelineProvider {
    func placeholder(in context: Context) -> AirEntry {
        AirEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (AirEntry) -> Void) {
        completion(AirEntry(date: .now, snapshot: context.isPreview ? (WidgetSnapshot.load() ?? .placeholder) : WidgetSnapshot.load()))
    }

    /// The app reloads us whenever it records. On our own we only need to
    /// redraw once more: the moment the last reading turns stale, so the
    /// widget fades honestly instead of pretending to be live.
    ///
    /// With iCloud sync on, each refresh also asks iCloud for the latest
    /// reading any of your devices published (a Mac recording around the
    /// clock, typically) and shows whichever is newer. iOS grants a widget a
    /// refresh roughly every 15–30 minutes, so that's how fresh it can be
    /// without opening the app.
    func getTimeline(in context: Context, completion: @escaping (Timeline<AirEntry>) -> Void) {
        Task {
            let local = WidgetSnapshot.load()
            let cloud = await CloudSync.fetchLatest()
            let snapshot = CloudSync.newer(local, cloud)
            if let snapshot, snapshot != local { try? snapshot.save() } // cache for the next offline refresh

            var entries = [AirEntry(date: .now, snapshot: snapshot)]
            if let snapshot, !snapshot.isStale() {
                let staleAt = snapshot.measuredAt.addingTimeInterval(WidgetSnapshot.staleAfter + 1)
                entries.append(AirEntry(date: staleAt, snapshot: snapshot))
            }
            let next: TimeInterval = CloudSync.isEnabled ? 15 * 60 : 3 * 3600
            completion(Timeline(entries: entries, policy: .after(.now.addingTimeInterval(next))))
        }
    }
}

// MARK: - Widget

@main
struct KukiWidgetBundle: WidgetBundle {
    var body: some Widget {
        AirWidget()
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        AirLiveActivity()
        #endif
    }
}

struct AirWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.widgetKind, provider: AirProvider()) { entry in
            AirWidgetView(entry: entry)
        }
        .configurationDisplayName("Air")
        .description("CO₂ where your sensor is, with temperature, humidity and the last few hours.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Views

struct AirWidgetView: View {
    let entry: AirEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let s = entry.snapshot, let co2 = s.co2 {
                let stale = s.isStale(at: entry.date)
                switch family {
                case .systemSmall: SmallAir(s: s, co2: co2, stale: stale)
                case .systemMedium: MediumAir(s: s, co2: co2, stale: stale)
                case .accessoryCircular: CircularAir(co2: co2, stale: stale)
                case .accessoryRectangular: RectangularAir(s: s, co2: co2, stale: stale)
                default: InlineAir(co2: co2, stale: stale)
                }
            } else {
                EmptyAir(family: family)
            }
        }
        .containerBackground(for: .widget) { Ink.paper }
    }
}

/// "12 min ago" — only shown when the reading isn't fresh enough to be
/// trusted as "now".
private struct AgeLabel: View {
    let s: WidgetSnapshot
    var body: some View {
        (Text(s.measuredAt, style: .relative) + Text(" ago"))
            .font(.caption2)
            .foregroundStyle(Ink.inkSoft)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// The ensō with the number inside — the app's signature, at rest.
private struct EnsoReading: View {
    let co2: Double
    let stale: Bool
    var numberSize: CGFloat
    var lineWidth: CGFloat

    var body: some View {
        let level = CO2Level(ppm: co2)
        ZStack {
            EnsoRing(fraction: EnsoRing.fraction(for: co2), color: stale ? Ink.inkFaint : level.color,
                     lineWidth: lineWidth, animated: false)
            VStack(spacing: 0) {
                Text(String(Int(co2.rounded())))
                    .font(.system(size: numberSize, weight: .ultraLight).monospacedDigit())
                    .foregroundStyle(stale ? Ink.inkSoft : Ink.ink)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("ppm").font(.system(size: max(9, numberSize * 0.22))).tracking(1.2)
                    .foregroundStyle(Ink.inkSoft)
            }
            .padding(lineWidth * 2)
        }
    }
}

private struct SmallAir: View {
    let s: WidgetSnapshot
    let co2: Double
    let stale: Bool

    var body: some View {
        VStack(spacing: 6) {
            EnsoReading(co2: co2, stale: stale, numberSize: 34, lineWidth: 6)
            if stale {
                AgeLabel(s: s)
            } else {
                HStack(spacing: 4) {
                    if !s.placeKanji.isEmpty {
                        Text(s.placeKanji).font(.custom("HiraMinProN-W3", size: 12)).foregroundStyle(Ink.inkSoft)
                    }
                    Text(s.placeName).font(.caption2).foregroundStyle(Ink.inkSoft).lineLimit(1)
                }
            }
        }
        .widgetAccessibility(s: s, co2: co2, stale: stale)
    }
}

private struct MediumAir: View {
    let s: WidgetSnapshot
    let co2: Double
    let stale: Bool

    var body: some View {
        let level = CO2Level(ppm: co2)
        HStack(spacing: 18) {
            EnsoReading(co2: co2, stale: stale, numberSize: 36, lineWidth: 6)
                .frame(width: 118)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(level.kanji).font(.custom("HiraMinProN-W3", size: 17))
                        .foregroundStyle(stale ? Ink.inkSoft : level.color)
                    Text(stale ? "Last reading" : level.title).font(.subheadline).foregroundStyle(Ink.ink)
                    Spacer(minLength: 0)
                }
                Sparkline(values: s.recentCO2, limit: s.limit)
                    .stroke(stale ? Ink.inkFaint : Ink.ink, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                    .frame(height: 30)
                HStack(spacing: 12) {
                    small(s.temperature.map { String(format: "%.1f°", $0) }, "温")
                    small(s.humidity.map { "\(Int($0.rounded()))%" }, "湿")
                    small(s.pm25.map { "\(Int($0.rounded()))" }, "塵")
                }
                if stale {
                    AgeLabel(s: s)
                } else {
                    Text(s.placeName).font(.caption2).foregroundStyle(Ink.inkSoft).lineLimit(1)
                }
            }
        }
        .widgetAccessibility(s: s, co2: co2, stale: stale)
    }

    private func small(_ value: String?, _ kanji: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(kanji).font(.custom("HiraMinProN-W3", size: 10)).foregroundStyle(Ink.inkSoft)
            Text(value ?? "—").font(.caption.monospacedDigit()).foregroundStyle(Ink.ink)
        }
    }
}

/// A tiny CO₂ trace, scaled to its own range (with the limit kept in view
/// when the air came close to it).
struct Sparkline: Shape {
    let values: [Double]
    let limit: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, let lo0 = values.min(), let hi0 = values.max() else { return path }
        let lo = lo0 - 20
        let hi = max(hi0 + 20, hi0 > limit * 0.85 ? limit : hi0 + 20)
        let span = max(hi - lo, 1)
        for (i, v) in values.enumerated() {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(values.count - 1)
            let y = rect.maxY - rect.height * CGFloat((v - lo) / span)
            i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
        }
        return path
    }
}

/// Lock Screen: a gauge that fills like the ensō.
private struct CircularAir: View {
    let co2: Double
    let stale: Bool
    var body: some View {
        Gauge(value: min(max(co2, 400), 2000), in: 400...2000) {
            Text("CO₂")
        } currentValueLabel: {
            Text(String(Int(co2.rounded()))).monospacedDigit()
        }
        .gaugeStyle(.accessoryCircular)
        .opacity(stale ? 0.5 : 1)
        .widgetAccentable()
        .accessibilityLabel("CO₂ \(Int(co2.rounded())) parts per million\(stale ? ", last reading" : "")")
    }
}

private struct RectangularAir: View {
    let s: WidgetSnapshot
    let co2: Double
    let stale: Bool
    var body: some View {
        let level = CO2Level(ppm: co2)
        VStack(alignment: .leading, spacing: 1) {
            Text("CO₂ \(Int(co2.rounded())) ppm").font(.headline).widgetAccentable()
            Text(stale ? "Last reading" : level.title).font(.caption)
            if stale {
                AgeLabel(s: s)
            } else {
                Text(s.placeName).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InlineAir: View {
    let co2: Double
    let stale: Bool
    var body: some View {
        Text("CO₂ \(Int(co2.rounded())) ppm\(stale ? " · old" : "")")
    }
}

private struct EmptyAir: View {
    let family: WidgetFamily
    var body: some View {
        switch family {
        case .accessoryCircular, .accessoryInline, .accessoryRectangular:
            Text("Open Kūki")
        default:
            VStack(spacing: 8) {
                EnsoRing(fraction: 0.08, color: Ink.inkFaint, lineWidth: 5, animated: false)
                    .frame(width: 54, height: 54)
                Text("Open Kūki to start reading the air.")
                    .font(.caption)
                    .foregroundStyle(Ink.inkSoft)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

private extension View {
    func widgetAccessibility(s: WidgetSnapshot, co2: Double, stale: Bool) -> some View {
        let level = CO2Level(ppm: co2)
        return self
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("CO₂ \(Int(co2.rounded())) parts per million, \(level.title), \(s.placeName)\(stale ? ", last reading, not live" : "")")
    }
}

#Preview("Small", as: .systemSmall) {
    AirWidget()
} timeline: {
    AirEntry(date: .now, snapshot: .placeholder)
}

#Preview("Medium", as: .systemMedium) {
    AirWidget()
} timeline: {
    AirEntry(date: .now, snapshot: .placeholder)
}
