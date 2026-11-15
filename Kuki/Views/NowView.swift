import Accessibility
import Charts
import SwiftData
import SwiftUI
import UIKit

/// 今 — the reading right now, and where the sensor is.
///
/// Split into small views with narrow inputs, so a new reading re-renders the
/// reading — not the place menu, the layout, or the footer.
struct NowView: View {
    @Environment(Recorder.self) private var recorder
    @Environment(\.modelContext) private var modelContext
    @State private var choosingPlace = false
    @State private var connectingHome = false
    @State private var size: CGSize = .zero

    /// The ensō follows Dynamic Type on narrow screens and the window on
    /// wide ones.
    @ScaledMetric(relativeTo: .largeTitle) private var ensoScaled: CGFloat = 256

    var body: some View {
        let wide = size.width >= 760
        ScrollView {
            // One view tree for both widths: only the layout changes, so the
            // ensō keeps its identity (and doesn't repaint) when the window is
            // resized across the breakpoint.
            let layout = wide
                ? AnyLayout(HStackLayout(alignment: .center, spacing: 56))
                : AnyLayout(VStackLayout(spacing: 0))
            layout {
                VStack(spacing: wide ? 24 : 28) {
                    PlaceButton(choosingPlace: $choosingPlace)
                    NowHero(ensoSize: ensoSize(wide: wide))
                }
                .frame(maxWidth: wide ? .infinity : nil)

                NowDetails(wide: wide)
            }
            .padding(.horizontal, wide ? 48 : 28)
            .padding(.top, wide ? 28 : 12)
            .padding(.bottom, wide ? 36 : 12)
            .frame(maxWidth: wide ? 1120 : 520)
            // Wide (iPad, Mac): centred in the window — on a tall portrait
            // iPad or a tall Mac window the content no longer hugs the top
            // and leaves half the screen empty.
            .frame(maxWidth: .infinity, minHeight: wide ? max(0, size.height - 1) : nil)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .paperBackground()
        .sheet(isPresented: $choosingPlace) { PlaceSheet().environment(recorder).environment(\.modelContext, modelContext) }
        // Owned here, not by the link that opens it: connecting turns the
        // demo off and finding a sensor replaces the empty state, and either
        // would take a sheet hosted by the link away mid-flow.
        .sheet(isPresented: $connectingHome) { AppleHomeConnectSheet().environment(recorder) }
        .environment(\.connectAppleHome, { connectingHome = true })
    }

    private func ensoSize(wide: Bool) -> CGFloat {
        if wide {
            // A scroll painting: the ring takes a real share of the window.
            return min(max(ensoScaled, size.width * 0.36), 440)
        }
        let room = size.width > 0 ? size.width - 56 : ensoScaled
        return min(ensoScaled, 380, max(200, room))
    }
}

// MARK: - Settling

/// How far the sensor has settled into a new place — pure, so it can be
/// tested and drawn from any clock.
enum SettleProgress {
    /// 1 right after a move, falling to 0 when settling is over. The ensō's
    /// ink is "wet" for exactly as long as the CO₂ cell is still adjusting.
    static func wetness(changedAt: Date, minutes: Int, now: Date) -> Double {
        guard minutes > 0 else { return 0 }
        let elapsed = now.timeIntervalSince(changedAt)
        return min(1, max(0, 1 - elapsed / (Double(minutes) * 60)))
    }

    /// Whole minutes left, rounded up; 0 when settled.
    static func minutesLeft(changedAt: Date, minutes: Int, now: Date) -> Int {
        let left = Double(minutes) * 60 - now.timeIntervalSince(changedAt)
        return left > 0 ? Int(ceil(left / 60)) : 0
    }
}

// MARK: - Place

/// "Sensor is in 寝室 Bedroom ⌄" — a menu to move the sensor.
private struct PlaceButton: View {
    @Binding var choosingPlace: Bool
    @Environment(Recorder.self) private var recorder
    @Query(sort: \Place.sortIndex) private var places: [Place]

