import SwiftData
import SwiftUI

/// 夜 — station mode. Leave the device on a charger in a room: the screen
/// stays awake (and the Mac won't sleep), showing only the number, dimly.
///
/// Dim, but still legible: every line of text clears 4.5:1 on black (more
/// with Increase Contrast). The whole composition drifts a few points each
/// minute so hours on an OLED screen leave no ghost of it.
struct StationView: View {
    @Environment(Recorder.self) private var recorder
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Place.sortIndex) private var places: [Place]

    /// The "how to leave" hint shows on arrival, then gets out of the way.
    @State private var hintVisible = true
    @State private var hintTask: Task<Void, Never>?

    private static var leaveHint: String {
        #if targetEnvironment(macCatalyst)
        "Click or press Esc to leave"
        #else
        "Tap to leave"
        #endif
    }

    private var outOfReach: String {
        guard let heard = recorder.current?.lastHeard else { return "Sensor out of reach" }
        return "Out of reach · last \(heard.formatted(date: .omitted, time: .shortened))"
    }

    var body: some View {
        let style = StationStyle(increasedContrast: contrast == .increased)
        TimelineView(.everyMinute) { context in
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 26) {
                    Spacer()
                    if let co2 = recorder.current?.co2 {
                        let level = CO2Level(ppm: co2)
                        let stale = recorder.isSensorStale
                        ZStack {
                            EnsoRing(fraction: EnsoRing.fraction(for: co2), color: stale ? Ink.inkFaint : level.color,
                                     lineWidth: 5)
                                .frame(width: 220, height: 220)
                                .opacity(stale ? 0.4 : 0.8)
                            Text(Metric.co2.format(co2))
                                .font(Typeface.numeral(64))
                                .foregroundStyle(.white.opacity(stale ? style.secondary : style.numeral))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Metric.co2.spoken(co2))
                        Text(stale ? outOfReach : "\(level.kanji)  \(level.title)")
                            .font(Typeface.mincho(17))
                            .foregroundStyle(.white.opacity(style.secondary))
                    } else {
                        Text("Waiting for the sensor…")
                            .foregroundStyle(.white.opacity(style.secondary))
                    }
                    Spacer()
                    VStack(spacing: 6) {
                        Text(places.first { $0.id == recorder.currentPlaceID }?.name ?? "")
                        Text(context.date.formatted(date: .omitted, time: .shortened))
                    }
                    .font(.caption)
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(style.tertiary))
                    Text(Self.leaveHint)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(style.tertiary))
                        .opacity(hintVisible ? 1 : 0)
                        .padding(.bottom, 20)
                        .accessibilityHidden(true)
                }
                .offset(StationDrift.offset(minute: StationDrift.minute(of: context.date)))
                .animation(reduceMotion ? nil : .easeInOut(duration: 3), value: StationDrift.minute(of: context.date))
            }
            .contentShape(Rectangle())
            .onTapGesture { recorder.stationMode = false }
            #if targetEnvironment(macCatalyst)
            // Moving the pointer brings the hint back for a moment.
            .onContinuousHover { phase in
                if case .active = phase { showHint() }
            }
            #endif
            .background {
                // Esc leaves too — a keyboard way out on the Mac and iPad.
                Button("Leave Station Mode") { recorder.stationMode = false }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .accessibilityAction(.escape) { recorder.stationMode = false }
            .accessibilityAction(named: "Leave Station Mode") { recorder.stationMode = false }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { showHint() }
    }

    private func showHint() {
        if !hintVisible {
            withAnimation(.easeOut(duration: 0.3)) { hintVisible = true }
        }
        hintTask?.cancel()
        hintTask = Task {
            try? await Task.sleep(for: .seconds(StationStyle.hintSeconds))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 1.2)) { hintVisible = false }
        }
    }
}

/// White-on-black opacities for station mode. Each clears 4.5:1 against
/// black for small text: 0.5 white ≈ 5.3:1, 0.62 ≈ 7.8:1; Increase Contrast
/// steps everything up.
struct StationStyle {
    var increasedContrast = false

    static let hintSeconds = 4.0

    var numeral: Double { increasedContrast ? 0.85 : 0.62 }
    var secondary: Double { increasedContrast ? 0.75 : 0.5 }
    var tertiary: Double { increasedContrast ? 0.7 : 0.5 }

    /// WCAG contrast of white at `opacity` over black.
    static func contrastOnBlack(opacity: Double) -> Double {
        let c = opacity <= 0.04045 ? opacity / 12.92 : pow((opacity + 0.055) / 1.055, 2.4)
        return (c + 0.05) / 0.05
    }
}

/// A slow, small wander so a static display never burns in: at most 6 pt
/// from centre, a new spot each minute.
enum StationDrift {
    static let reach = 6.0

    static func minute(of date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate / 60)
    }

    static func offset(minute: Int) -> CGSize {
        let m = Double(minute)
        return CGSize(width: reach * sin(m * 1.7), height: reach * cos(m * 1.3))
    }
}
