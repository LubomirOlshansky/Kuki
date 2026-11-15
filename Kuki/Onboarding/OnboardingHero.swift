import SwiftUI

/// The Now screen's hero, for the introduction: motes inside the ensō, the
/// numeral in the middle — so the science screens teach the real screen.
struct AirHero: View {
    let ppm: Double
    let size: CGFloat
    var fractionAnimation: Animation? = .easeInOut(duration: 1.2)
    var colorAnimation: Animation? = .easeInOut(duration: 0.4)
    var wind: Double = 0
    /// Per-frame updates (a sweep) skip the numeric-text roll.
    var rolling = true
    var accessibilityLabel = String(localized: "Estimated CO₂", comment: "Onboarding: VoiceOver label of the illustrative CO₂ dial")

    @ScaledMetric(relativeTo: .largeTitle) private var numeralScaled: CGFloat = 64
    @Environment(\.legibilityWeight) private var legibilityWeight

    private var numeralSize: CGFloat { min(max(numeralScaled, size * 0.28), size * 0.32) }

    var body: some View {
        let level = CO2Level(ppm: ppm)
        let digits = Metric.co2.format(ppm)
        ZStack {
            AirMotes(ppm: ppm, color: level == .poor ? Ink.shu : Ink.ink,
                     exclusion: AirMotes.exclusion(digits: digits.count), wind: wind)
                .frame(width: size * 232 / 256, height: size * 232 / 256)
            EnsoRing(fraction: EnsoRing.fraction(for: ppm), color: level.color, lineWidth: 9,
                     fractionAnimation: fractionAnimation, colorAnimation: colorAnimation)
                .frame(width: size, height: size)
            VStack(spacing: 2) {
                Text(digits)
                    .font(Typeface.numeral(numeralSize, bold: legibilityWeight == .bold))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(rolling ? .numericText(value: ppm) : .identity)
                Text(verbatim: "ppm CO₂").kukiLabel()
            }
            .frame(maxWidth: size * 0.72)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(String(localized: "\(Metric.co2.spoken(ppm)), \(level.title)", comment: "VoiceOver value of a CO₂ reading in the onboarding: the spoken reading, then the air level name (e.g. Getting stale)"))
    }
}

/// "淀 Getting stale" — the level's kanji (hidden from VoiceOver) and title.
struct LevelLine: View {
    let level: CO2Level
    var quick = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Text(level.kanji).font(Typeface.mincho(26)).foregroundStyle(level.color)
                .accessibilityHidden(true)
            Text(level.title).font(Typeface.title).foregroundStyle(Ink.ink)
        }
        .id(level)
        .transition(.inkDiffuseOrFade(reduceMotion: reduceMotion))
        .animation(.easeInOut(duration: quick ? 0.35 : 0.8), value: level)
    }
}

/// Hero sizes: Now's ensō scaled to the introduction's room.
enum HeroSize {
    static func science(scaled: CGFloat, viewport: CGSize, column: CGFloat, accessibility: Bool) -> CGFloat {
        let compact = viewport.height < OnboardingMetrics.compactHeight
        var size = min(scaled, column - 56, viewport.height * (accessibility ? 0.40 : 0.34))
        if compact { size = min(size, 170) }
        return max(140, size)
    }
}