    var body: some View {
        let place = places.first { $0.id == recorder.currentPlaceID }
        Menu {
            Picker(selection: Binding(
                get: { recorder.currentPlaceID },
                set: { id in if let p = places.first(where: { $0.id == id }) { recorder.move(to: p) } }
            )) {
                ForEach(places) { p in
                    Text(verbatim: p.kanji.isEmpty ? p.displayName : "\(p.displayName)  \(p.kanji)").tag(Optional(p.id))
                }
            } label: {
                Text("Move Sensor To", comment: "Now screen: heading of the menu listing the rooms the sensor can be moved to")
            }
            .pickerStyle(.inline)
            Divider()
            Button("Edit Places…", systemImage: "square.and.pencil") { choosingPlace = true }
        } label: {
            VStack(spacing: 6) {
                Text("Sensor is in", comment: "Now screen: small uppercase label above the name of the room the sensor is in")
                    .kukiLabel()
                HStack(spacing: 10) {
                    if let kanji = place?.kanji, !kanji.isEmpty {
                        Text(kanji).font(Typeface.mincho(22)).foregroundStyle(Ink.inkSoft)
                    }
                    Text(verbatim: place?.displayName ?? String(localized: "Choose a place",
                                                         comment: "Now screen: shown instead of a room name when the sensor has no place yet"))
                        .font(.system(.title2))
                        .foregroundStyle(Ink.ink)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Ink.inkSoft)
                }
                .id(place?.id)
                .transition(.inkDiffuse)
            }
            .animation(.easeInOut(duration: 0.5), value: place?.id)
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .quietHover(RoundedRectangle(cornerRadius: 14))
        }
        .menuStyle(.button)
        .buttonStyle(QuietButtonStyle())
        .menuIndicator(.hidden)
        .help("Move the sensor to another place")
        .accessibilityLabel(place.map {
            String(localized: "Sensor place: \($0.displayName)",
                   comment: "Now screen, VoiceOver: the room the sensor is in. Placeholder is the room's name.")
        } ?? String(localized: "Sensor place: none", comment: "Now screen, VoiceOver: the sensor has no room yet"))
        .accessibilityHint("Choose where the sensor is now")
    }
}

// MARK: - Hero

/// The ensō with the reading — or what's in the way of one.
private struct NowHero: View {
    @Environment(Recorder.self) private var recorder
    let ensoSize: CGFloat

    var body: some View {
        if let snapshot = recorder.current, let co2 = snapshot.co2 {
            HeroReading(co2: co2, stale: recorder.isSensorStale, catchingUp: recorder.isCatchingUp,
                        pausedInBackground: recorder.isPausedInBackground,
                        lastHeard: snapshot.lastHeard,
                        placeID: recorder.currentPlaceID, memory: recorder.ensoPaint,
                        changedAt: recorder.placeChangedAt, settleMinutes: recorder.settleMinutes,
                        ensoSize: ensoSize)
        } else if let snapshot = recorder.current, snapshot.hasAnyValue {
            Text("This sensor doesn't report CO₂")
                .font(Typeface.body)
                .foregroundStyle(Ink.inkSoft)
                .frame(height: 300)
        } else {
            EmptySensorView().padding(.top, 12)
        }
    }
}

/// Plain values in, so the reading only re-renders when the reading changes.
private struct HeroReading: View {
    let co2: Double
    let stale: Bool
    /// Back from the background: last-known values while Apple Home reconnects.
    let catchingUp: Bool
    /// Stale because Apple Home won't update a background app — not a sensor problem.
    let pausedInBackground: Bool
    let lastHeard: Date?
    let placeID: UUID?
    let memory: EnsoPaintMemory
    let changedAt: Date
    let settleMinutes: Int
    let ensoSize: CGFloat

    @ScaledMetric(relativeTo: .largeTitle) private var numeralScaled: CGFloat = 76
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The introduction's airing-habit answer: a usually-tilted window gets
    /// "open it wide" advice.
    @AppStorage(OnboardingKeys.airingHabit) private var airingHabit: String?
    /// 0…1 — the new room's air "arriving" after the brush has painted.
    @State private var moteReveal = 1.0
    @State private var revealTask: Task<Void, Never>?

    /// The numeral never outgrows the ring it sits in.
    private var numeralSize: CGFloat { min(max(numeralScaled, ensoSize * 0.30), ensoSize * 0.34) }

