#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen + Dynamic Island. Same language as the app: the ensō carries
/// CO₂, colour only when there is something to do, the age shown honestly
/// once the reading is old (`staleDate` makes `context.isStale` true).
struct AirLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AirActivityAttributes.self) { context in
            LockScreenAir(state: context.state, stale: context.isStale)
                .activityBackgroundTint(Ink.paper)
                .activitySystemActionForegroundColor(Ink.ink)
        } dynamicIsland: { context in
            let s = context.state
            let level = CO2Level(ppm: s.co2)
            let tint = context.isStale ? Color.secondary : level.islandColor
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    EnsoRing(fraction: EnsoRing.fraction(for: s.co2), color: tint, lineWidth: 4, animated: false)
                        .frame(width: 44, height: 44)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 0) {
                        Text("\(Int(s.co2.rounded()))")
                            .font(.system(size: 30, weight: .light).monospacedDigit())
                        Text("ppm CO₂").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let t = s.temperature { Text(oneDecimal(t) + "°").font(.caption.monospacedDigit()) }
                        if let h = s.humidity { Text("\(Int(h.rounded()))%").font(.caption.monospacedDigit()) }
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.isStale ? "Last reading" : level.title).font(.caption)
                        Spacer()
                        (Text(s.placeName) + Text(" · ") + Text(s.measuredAt, style: .relative))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } compactLeading: {
                EnsoRing(fraction: EnsoRing.fraction(for: s.co2), color: tint, lineWidth: 2.5, animated: false)
                    .frame(width: 18, height: 18)
            } compactTrailing: {
                Text("\(Int(s.co2.rounded()))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tint)
            } minimal: {
                EnsoRing(fraction: EnsoRing.fraction(for: s.co2), color: tint, lineWidth: 2.5, animated: false)
                    .frame(width: 18, height: 18)
            }
            .keylineTint(tint)
        }
    }
}

private struct LockScreenAir: View {
    let state: AirActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        let level = CO2Level(ppm: state.co2)
        HStack(spacing: 16) {
            ZStack {
                EnsoRing(fraction: EnsoRing.fraction(for: state.co2),
                         color: stale ? Ink.inkFaint : level.color, lineWidth: 5, animated: false)
                Text("\(Int(state.co2.rounded()))")
                    .font(.system(size: 22, weight: .light).monospacedDigit())
                    .foregroundStyle(stale ? Ink.inkSoft : Ink.ink)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 70, height: 70)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(level.kanji).font(.custom("HiraMinProN-W3", size: 16))
                        .foregroundStyle(stale ? Ink.inkSoft : level.color)
                    Text(stale ? "Last reading" : level.title).font(.headline.weight(.regular)).foregroundStyle(Ink.ink)
                }
                Text(stale ? "No new reading. Open Kūki to update." : level.advice)
                    .font(.footnote).foregroundStyle(Ink.inkSoft).lineLimit(2)
                HStack(spacing: 10) {
                    if !state.placeKanji.isEmpty {
                        Text(state.placeKanji).font(.custom("HiraMinProN-W3", size: 11)).foregroundStyle(Ink.inkSoft)
                    }
                    Text(state.placeName).font(.caption2).foregroundStyle(Ink.inkSoft)
                    if let t = state.temperature { Text(oneDecimal(t) + "°").font(.caption2.monospacedDigit()).foregroundStyle(Ink.inkSoft) }
                    if let h = state.humidity { Text("\(Int(h.rounded()))%").font(.caption2.monospacedDigit()).foregroundStyle(Ink.inkSoft) }
                    Spacer(minLength: 0)
                    (Text(state.measuredAt, style: .relative) + Text(" ago"))
                        .font(.caption2).foregroundStyle(Ink.inkSoft).lineLimit(1)
                }
            }
        }
        .padding(16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel(level))
    }

    /// "CO₂ 742 parts per million, Fine, temperature 21.4 degrees, humidity 47 percent, Living room"
    private func spokenLabel(_ level: CO2Level) -> String {
        var label = "CO₂ \(Int(state.co2.rounded())) parts per million, \(stale ? "last reading" : level.title)"
        if let t = state.temperature { label += ", temperature \(oneDecimal(t)) degrees" }
        if let h = state.humidity { label += ", humidity \(Int(h.rounded())) percent" }
        return label + ", \(state.placeName)"
    }
}

private extension CO2Level {
    /// The Dynamic Island is always black: use the night variants' brightness.
    var islandColor: Color {
        switch self {
        case .clear: Color(red: 0.58, green: 0.70, blue: 0.48)
        case .fine: .white
        case .stale: Color(red: 0.84, green: 0.66, blue: 0.35)
        case .poor: Color(red: 0.89, green: 0.42, blue: 0.31)
        }
    }
}
#endif
