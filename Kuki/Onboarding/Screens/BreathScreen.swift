import SwiftUI

/// 息 — indoor CO₂ is breathed air, and 1000 ppm is a signal, not a danger
/// line. One dial carries both: as it rises the motes fill the ensō and the
/// share of each breath that was already breathed climbs with it.
struct BreathScreen: View {
    @Bindable var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingViewport) private var viewport
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var ensoScaled: CGFloat = 220
    @ScaledMetric(relativeTo: .largeTitle) private var shareSize: CGFloat = 34

    @State private var ppm = 1000.0
    /// When the opening glide started; nil once it's over (or interrupted).
    @State private var glideStart: Date?

    static let range = 420.0...2000.0
    static let glideLength = 2.8

    var body: some View {
        let wide = WideReader.isWide(viewport, dynamicTypeSize)
        let column = wide ? viewport.width / 2 : min(viewport.width, OnboardingMetrics.maxColumn)
        let size = HeroSize.science(scaled: ensoScaled, viewport: viewport, column: column,
                                    accessibility: dynamicTypeSize.isAccessibilitySize)
        ScienceColumns {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: glideStart == nil)) { context in
                let shown = glideStart.map { Self.glide(at: context.date.timeIntervalSince($0)) } ?? ppm
                dial(shown: shown, size: size)
            }
        } words: {
            words
        }
        .frame(maxWidth: .infinity)
        .task { await startGlide() }
    }

    // MARK: Dial

    private func dial(shown: Double, size: CGFloat) -> some View {
        let level = CO2Level(ppm: shown)
        let gliding = glideStart != nil
        return VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: OnboardingMetrics.titleToBody) {
                Eyebrow(kanji: "息", word: "Breath")
                ScreenTitle(text: "Indoors, you breathe each other's air.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(WideReader.isWide(viewport, dynamicTypeSize) ? 0 : 1)
            .frame(height: WideReader.isWide(viewport, dynamicTypeSize) ? 0 : nil)
            .accessibilityHidden(WideReader.isWide(viewport, dynamicTypeSize))

            AirHero(ppm: shown, size: size,
                    fractionAnimation: gliding ? nil : .interactiveSpring(response: 0.25, dampingFraction: 0.9),
                    colorAnimation: .easeInOut(duration: 0.4), rolling: !gliding,
                    accessibilityLabel: "CO₂")
            VStack(spacing: 6) {
                LevelLine(level: level, quick: true)
                Text(OnboardingCopy.bandNote(ppm: shown))
                    .font(.subheadline)
                    .foregroundStyle(Ink.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(OnboardingCopy.bandNote(ppm: shown))
                    .transition(.inkDiffuseOrFade(reduceMotion: reduceMotion))
                    .animation(.easeInOut(duration: 0.35), value: OnboardingCopy.bandNote(ppm: shown))
            }
            .frame(minHeight: 64, alignment: .top)

            VStack(spacing: 4) {
                // No `step:` — on iOS 26 a stepped slider draws a tick per step.
                Slider(value: Binding(get: { shown }, set: { glideStart = nil; ppm = ($0 / 10).rounded() * 10 }),
                       in: Self.range) {
                    Text("CO₂")
                } onEditingChanged: { editing in
                    if editing { model.noteInteraction("ppm_dial") }
                    if editing, glideStart != nil { ppm = shown; glideStart = nil }
                }
                .tint(level.color)
                .accessibilityValue("\(Metric.co2.spoken(shown)), \(level.title)")
                Ticks()
            }
            .sensoryFeedback(.selection, trigger: level)

            share(shown)
        }
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity)
    }

    /// "1.5% — of each breath, already breathed".
    private func share(_ shown: Double) -> some View {
        let fraction = OnboardingCopy.rebreathedFraction(ppm: shown) * 100
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(String(format: "%.1f%%", fraction))
                .font(Typeface.numeral(shareSize, bold: true).weight(.light))
                .foregroundStyle(Ink.ink)
                .contentTransition(.numericText(value: fraction))
                .animation(.smooth(duration: 0.3), value: fraction)
            Text("of each breath, already breathed").kukiLabel()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: "%.1f percent of each breath was already breathed", fraction))
    }

    // MARK: Words

    private var words: some View {
        let goals = model.draft.answers.goals ?? []
        let wide = WideReader.isWide(viewport, dynamicTypeSize)
        return VStack(alignment: .leading, spacing: OnboardingMetrics.block) {
            if wide {
                VStack(alignment: .leading, spacing: OnboardingMetrics.titleToBody) {
                    Eyebrow(kanji: "息", word: "Breath")
                    ScreenTitle(text: "Indoors, you breathe each other's air.")
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                BodyText("Outside, air holds about 430 ppm of CO₂. Every breath out holds around 40,000 ppm, nearly a hundred times more.", ink: true)
                BodyText("So indoor CO₂ is a measure of air that's already been breathed. At 1000 ppm, roughly 1.5% of each breath was recently someone's exhale.")
                if goals.contains(.freshness) {
                    PersonalLine(text: "That stuffy feeling often starts here.")
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("1000 ppm is a signal, not a danger line.")
                    .font(Typeface.title)
                    .foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                BodyText("Germany's Umweltbundesamt calls indoor air under 1000 ppm harmless, 1000–2000 ppm \u{201C}conspicuous\u{201D}, and over 2000 unacceptable. ASHRAE treats CO₂ as a sign of how well a room is ventilated, not as a health limit.")
                BodyText("Studies of thinking at these levels are mixed, and the rest of stale air may matter as much as the CO₂. Kūki calls air \u{201C}getting stale\u{201D} from 1000 ppm and \u{201C}stuffy\u{201D} from 1400.")
                if goals.contains(.focus) {
                    PersonalLine(text: "For focus: open a window before long work, not after.")
                }
            }
            Text(SourcesDisclosure.medicalFinePrint)
                .font(.footnote)
                .foregroundStyle(Ink.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            SourcesDisclosure(sources: OnboardingSources.breath, showsMedicalLine: false)
        }
    }

    // MARK: Glide

    /// 430 → 1400 (1.6 s) → 1000 (1.2 s): the room fills, then lands on the line.
    static func glide(at t: Double) -> Double {
        func ease(_ u: Double) -> Double { u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2 }
        if t <= 0 { return 430 }
        if t < 1.6 { return 430 + (1400 - 430) * ease(t / 1.6) }
        if t < glideLength { return 1400 + (1000 - 1400) * ease((t - 1.6) / 1.2) }
        return 1000
    }

    private func startGlide() async {
        guard !model.breathGlided else { return }
        model.breathGlided = true
        guard !reduceMotion else { ppm = 1000; return }
        try? await Task.sleep(for: .milliseconds(400))
        let start = Date.now
        glideStart = start
        try? await Task.sleep(for: .seconds(Self.glideLength))
        if glideStart == start { ppm = 1000; glideStart = nil }
    }
}

/// 800 · 1000 · 1400 · 2000 under the slider, at their places; 1000 carries
/// the shu limit line.
private struct Ticks: View {
    private let ticks: [Double] = [800, 1000, 1400, 2000]

    var body: some View {
        GeometryReader { geo in
            // The slider's track is inset by about half a thumb on each side.
            let inset: CGFloat = 14
            let track = geo.size.width - inset * 2
            ForEach(ticks, id: \.self) { tick in
                let u = (tick - BreathScreen.range.lowerBound) / (BreathScreen.range.upperBound - BreathScreen.range.lowerBound)
                VStack(spacing: 3) {
                    Rectangle()
                        .fill(tick == 1000 ? Ink.shu : Ink.hairline)
                        .frame(width: 1, height: 8)
                    Text(Metric.co2.format(tick)).kukiLabel().fixedSize()
                }
                .position(x: inset + track * u, y: 14)
            }
        }
        .frame(height: 30)
        .accessibilityHidden(true)
    }
}