    private static var pausedAdvice: String {
        #if targetEnvironment(macCatalyst)
        String(localized: "Apple Home only updates Kūki in the background when it runs from the menu bar. Turn off Settings › Show in Dock to record around the clock.",
               comment: "Now screen (Mac): why recording is paused. 'Show in Dock' is the name of a Kūki setting.")
        #else
        String(localized: "Apple Home only updates the app in front. Station Mode keeps Kūki in front and recording.",
               comment: "Now screen: why recording is paused. 'Station Mode' is Kūki's dim, always-awake screen mode.")
        #endif
    }

    private var lastHeardText: String {
        if pausedInBackground {
            guard let lastHeard else {
                return String(localized: "Paused", comment: "Now screen: recording is paused because Kūki is in the background")
            }
            let time = lastHeard.formatted(date: .omitted, time: .shortened)
            return String(localized: "Paused · last \(time)",
                          comment: "Now screen: recording paused; placeholder is the time of the last reading, e.g. 14:05")
        }
        guard let lastHeard else {
            return String(localized: "Sensor out of reach", comment: "Now screen: the air sensor can't be heard right now")
        }
        let time = lastHeard.formatted(date: .omitted, time: .shortened)
        return String(localized: "Sensor out of reach · last \(time)",
                      comment: "Now screen: the sensor can't be heard; placeholder is the time of the last reading, e.g. 14:05")
    }

    var body: some View {
        let level = CO2Level(ppm: co2)
        let digits = Metric.co2.format(co2)
        VStack(spacing: 22) {
            ZStack {
                AirMotes(ppm: co2, color: level == .poor ? Ink.shu : Ink.ink, reveal: moteReveal,
                         exclusion: AirMotes.exclusion(digits: digits.count))
                    .frame(width: ensoSize * 232 / 256, height: ensoSize * 232 / 256)
                    .opacity(stale ? 0 : 1)
                // The ink stays wet while the sensor settles into a new room.
                TimelineView(.periodic(from: changedAt, by: 30)) { context in
                    EnsoRing(fraction: EnsoRing.fraction(for: co2), color: stale ? Ink.inkFaint : level.color,
                             lineWidth: 9, paintToken: AnyHashable(placeID), memory: memory,
                             wetness: stale ? 0 : SettleProgress.wetness(changedAt: changedAt, minutes: settleMinutes,
                                                                         now: context.date))
                }
                .frame(width: ensoSize, height: ensoSize)
                .opacity(stale ? 0.55 : catchingUp ? 0.7 : 1)
                VStack(spacing: 2) {
                    Text(digits)
                        .font(Typeface.numeral(numeralSize, bold: legibilityWeight == .bold))
                        .foregroundStyle(stale || catchingUp ? Ink.inkSoft : Ink.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .contentTransition(.numericText(value: co2))
                        .animation(.smooth(duration: 0.6), value: co2)
                    Text(verbatim: "ppm CO₂").kukiLabel()
                }
                .frame(maxWidth: ensoSize * 0.72)
            }
            .animation(.easeInOut(duration: 0.8), value: stale)
            .animation(.easeInOut(duration: 0.6), value: catchingUp)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Metric.co2.spoken(co2))
            .accessibilityValue(stale ? lastHeardText : level.title)

            Group {
                if stale {
                    VStack(spacing: 8) {
                        Text(lastHeardText).font(Typeface.title).foregroundStyle(Ink.ink)
                        Text(pausedInBackground
                             ? Self.pausedAdvice
                             : String(localized: "Recording pauses until Apple Home hears from it again.",
                                      comment: "Now screen: shown under 'Sensor out of reach'; 'it' is the sensor"))
                            .font(Typeface.body)
                            .foregroundStyle(Ink.inkSoft)
                    }
                    .id("stale")
                } else {
                    VStack(spacing: 8) {
                        HStack(spacing: 10) {
                            Text(level.kanji).font(Typeface.mincho(26)).foregroundStyle(level.color)
                                .accessibilityHidden(true)
                            Text(level.title).font(Typeface.title).foregroundStyle(Ink.ink)
                        }
                        Text(level.advice(habit: airingHabit))
                            .font(Typeface.body)
                            .foregroundStyle(Ink.inkSoft)
                    }
                    .id(level)
                }
            }
            .multilineTextAlignment(.center)
            .transition(.inkDiffuse)
            .animation(.easeInOut(duration: 0.8), value: level)
            .animation(.easeInOut(duration: 0.8), value: stale)

            if !stale {
                ReachingLabel(active: catchingUp)
                SettlingLabel(changedAt: changedAt, minutes: settleMinutes)
            }
        }
        .onChange(of: placeID) { revealMotes() }
    }

