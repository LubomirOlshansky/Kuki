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
        .configurationDisplayName(Text("Air", comment: "Widget gallery: the widget's name (one short word: the air in a room)."))
        .description(Text("CO₂ where your sensor is, with temperature, humidity and the last few hours.", comment: "Widget gallery: the widget's description."))
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

/// The ink hierarchy for the current rendering mode. Full colour keeps
/// Kūki's own inks, exactly as before. Tinted (accented) and clear/vibrant
/// modes keep only each pixel's alpha and luminance, so the low-alpha inks
/// (inkSoft 68 %, inkFaint 30 %) would wash into one faint tone: there the
/// system's own primary/secondary styles carry the hierarchy instead.
private struct WidgetInk {
    let fullColor: Bool
    init(_ mode: WidgetRenderingMode) { fullColor = mode == .fullColor }

    var ink: Color { fullColor ? Ink.ink : .primary }
    var soft: Color { fullColor ? Ink.inkSoft : .secondary }
    var faint: Color { fullColor ? Ink.inkFaint : .secondary }
    /// A level pigment. Outside full colour it's the accent (see
    /// `.widgetAccentable()`) at full strength, so the system tint carries it.
    func pigment(_ color: Color) -> Color { fullColor ? color : .primary }
}

/// Locale-aware "21.4" (or "21,4"): the decimal separator follows the reader's region. Shared with the Live Activity.
func oneDecimal(_ v: Double) -> String {
    v.formatted(.number.precision(.fractionLength(1)).grouping(.never))
}

/// A whole reading in the reader's digits, never grouped: "742", "1234", "٧٤٢".
func wholeNumber(_ v: Double) -> String {
    Int(v.rounded()).formatted(.number.grouping(.never))
}

/// Locale-aware "47%" ("47 %" in French, "%47" in Turkish).
func percentText(_ v: Double) -> String {
    (v.rounded() / 100).formatted(.percent.precision(.fractionLength(0)).grouping(.never))
}

/// "Last reading": shown instead of the level title once a reading is old.
var lastReadingTitle: String {
    String(localized: "Last reading", comment: "Widget and Live Activity: replaces the air level title when the reading is old (no new reading for 30 minutes). Keep short.")
}

/// VoiceOver for the widget and the Live Activity: independent clauses,
/// each translated whole, read as a comma-separated list.
enum AirSpeech {
    static func co2(_ ppm: Double) -> String {
        String(localized: "CO₂ \(wholeNumber(ppm)) parts per million", comment: "VoiceOver (widget, Live Activity): the CO₂ reading. %@ = number.")
    }
    static func temperature(_ t: Double) -> String {
        String(localized: "temperature \(oneDecimal(t)) degrees", comment: "VoiceOver (widget, Live Activity): a clause after the CO₂ reading, lowercase in English. %@ = number.")
    }
    static func humidity(_ h: Double) -> String {
        String(localized: "humidity \(wholeNumber(h)) percent", comment: "VoiceOver (widget, Live Activity): a clause after the CO₂ reading, lowercase in English. %@ = number.")
    }
    static func pm25(_ p: Double) -> String {
        String(localized: "PM2.5 \(wholeNumber(p)) micrograms per cubic metre", comment: "VoiceOver (widget): fine-particle reading clause. %@ = number. Keep PM2.5.")
    }
    static var lastReading: String {
        String(localized: "last reading", comment: "VoiceOver (widget, Live Activity): clause saying the value shown is the last one heard, not live. Lowercase in English.")
    }
    static var notLive: String {
        String(localized: "last reading, not live", comment: "VoiceOver (widget): clause at the end saying the value is old, not live. Lowercase in English.")
    }
    static func list(_ clauses: [String]) -> String {
        clauses.joined(separator: String(localized: ", ", comment: "VoiceOver: separator between clauses of a spoken reading (comma and space). Use your language's comma."))
    }
}

/// "12 min ago" — only shown when the reading isn't fresh enough to be
/// trusted as "now".
private struct AgeLabel: View {
    let s: WidgetSnapshot
    @Environment(\.widgetRenderingMode) private var renderingMode
    var body: some View {
        Text("\(s.measuredAt, style: .relative) ago", comment: "Widget: how old the last reading is. %@ = a relative duration such as '12 min'. Very small space.")
            .font(.caption2)
            .foregroundStyle(WidgetInk(renderingMode).soft)
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
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.legibilityWeight) private var legibilityWeight

    var body: some View {
        let level = CO2Level(ppm: co2)
        let tone = WidgetInk(renderingMode)
        ZStack {
            // The ensō is the accent: the tinted Home Screen paints it in the
            // tint, everything else in the monochrome ink.
            EnsoRing(fraction: EnsoRing.fraction(for: co2), color: stale ? tone.faint : tone.pigment(level.color),
                     lineWidth: lineWidth, animated: false)
                .widgetAccentable()
            VStack(spacing: 0) {
                Text(verbatim: wholeNumber(co2))
                    // Ultralight, one step heavier with Bold Text — as in the app.
                    .font(Typeface.numeral(numberSize, bold: legibilityWeight == .bold))
                    .foregroundStyle(stale ? tone.soft : tone.ink)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                // Never below 11 pt, the floor for any widget text.
                Text(verbatim: "ppm").font(.system(size: max(11, numberSize * 0.22))).tracking(1.2)
                    .foregroundStyle(tone.soft)
            }
            .padding(lineWidth * 2)
        }
    }
}

