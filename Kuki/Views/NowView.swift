import Charts
import SwiftData
import SwiftUI

/// 今 — the reading right now, and where the sensor is.
struct NowView: View {
    @Environment(Recorder.self) private var recorder
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: \Place.sortIndex) private var places: [Place]
    @State private var choosingPlace = false

    // Sizes follow Dynamic Type, within what fits inside the ring.
    @ScaledMetric(relativeTo: .largeTitle) private var ensoScaled: CGFloat = 256
    @ScaledMetric(relativeTo: .largeTitle) private var numeralScaled: CGFloat = 76
    @ScaledMetric(relativeTo: .title) private var secondarySize: CGFloat = 30

    private var ensoSize: CGFloat { min(ensoScaled, 380) }
    /// The numeral never outgrows the ring it sits in.
    private var numeralSize: CGFloat { min(numeralScaled, ensoSize * 0.34) }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 760
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                ScrollView {
                    // One view tree for both widths: only the layout changes,
                    // so the ensō keeps its identity (and doesn't repaint)
                    // when the window is resized across the breakpoint.
                    let layout = wide
                        ? AnyLayout(HStackLayout(alignment: .center, spacing: 56))
                        : AnyLayout(VStackLayout(spacing: 0))
                    layout {
                        VStack(spacing: wide ? 24 : 28) {
                            placeButton
                            hero
                        }
                        .frame(maxWidth: wide ? .infinity : nil)

                        if let s = recorder.current, s.hasAnyValue {
                            details(s, wide: wide)
                        }
                    }
                    .padding(.horizontal, wide ? 48 : 28)
                    .padding(.vertical, wide ? 36 : 12)
                    .frame(maxWidth: wide ? 1040 : 520)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
            }
        }
        .paperBackground()
        .sheet(isPresented: $choosingPlace) { PlaceSheet().environment(recorder).environment(\.modelContext, modelContext) }
        .sensoryFeedback(.selection, trigger: recorder.currentPlaceID)
    }

    // MARK: Layout

    /// iPhone: under the ensō, read top to bottom. Mac / iPad: on the right,
    /// the ensō on the left like a scroll painting.
    private func details(_ s: SensorSnapshot, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !wide { Hairline().padding(.top, 36) }
            secondary(s).padding(.vertical, wide ? 0 : 22)
            Hairline().padding(.top, wide ? 28 : 0)
            RecentTrace(limit: recorder.co2Limit, filter: recorder.sensorFilter, refresh: recorder.lastRecordedAt)
                .padding(.top, 28)
            if wide { Hairline().padding(.top, 28) }
            footer
                .frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
                .padding(.top, wide ? 28 : 32)
                .padding(.bottom, wide ? 0 : 24)
        }
        .frame(maxWidth: wide ? 440 : .infinity)
    }

    @ViewBuilder private var hero: some View {
        if let snapshot = recorder.current, let co2 = snapshot.co2 {
            reading(co2: co2, snapshot: snapshot)
        } else if let snapshot = recorder.current, snapshot.hasAnyValue {
            Text("This sensor doesn't report CO₂")
                .font(Typeface.body)
                .foregroundStyle(Ink.inkSoft)
                .frame(height: 300)
        } else {
            EmptySensorView().padding(.top, 12)
        }
    }

    // MARK: Pieces

    private var currentPlace: Place? { places.first { $0.id == recorder.currentPlaceID } }

    private var placeSelection: Binding<UUID?> {
        Binding(
            get: { recorder.currentPlaceID },
            set: { id in if let place = places.first(where: { $0.id == id }) { recorder.move(to: place) } }
        )
    }

    private var placeButton: some View {
        let place = currentPlace
        return Menu {
            Picker(selection: placeSelection) {
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
                        .font(.system(.title2).weight(.light))
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
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(QuietButtonStyle())
        .menuIndicator(.hidden)
        .hoverEffect(.highlight)
        .accessibilityLabel("Sensor place: \(place?.name ?? "none")")
        .accessibilityHint("Choose where the sensor is now")
    }

    private var lastHeardText: String {
        guard let heard = recorder.current?.lastHeard else { return "Sensor out of reach" }
        return "Sensor out of reach · last \(heard.formatted(date: .omitted, time: .shortened))"
    }

    private func reading(co2: Double, snapshot: SensorSnapshot) -> some View {
        let level = CO2Level(ppm: co2)
        let stale = recorder.isSensorStale
        let motesColor = level == .poor ? Ink.shu : Ink.ink
        return VStack(spacing: 22) {
            ZStack {
                AirMotes(ppm: co2, color: motesColor)
                    .frame(width: ensoSize * 232 / 256, height: ensoSize * 232 / 256)
                    .opacity(stale ? 0 : 1)
                EnsoRing(fraction: EnsoRing.fraction(for: co2), color: stale ? Ink.inkFaint : level.color,
                         lineWidth: 9, paintToken: AnyHashable(recorder.currentPlaceID), memory: recorder.ensoPaint)
                    .frame(width: ensoSize, height: ensoSize)
                    .opacity(stale ? 0.55 : 1)
                VStack(spacing: 2) {
                    Text(Metric.co2.format(co2))
                        .font(Typeface.numeral(numeralSize))
                        .foregroundStyle(stale ? Ink.inkSoft : Ink.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .contentTransition(.numericText(value: co2))
                        .animation(.smooth(duration: 0.6), value: co2)
                    Text("ppm CO₂").kukiLabel()
                }
                .frame(maxWidth: ensoSize * 0.72)
            }
            .animation(.easeInOut(duration: 0.8), value: stale)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Metric.co2.spoken(co2))
            .accessibilityValue(stale ? lastHeardText : level.title)

            Group {
                if stale {
                    VStack(spacing: 8) {
                        Text(lastHeardText).font(Typeface.title).foregroundStyle(Ink.ink)
                        Text("Recording pauses until Apple Home hears from it again.")
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

            if recorder.isSettling, !stale {
                Label("Settling in · \(Int(ceil(recorder.settleRemaining / 60))) min", systemImage: "hourglass")
                    .font(.footnote)
                    .foregroundStyle(Ink.inkSoft)
                    .transition(.opacity)
                    .accessibilityLabel("Settling into the new place, \(Int(ceil(recorder.settleRemaining / 60))) minutes left")
            }
        }
    }

    private func secondary(_ s: SensorSnapshot) -> some View {
        let stale = recorder.isSensorStale
        // Three columns side by side, or stacked when the text is too large for that.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
        return layout {
            ForEach([Metric.temperature, .humidity, .pm25]) { metric in
                VStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(metric.format(metric.value(of: s)))
                            .font(.system(size: secondarySize, weight: .light).monospacedDigit())
                            .foregroundStyle(stale ? Ink.inkSoft : Ink.ink)
                            .contentTransition(.numericText())
                            .animation(.smooth, value: metric.value(of: s))
                        Text(metric.unit)
                            .font(.caption)
                            .foregroundStyle(Ink.inkSoft)
                    }
                    HStack(spacing: 6) {
                        Text(metric.kanji).font(Typeface.mincho(13)).foregroundStyle(Ink.inkFaint)
                            .accessibilityHidden(true)
                        Text(metric.title).kukiLabel()
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(metric.spoken(metric.value(of: s)))
            }
        }
    }

    private var footer: some View {
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
            }
            .buttonStyle(QuietButtonStyle())
            .hoverEffect(.highlight)
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
        if recorder.isSensorStale { return "Paused — sensor out of reach" }
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
/// ring: a different shape, not just a different colour.
struct RecordingDot: View {
    var active = true

    var body: some View {
        Group {
            if active {
                BreathingDot()
            } else {
                Circle()
                    .strokeBorder(Ink.inkSoft, lineWidth: 1)
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }

    private struct BreathingDot: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var breathe = false

        var body: some View {
            Circle()
                .fill(Ink.matcha)
                .frame(width: 6, height: 6)
                .opacity(breathe ? 0.35 : 1)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathe = true }
                }
        }
    }
}

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
                let floor = (values.min() ?? 400) - 40
                Chart {
                    RuleMark(y: .value("Limit", limit))
                        .foregroundStyle(Ink.shu.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 0.75, dash: [3, 4]))
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
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour)) { _ in
                        AxisValueLabel(format: .dateTime.hour()).foregroundStyle(Ink.inkSoft)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisValueLabel().foregroundStyle(Ink.inkSoft)
                    }
                }
                .frame(height: 110)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("CO₂ over the last 3 hours")
                .accessibilityValue(Self.summary(points, limit: limit))
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
        .alert("Can't show on Lock Screen", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }
}
#endif