    /// After a move the motes clear, then the new room's air drifts in once
    /// the brush has finished (≈ 1.8 s).
    private func revealMotes() {
        revealTask?.cancel()
        guard !reduceMotion else { return }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { moteReveal = 0 }
        revealTask = Task {
            try? await Task.sleep(for: .milliseconds(1800))
            guard !Task.isCancelled else { return }
            moteReveal = 1
        }
    }
}

/// "Settling in · 7 min" — the only part of the screen that needs a clock.
private struct SettlingLabel: View {
    let changedAt: Date
    let minutes: Int

    var body: some View {
        TimelineView(.periodic(from: changedAt, by: 30)) { context in
            let left = SettleProgress.minutesLeft(changedAt: changedAt, minutes: minutes, now: context.date)
            Group {
                if left > 0 {
                    Label(String(localized: "Settling in · \(left) min",
                                 comment: "Now screen: minutes left while the sensor adapts to a new room's air (its CO₂ cell needs time). Short."),
                          systemImage: "hourglass")
                        .font(.footnote)
                        .foregroundStyle(Ink.inkSoft)
                        .transition(.opacity)
                        .accessibilityLabel(String(localized: "Settling into the new place, \(left) minutes left",
                                                   comment: "Now screen, VoiceOver: minutes left while the sensor adapts to a new room's air"))
                }
            }
            .animation(.easeInOut(duration: 0.6), value: left > 0)
        }
    }
}

// MARK: - Details

/// Temperature, humidity and particles, the last three hours, and the footer.
private struct NowDetails: View {
    @Environment(Recorder.self) private var recorder
    let wide: Bool

    var body: some View {
        if let s = recorder.current, s.hasAnyValue {
            // iPhone: under the ensō, read top to bottom. Mac / iPad: on the
            // right, the ensō on the left like a scroll painting.
            VStack(alignment: .leading, spacing: 0) {
                if !wide { Hairline().padding(.top, 36) }
                MetricsRow(temperature: s.temperature, humidity: s.humidity, pm25: s.pm25,
                           stale: recorder.isSensorStale)
                    .padding(.vertical, wide ? 0 : 22)
                Hairline().padding(.top, wide ? 28 : 0)
                RecentTrace(limit: recorder.co2Limit, filter: recorder.sensorFilter, refresh: recorder.lastRecordedAt)
                    .padding(.top, 28)
                if wide { Hairline().padding(.top, 28) }
                NowFooter()
                    .frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
                    .padding(.top, wide ? 28 : 32)
                    .padding(.bottom, wide ? 0 : 24)
            }
            .frame(maxWidth: wide ? 440 : .infinity)
        }
    }
}

private struct MetricsRow: View {
    let temperature: Double?
    let humidity: Double?
    let pm25: Double?
    let stale: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title) private var valueSize: CGFloat = 30

    var body: some View {
        // Three columns side by side, or stacked when the text is too large for that.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
        layout {
            column(.temperature, temperature)
            column(.humidity, humidity)
            column(.pm25, pm25)
        }
    }

    private func column(_ metric: Metric, _ value: Double?) -> some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(metric.format(value))
                    .font(.system(size: valueSize, weight: .regular).monospacedDigit())
                    .foregroundStyle(stale ? Ink.inkSoft : Ink.ink)
                    .contentTransition(.numericText())
                    .animation(.smooth, value: value)
                Text(metric.unit)
                    .font(.caption)
                    .foregroundStyle(Ink.inkSoft)
            }
            Text(metric.title).kukiLabel()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.spoken(value))
    }
}

private struct NowFooter: View {
    @Environment(Recorder.self) private var recorder
    @Environment(\.connectAppleHome) private var connectAppleHome

