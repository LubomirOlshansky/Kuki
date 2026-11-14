import SwiftData
import SwiftUI

/// 夜 — station mode. Leave the device on a charger in a room: the screen
/// stays awake (and the Mac won't sleep), showing only the number, dimly.
struct StationView: View {
    @Environment(Recorder.self) private var recorder
    @Query(sort: \Place.sortIndex) private var places: [Place]

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
        TimelineView(.periodic(from: .now, by: 30)) { context in
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
                                .foregroundStyle(.white.opacity(stale ? 0.42 : 0.62))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Metric.co2.spoken(co2))
                        Text(stale ? outOfReach : "\(level.kanji)  \(level.title)")
                            .font(Typeface.mincho(17))
                            .foregroundStyle(.white.opacity(0.42))
                    } else {
                        Text("Waiting for the sensor…")
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer()
                    VStack(spacing: 6) {
                        Text(places.first { $0.id == recorder.currentPlaceID }?.name ?? "")
                        Text(context.date.formatted(date: .omitted, time: .shortened))
                    }
                    .font(.caption.weight(.light))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.32))
                    Text(Self.leaveHint)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.2))
                        .padding(.bottom, 20)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { recorder.stationMode = false }
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
    }
}