private struct SmallAir: View {
    let s: WidgetSnapshot
    let co2: Double
    let stale: Bool
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let tone = WidgetInk(renderingMode)
        VStack(spacing: 6) {
            EnsoReading(co2: co2, stale: stale, numberSize: 34, lineWidth: 6)
            if stale {
                AgeLabel(s: s)
            } else {
                HStack(spacing: 4) {
                    if !s.placeKanji.isEmpty {
                        Text(s.placeKanji).font(.custom("HiraMinProN-W3", size: 12)).foregroundStyle(tone.soft)
                    }
                    Text(s.placeName).font(.caption2).foregroundStyle(tone.soft).lineLimit(1)
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
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let level = CO2Level(ppm: co2)
        let tone = WidgetInk(renderingMode)
        HStack(spacing: 18) {
            EnsoReading(co2: co2, stale: stale, numberSize: 36, lineWidth: 6)
                .frame(width: 118)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    // The level kanji wears the pigment, so it joins the ensō as accent.
                    Text(level.kanji).font(.custom("HiraMinProN-W3", size: 17))
                        .foregroundStyle(stale ? tone.soft : tone.pigment(level.color))
                        .widgetAccentable()
                    Text(stale ? lastReadingTitle : level.title).font(.subheadline).foregroundStyle(tone.ink)
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                }
                Sparkline(values: s.recentCO2, limit: s.limit)
                    .stroke(stale ? tone.faint : tone.ink, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                    .frame(height: 30)
                    // Time runs left to right in every language.
                    .environment(\.layoutDirection, .leftToRight)
                HStack(spacing: 12) {
                    small(s.temperature.map { oneDecimal($0) + "°" }, tone) {
                        Image(systemName: "thermometer.medium")
                    }
                    small(s.humidity.map { percentText($0) }, tone) {
                        Image(systemName: "humidity")
                    }
                    small(s.pm25.map { wholeNumber($0) }, tone) {
                        Text(verbatim: "PM2.5")
                    }
                }
                .lineLimit(1)
                if stale {
                    AgeLabel(s: s)
                } else {
                    Text(s.placeName).font(.caption2).foregroundStyle(tone.soft).lineLimit(1)
                }
            }
        }
        .widgetAccessibility(s: s, co2: co2, stale: stale, withMetrics: true)
    }

    /// A value with a quiet label in front: an SF Symbol, or short text where
    /// no symbol says it plainly. Both at caption2 (11 pt), never smaller.
    private func small<L: View>(_ value: String?, _ tone: WidgetInk, @ViewBuilder label: () -> L) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            label().font(.caption2).foregroundStyle(tone.soft)
            Text(value ?? "—").font(.caption.monospacedDigit()).foregroundStyle(tone.ink)
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
            Text(verbatim: "CO₂")
        } currentValueLabel: {
            Text(verbatim: wholeNumber(co2)).monospacedDigit()
        }
        .gaugeStyle(.accessoryCircular)
        .opacity(stale ? 0.5 : 1)
        .widgetAccentable()
        .accessibilityLabel(AirSpeech.list([AirSpeech.co2(co2)] + (stale ? [AirSpeech.lastReading] : [])))
    }
}

private struct RectangularAir: View {
    let s: WidgetSnapshot
    let co2: Double
    let stale: Bool
    var body: some View {
        let level = CO2Level(ppm: co2)
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: "CO₂ \(wholeNumber(co2)) ppm").font(.headline).widgetAccentable()
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(stale ? lastReadingTitle : level.title).font(.caption)
                .lineLimit(1).minimumScaleFactor(0.8)
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
        if stale {
            Text("CO₂ \(wholeNumber(co2)) ppm · old", comment: "Lock Screen inline widget (one short line next to the date) when the reading is old. %@ = CO₂ number. Keep CO₂ and ppm; 'old' must be very short.")
        } else {
            Text(verbatim: "CO₂ \(wholeNumber(co2)) ppm")
        }
    }
}

private struct EmptyAir: View {
    let family: WidgetFamily
    @Environment(\.widgetRenderingMode) private var renderingMode
    var body: some View {
        let tone = WidgetInk(renderingMode)
        switch family {
        case .accessoryCircular, .accessoryInline, .accessoryRectangular:
            Text("Open Kūki", comment: "Lock Screen widget before any reading exists (very small space: a small circle or one line). Keep very short.")
                .minimumScaleFactor(0.6)
        default:
            VStack(spacing: 8) {
                EnsoRing(fraction: 0.08, color: tone.faint, lineWidth: 5, animated: false)
                    .frame(width: 54, height: 54)
                    .widgetAccentable()
                Text("Open Kūki to start reading the air.", comment: "Home Screen widget before any reading exists (small widget, under an empty ensō).")
                    .minimumScaleFactor(0.8)
                    .font(.caption)
                    .foregroundStyle(tone.soft)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

private extension View {
    func widgetAccessibility(s: WidgetSnapshot, co2: Double, stale: Bool, withMetrics: Bool = false) -> some View {
        let level = CO2Level(ppm: co2)
        var clauses = [AirSpeech.co2(co2), level.title]
        if withMetrics {
            // "temperature 21.4 degrees, humidity 47 percent, PM2.5 6 micrograms per cubic metre"
            if let t = s.temperature { clauses.append(AirSpeech.temperature(t)) }
            if let h = s.humidity { clauses.append(AirSpeech.humidity(h)) }
            if let p = s.pm25 { clauses.append(AirSpeech.pm25(p)) }
        }
        clauses.append(s.placeName)
        if stale { clauses.append(AirSpeech.notLive) }
        return self
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AirSpeech.list(clauses))
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