    var body: some View {
        VStack(alignment: .center, spacing: 18) {
            Button {
                recorder.stationMode = true
            } label: {
                Label(String(localized: "Station Mode", comment: "Button that starts Station Mode: a dim, always-awake screen for a device left on a charger"),
                      systemImage: "moon")
                    .font(.subheadline)
                    .foregroundStyle(Ink.ink)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .overlay(Capsule().stroke(Ink.hairline, lineWidth: 1))
                    .contentShape(Capsule())
                    .quietHover(Capsule())
            }
            .buttonStyle(QuietButtonStyle())
            .help("Keep the screen awake and dim everything but the reading")
            .accessibilityHint("Keeps the screen awake and dims everything but the reading")

            #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
            LiveActivityButton()
            #endif

            HStack(spacing: 8) {
                RecordingDot(active: !recorder.isSensorStale)
                Text(recordingLine).font(.footnote).foregroundStyle(Ink.inkSoft)
            }
            .accessibilityElement(children: .combine)

            // The demo's way back to a real sensor: without it, the only exit
            // is a toggle in Settings (someone who tapped "Try the demo" in
            // the introduction never saw the Apple Home screen).
            if recorder.useDemo {
                Button {
                    Analytics.track("connect_home_tapped", ["from": "now_demo"])
                    connectAppleHome()
                } label: {
                    Text("Connect Apple Home")
                        .font(.subheadline)
                        .foregroundStyle(Ink.ai)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(QuietButtonStyle())
                .padding(.top, -12)
                .accessibilityHint(Text("Switches from the demo to your sensor in Apple Home", comment: "Now screen: VoiceOver hint for the Connect Apple Home link shown while the demo sensor is on"))
            }
        }
    }

    private var recordingLine: String {
        if recorder.isSensorStale {
            return recorder.isPausedInBackground
                ? String(localized: "Paused — Kūki is in the background", comment: "Now screen footer: recording status")
                : String(localized: "Paused — sensor out of reach", comment: "Now screen footer: recording status")
        }
        if recorder.isCatchingUp {
            return String(localized: "Updating from Apple Home…", comment: "Now screen footer: recording status while Apple Home reconnects")
        }
        let sensor = recorder.sensorDisplayName
        guard let last = recorder.lastRecordedAt else {
            return String(localized: "Recording · \(sensor)",
                          comment: "Now screen footer: recording status. Placeholder is the sensor's name, e.g. ALPSTUGA.")
        }
        let time = last.formatted(date: .omitted, time: .shortened)
        return String(localized: "Recording · \(sensor) · \(time)",
                      comment: "Now screen footer: recording status. Placeholders: the sensor's name (e.g. ALPSTUGA), then the time of the last saved reading.")
    }
}

/// A small ink dot that breathes slowly while recording — the only sign
/// the app is working, and enough of one. Paused, it becomes a still, hollow
/// ring: a different shape, not just a different colour. The breathing is a
/// symbol effect, so it costs nothing per frame here and stops whenever the
/// window isn't in front or can't be seen (`motionPaused`).
struct RecordingDot: View {
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.motionPaused) private var motionPaused

