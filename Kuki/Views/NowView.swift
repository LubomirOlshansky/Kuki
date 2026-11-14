import Accessibility
import Charts
import SwiftData
import SwiftUI

/// 今 — the reading right now, and where the sensor is.
///
/// Split into small views with narrow inputs, so a new reading re-renders the
/// reading — not the place menu, the layout, or the footer.
struct NowView: View {
    @Environment(Recorder.self) private var recorder
    @Environment(\.modelContext) private var modelContext
    @State private var choosingPlace = false
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
            // Wide: anchored near the top (not centred), so a window resized
            // vertically doesn't make the ensō drift.
            .padding(.top, wide ? max(28, size.height * 0.10) : 12)
            .padding(.bottom, wide ? 36 : 12)
            .frame(maxWidth: wide ? 1120 : 520)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .paperBackground()
        .sheet(isPresented: $choosingPlace) { PlaceSheet().environment(recorder).environment(\.modelContext, modelContext) }
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
                    Text(p.kanji.isEmpty ? p.name : "\(p.name)  \(p.kanji)").tag(Optional(p.id))
                }
            } label: {
                Text("Move Sensor To")
            }
            .pickerStyle(.inline)
            Divider()
            Button("Edit Places…", systemImage: "square.and.pencil") { choosingPlace = true }
        } label: {
            VStack(spacing: 6) {
                Text("Sensor is in").kukiLabel()
                HStack(spacing: 10) {
                    if let kanji = place?.kanji, !kanji.isEmpty {
                        Text(kanji).font(Typeface.mincho(22)).foregroundStyle(Ink.inkSoft)
                    }
                    Text(place?.name ?? "Choose a place")
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
        .accessibilityLabel("Sensor place: \(place?.name ?? "none")")
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
    /// 0…1 — the new room's air "arriving" after the brush has painted.
    @State private var moteReveal = 1.0
    @State private var revealTask: Task<Void, Never>?

    /// The numeral never outgrows the ring it sits in.
    private var numeralSize: CGFloat { min(max(numeralScaled, ensoSize * 0.30), ensoSize * 0.34) }

    private static var pausedAdvice: String {
        #if targetEnvironment(macCatalyst)
        "Apple Home only updates Kūki in the background when it runs from the menu bar. Turn off Settings › Show in Dock to record around the clock."
        #else
        "Apple Home only updates the app in front. Station Mode keeps Kūki in front and recording."
        #endif
    }

    private var lastHeardText: String {
        if pausedInBackground {
            guard let lastHeard else { return "Paused" }
            return "Paused · last \(lastHeard.formatted(date: .omitted, time: .shortened))"
        }
        guard let lastHeard else { return "Sensor out of reach" }
        return "Sensor out of reach · last \(lastHeard.formatted(date: .omitted, time: .shortened))"
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
                    Text("ppm CO₂").kukiLabel()
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
                             : "Recording pauses until Apple Home hears from it again.")
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
                        Text(level.advice)
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
                    Label("Settling in · \(left) min", systemImage: "hourglass")
                        .font(.footnote)
                        .foregroundStyle(Ink.inkSoft)
                        .transition(.opacity)
                        .accessibilityLabel("Settling into the new place, \(left) minutes left")
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
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.spoken(value))
    }
}

private struct NowFooter: View {
    @Environment(Recorder.self) private var recorder

    var body: some View {
        VStack(alignment: .center, spacing: 18) {
            Button {
                recorder.stationMode = true
            } label: {
                Label("Station Mode", systemImage: "moon")
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
        }
    }

    private var recordingLine: String {
        if recorder.isSensorStale {
            return recorder.isPausedInBackground ? "Paused — Kūki is in the background" : "Paused — sensor out of reach"
        }
        if recorder.isCatchingUp { return "Updating from Apple Home…" }
        var line = "Recording · \(recorder.sensorName)"
        if let last = recorder.lastRecordedAt {
            line += " · " + last.formatted(date: .omitted, time: .shortened)
        }
        return line
    }
}

/// A small matcha dot that breathes slowly while recording — the only sign
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
                    .foregroundStyle(Ink.matcha)
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
                Text("Last 3 hours").kukiLabel()
                Spacer()
                if let peak = values.max() {
                    Text("Peak \(Metric.co2.format(peak))").font(.footnote).foregroundStyle(Ink.inkSoft)
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
                        RuleMark(y: .value("Limit", limit))
                            .foregroundStyle(Ink.shu.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 0.75, dash: [3, 4]))
                    }
                    ForEach(points, id: \.time) { p in
                        AreaMark(x: .value("Time", p.time), yStart: .value("Floor", floor), yEnd: .value("CO₂", p.co2))
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
        guard let last = values.last, let low = values.min(), let high = values.max() else { return "No readings yet." }
        let f = Metric.co2.format
        var text = "Now \(f(last)) parts per million, between \(f(low)) and \(f(high))"
        if high >= limit {
            let share = Double(values.filter { $0 >= limit }.count) / Double(values.count)
            text += "; over the \(f(limit)) limit \(Int((share * 100).rounded()))% of the time"
        }
        return text + "."
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
            title: "Time", range: (times.min() ?? 0)...(times.max() ?? 1), gridlinePositions: []
        ) { Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened) }
        let y = AXNumericDataAxisDescriptor(
            title: "CO₂", range: (values.min() ?? 400)...(max(values.max() ?? 1000, (values.min() ?? 400) + 1)),
            gridlinePositions: [limit]
        ) { "\(Int($0.rounded())) parts per million" }
        let series = AXDataSeriesDescriptor(
            name: "CO₂", isContinuous: true,
            dataPoints: points.map { AXDataPoint(x: $0.time.timeIntervalSince1970, y: $0.co2) })
        return AXChartDescriptor(title: "CO₂ over the last 3 hours",
                                 summary: RecentTrace.summary(points, limit: limit),
                                 xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}

/// Shown until a sensor is found in Apple Home.
struct EmptySensorView: View {
    @Environment(Recorder.self) private var recorder

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
            Button("Try the Demo Sensor") { recorder.useDemo = true }
                .font(.subheadline)
                .foregroundStyle(Ink.ai)
                .buttonStyle(QuietButtonStyle())
                .padding(.top, 6)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: 420)
    }

    private var title: String {
        switch recorder.homeKit.status {
        case .starting: "Looking for your sensor…"
        case .notAuthorized: "Kūki can't see Apple Home"
        case .noHomes: "No home in Apple Home"
        case .noSensors: "No air sensor found"
        case .ready: "Waiting for the first reading…"
        }
    }

    private var message: String {
        switch recorder.homeKit.status {
        case .starting, .ready:
            "Values arrive from Apple Home in a few seconds."
        case .notAuthorized:
            "Allow Kūki in System Settings › Privacy & Security › Home, then come back."
        case .noHomes, .noSensors:
            "Add your IKEA ALPSTUGA in the Home app first. Kūki will find it there."
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
            Label(running ? "Remove from Lock Screen" : "Show on Lock Screen",
                  systemImage: running ? "lock.slash" : "lock.rectangle.on.rectangle")
                .font(.subheadline)
                .foregroundStyle(Ink.ink)
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