    var body: some View {
        Group {
            if active {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    // Ink, not matcha: the pigments mean the air's level only.
                    .foregroundStyle(Ink.ink)
                    .symbolEffect(.breathe.pulse.wholeSymbol,
                                  isActive: scenePhase == .active && !reduceMotion && !motionPaused)
            } else {
                Circle()
                    .strokeBorder(Ink.inkSoft, lineWidth: 1)
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Recent trace

/// Last few hours of CO₂ as one quiet line. Read off the main actor, and
/// again every minute (the window moves) and after every new reading.
struct RecentTrace: View {
    @Environment(\.modelContext) private var context
    let limit: Double
    let filter: SensorFilter
    /// Changes when a reading is logged, which triggers a re-read.
    let refresh: Date?

    @State private var points: [TracePoint] = []

    struct TracePoint: Sendable, Equatable {
        let time: Date
        let co2: Double
    }

    private struct LoadKey: Hashable { let filter: SensorFilter; let refresh: Date? }

    var body: some View {
        let values = points.map(\.co2)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Last 3 hours", comment: "Now screen: small uppercase label above the CO₂ line of the last three hours")
                    .kukiLabel()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer()
                if let peak = values.max() {
                    Text("Peak \(Metric.co2.format(peak))",
                         comment: "Now screen: the highest CO₂ in the last three hours; placeholder is a number in ppm. Short.")
                        .font(.footnote).foregroundStyle(Ink.inkSoft)
                        .lineLimit(1)
                }
            }
            if points.count < 2 {
                Text("The line appears after a few minutes of recording.")
                    .font(Typeface.body)
                    .foregroundStyle(Ink.inkSoft)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
            } else {
                let scale = TraceScale(values: values, limit: limit)
                let floor = scale.domain.lowerBound
                Chart {
                    if scale.showsLimit {
                        RuleMark(y: .value(String(localized: "Limit", comment: "Chart: the user's CO₂ alert limit line"), limit))
                            .foregroundStyle(Ink.shu.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 0.75, dash: [3, 4]))
                    }
                    ForEach(points, id: \.time) { p in
                        AreaMark(x: .value("Time", p.time),
                                 yStart: .value(String(localized: "Floor", comment: "Chart: the lowest value of the chart's vertical axis (not a building floor)"), floor),
                                 yEnd: .value("CO₂", p.co2))
                            .foregroundStyle(LinearGradient(colors: [Ink.ink.opacity(0.10), Ink.ink.opacity(0)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("Time", p.time), y: .value("CO₂", p.co2))
                            .foregroundStyle(Ink.ink)
                            .lineStyle(StrokeStyle(lineWidth: 1.25))
                            .interpolationMethod(.catmullRom)
                    }
                }
                .chartYScale(domain: scale.domain)
                .chartXAxis {
                    AxisMarks(preset: .aligned, values: .stride(by: .hour)) { _ in
                        AxisValueLabel(format: .dateTime.hour()).foregroundStyle(Ink.inkSoft)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisValueLabel().foregroundStyle(Ink.inkSoft)
                    }
                }
                .frame(height: 110)
                // Time runs left to right in every language, RTL included.
                .environment(\.layoutDirection, .leftToRight)
                // Keep Swift Charts' own VoiceOver tools (Describe Chart,
                // Audio Graph) and give them our summary.
                .accessibilityLabel("CO₂ over the last 3 hours")
                .accessibilityChartDescriptor(TraceChartDescriptor(points: points, limit: limit))
            }
        }
        .task(id: LoadKey(filter: filter, refresh: refresh)) {
            let container = context.container
            let filter = filter
            while !Task.isCancelled {
                let since = Date.now.addingTimeInterval(-3 * 3600)
                let loaded = await Task.detached(priority: .utility) {
                    let rows = (try? Exporter.fetchRows(container: container, since: since, filter: filter)) ?? []
                    return rows.compactMap { r in r.co2.map { TracePoint(time: r.time, co2: $0) } }
                }.value
                if Task.isCancelled { break }
                if loaded != points { points = loaded }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// "Now 812 ppm, between 640 and 1020; above the 1000 ppm limit for part of it."
    nonisolated static func summary(_ points: [TracePoint], limit: Double) -> String {
        let values = points.map(\.co2)
        guard let last = values.last, let low = values.min(), let high = values.max() else {
            return String(localized: "No readings yet.", comment: "Now screen, VoiceOver chart summary: nothing recorded in the last three hours")
        }
        let f = Metric.co2.format
        let (now, lo, hi) = (f(last), f(low), f(high))
        guard high >= limit else {
            return String(localized: "Now \(now) parts per million, between \(lo) and \(hi).",
                          comment: "Now screen, VoiceOver chart summary of the last three hours of CO₂. Placeholders: the current, lowest and highest value in ppm.")
        }
        let share = Double(values.filter { $0 >= limit }.count) / Double(values.count)
        let percent = share.formatted(.percent.precision(.fractionLength(0)))
        let limitText = f(limit)
        return String(localized: "Now \(now) parts per million, between \(lo) and \(hi); over the \(limitText) limit \(percent) of the time.",
                      comment: "Now screen, VoiceOver chart summary of the last three hours of CO₂. Placeholders: current, lowest and highest value in ppm, the user's limit in ppm, and a percentage such as 25%.")
    }
}

/// The recent trace for VoiceOver's Audio Graph and Describe Chart.
private struct TraceChartDescriptor: AXChartDescriptorRepresentable {
    let points: [RecentTrace.TracePoint]
    let limit: Double

    func makeChartDescriptor() -> AXChartDescriptor {
        let times = points.map { $0.time.timeIntervalSince1970 }
        let values = points.map(\.co2)
        let x = AXNumericDataAxisDescriptor(
            title: String(localized: "Time", comment: "Chart, VoiceOver: name of the time axis"),
            range: (times.min() ?? 0)...(times.max() ?? 1), gridlinePositions: []
        ) { Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened) }
        let y = AXNumericDataAxisDescriptor(
            title: "CO₂", range: (values.min() ?? 400)...(max(values.max() ?? 1000, (values.min() ?? 400) + 1)),
            gridlinePositions: [limit]
        ) { value in
            String(localized: "\(Int(value.rounded())) parts per million",
                   comment: "Chart, VoiceOver: a CO₂ value on the vertical axis")
        }
        let series = AXDataSeriesDescriptor(
            name: "CO₂", isContinuous: true,
            dataPoints: points.map { AXDataPoint(x: $0.time.timeIntervalSince1970, y: $0.co2) })
        return AXChartDescriptor(title: String(localized: "CO₂ over the last 3 hours",
                                               comment: "Now screen, VoiceOver: title of the CO₂ chart"),
                                 summary: RecentTrace.summary(points, limit: limit),
                                 xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}

/// Shown until a sensor is found in Apple Home.
struct EmptySensorView: View {
    @Environment(Recorder.self) private var recorder
    @Environment(\.openURL) private var openURL
    @Environment(\.connectAppleHome) private var connectAppleHome

    /// Skipped the introduction before connecting: Apple Home was never asked.
    private var notConnected: Bool { !recorder.useDemo && !recorder.homeKitRequested }

    var body: some View {
        VStack(spacing: 18) {
            EnsoRing(fraction: 0.08, color: Ink.inkFaint, lineWidth: 6)
                .frame(width: 120, height: 120)
                .accessibilityHidden(true)
            Text(title)
                .font(Typeface.title)
                .foregroundStyle(Ink.ink)
                .multilineTextAlignment(.center)
            Text(message)
                .font(Typeface.body)
                .foregroundStyle(Ink.inkSoft)
                .multilineTextAlignment(.center)
            // The buttons' 44 pt frames already give more air than the old
            // 6 pt top padding; stacked tight, they read as one group.
            VStack(spacing: 0) {
                if notConnected {
                    textButton("Connect Apple Home") {
                        Analytics.track("connect_home_tapped", ["from": "now_empty"])
                        connectAppleHome()
                    }
                }
                #if !targetEnvironment(macCatalyst)
                if !notConnected, recorder.homeKit.status == .notAuthorized,
                   let settings = URL(string: UIApplication.openSettingsURLString) {
                    textButton("Open Settings") { openURL(settings) }
                }
                #endif
                textButton("Try the demo") { recorder.useDemo = true }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: 420)
    }

    /// Where Home access is granted: System Settings on the Mac, the Settings
    /// app (one tap away, below) on iPhone and iPad.
    static var homeAccessMessage: String {
        #if targetEnvironment(macCatalyst)
        String(localized: "Allow Kūki in System Settings › Privacy & Security › Home, then come back.",
               comment: "Shown when Kūki has no access to Apple Home (Mac). Use the System Settings names macOS shows in your language.")
        #else
        String(localized: "Allow Home access for Kūki in Settings, then come back.",
               comment: "Shown when Kūki has no access to Apple Home (iPhone/iPad). 'Settings' is the iOS Settings app.")
        #endif
    }

    /// A quiet indigo text button with a full 44 pt tap target.
    private func textButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Ink.ai)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
    }

    private var title: String {
        if notConnected {
            return String(localized: "Kūki isn't connected to Apple Home yet", comment: "Now screen, no sensor yet: title")
        }
        return switch recorder.homeKit.status {
        case .starting: String(localized: "Looking for your sensor…", comment: "Now screen, no sensor yet: title")
        case .notAuthorized: String(localized: "Kūki can't see Apple Home", comment: "Now screen, no sensor yet: title when Home access was denied")
        case .noHomes: String(localized: "No home in Apple Home", comment: "Now screen, no sensor yet: title when the Home app has no home set up")
        case .noSensors: String(localized: "No air sensor found", comment: "Now screen, no sensor yet: title")
        case .ready: String(localized: "Waiting for the first reading…", comment: "Now screen, no sensor yet: title")
        }
    }

    private var message: String {
        if notConnected {
            return String(localized: "Connect to read your air sensor.", comment: "Now screen, no sensor yet: message under the title")
        }
        return switch recorder.homeKit.status {
        case .starting, .ready:
            String(localized: "Values arrive from Apple Home in a few seconds.", comment: "Now screen, no sensor yet: message under the title")
        case .notAuthorized:
            Self.homeAccessMessage
        case .noHomes, .noSensors:
            String(localized: "Add your IKEA ALPSTUGA in the Home app first. Kūki will find it there.",
                   comment: "Now screen, no sensor yet: message. IKEA ALPSTUGA is a product name; 'the Home app' is Apple's Home app.")
        }
    }
}

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
/// "Show on Lock Screen": starts the Air Live Activity, which then follows
/// this app while it's open and the Mac (through iCloud) while it isn't.
private struct LiveActivityButton: View {
    @State private var running = LiveAir.shared.isRunning
    @State private var problem: String?
    @State private var showingProblem = false

    var body: some View {
        Button {
            if running {
                LiveAir.shared.end()
                running = false
            } else {
                do {
                    try LiveAir.shared.start()
                    running = true
                } catch {
                    problem = error.localizedDescription
                    showingProblem = true
                }
            }
        } label: {
            Label(running
                  ? String(localized: "Remove from Lock Screen", comment: "Now screen: button that ends the Live Activity showing the air on the Lock Screen")
                  : String(localized: "Show on Lock Screen", comment: "Now screen: button that starts a Live Activity showing the air on the Lock Screen"),
                  systemImage: running ? "lock.slash" : "lock.rectangle.on.rectangle")
                .font(.subheadline)
                .foregroundStyle(Ink.ink)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
        .onAppear { running = LiveAir.shared.isRunning }
        .alert("Can't show on Lock Screen", isPresented: $showingProblem, presenting: problem) { _ in
            Button("OK", role: .cancel) {}
        } message: { problem in
            Text(problem)
        }
    }
}
#endif

/// Y range for the small CO₂ trace: hug the data so a calm, flat morning
/// still shows its shape, and bring the limit line in only when the air came
/// within reach of it (otherwise a 1000 ppm line squashes a 420 ppm trace
/// against the floor).
struct TraceScale: Equatable {
    let domain: ClosedRange<Double>
    let showsLimit: Bool

    init(values: [Double], limit: Double) {
        let lo = values.min() ?? 400, hi = values.max() ?? 450
        let pad = max(15, (hi - lo) * 0.15)
        showsLimit = hi >= limit * 0.8
        let top = showsLimit ? max(hi + pad, limit + pad) : hi + pad
        domain = max(0, lo - pad)...top
    }
}

/// "Reaching your sensor…" — shown while Apple Home reconnects after the app
/// comes back (typically 5–15 s). Waits 0.6 s before appearing so an instant
/// reconnect never flickers it, then fades out the moment values are live.
private struct ReachingLabel: View {
    let active: Bool
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label("Reaching your sensor…", systemImage: "dot.radiowaves.left.and.right")
            .font(.footnote)
            .foregroundStyle(Ink.inkSoft)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating,
                          isActive: shown && !reduceMotion)
            .opacity(shown ? 1 : 0)
            .frame(height: shown ? nil : 0)
            .clipped()
            .accessibilityHidden(!shown)
            .task(id: active) {
                if active {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.4)) { shown = true }
                } else {
                    withAnimation(.easeIn(duration: 0.4)) { shown = false }
                }
            }
    }
}

extension EnvironmentValues {
    /// Opens the "Connect Apple Home" sheet that the Now screen hosts.
    @Entry var connectAppleHome: () -> Void = {}
}
