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
                Eyebrow(kanji: "息", word: String(localized: "Breath", comment: "Onboarding, Breath screen: eyebrow label above the title, small capitals (one short word)"))
                ScreenTitle(text: String(localized: "Indoors, you breathe each other's air.", comment: "Onboarding, Breath screen: title"))
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
                    Text(verbatim: "CO₂")
                } onEditingChanged: { editing in
                    if editing { model.noteInteraction("ppm_dial") }
                    if editing, glideStart != nil { ppm = shown; glideStart = nil }
                }
                .tint(level.color)
                .accessibilityValue(String(localized: "\(Metric.co2.spoken(shown)), \(level.title)", comment: "VoiceOver value of a CO₂ reading in the onboarding: the spoken reading, then the air level name (e.g. Getting stale)"))
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
        let percent = OnboardingCopy.rebreathedFraction(ppm: shown).formatted(.percent.precision(.fractionLength(1)))
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(percent)
                .font(Typeface.numeral(shareSize, bold: true).weight(.light))
                .foregroundStyle(Ink.ink)
                .contentTransition(.numericText(value: fraction))
                .animation(.smooth(duration: 0.3), value: fraction)
            Text("of each breath, already breathed", comment: "Onboarding, Breath screen: small-capitals label after a large percentage, e.g. 1.5% | of each breath, already breathed").kukiLabel()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(percent) of each breath was already breathed", comment: "Onboarding, Breath screen: VoiceOver label; the placeholder is a percentage such as 1.5%"))
    }

    // MARK: Words

    private var words: some View {
        let goals = model.draft.answers.goals ?? []
        let wide = WideReader.isWide(viewport, dynamicTypeSize)
        return VStack(alignment: .leading, spacing: OnboardingMetrics.block) {
            if wide {
                VStack(alignment: .leading, spacing: OnboardingMetrics.titleToBody) {
                    Eyebrow(kanji: "息", word: String(localized: "Breath", comment: "Onboarding, Breath screen: eyebrow label above the title, small capitals (one short word)"))
                    ScreenTitle(text: String(localized: "Indoors, you breathe each other's air.", comment: "Onboarding, Breath screen: title"))
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                BodyText(String(localized: "Outside, air holds about 430 ppm of CO₂. Every breath out holds around 40,000 ppm, nearly a hundred times more.", comment: "Onboarding, Breath screen: lead paragraph"), ink: true)
                BodyText(String(localized: "So indoor CO₂ is a measure of air that's already been breathed. At 1000 ppm, roughly 1.5% of each breath was recently someone's exhale.", comment: "Onboarding, Breath screen: body paragraph"))
                if goals.contains(.freshness) {
                    PersonalLine(text: String(localized: "That stuffy feeling often starts here.", comment: "Onboarding, Breath screen: personal line for users who chose the Feeling fresh goal; stuffy = stale indoor air"))
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("1000 ppm is a signal, not a danger line.", comment: "Onboarding, Breath screen: section heading")
                    .font(Typeface.title)
                    .foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                BodyText(String(localized: "Germany's Umweltbundesamt calls indoor air under 1000 ppm harmless, 1000–2000 ppm \u{201C}conspicuous\u{201D}, and over 2000 unacceptable. ASHRAE treats CO₂ as a sign of how well a room is ventilated, not as a health limit.", comment: "Onboarding, Breath screen: body paragraph. Umweltbundesamt (German Environment Agency) and ASHRAE are proper names; use your language's quotation marks"))
                BodyText(String(localized: "Studies of thinking at these levels are mixed, and the rest of stale air may matter as much as the CO₂. Kūki calls air \u{201C}getting stale\u{201D} from 1000 ppm and \u{201C}stuffy\u{201D} from 1400.", comment: "Onboarding, Breath screen: body paragraph. The quoted words must match the air level names Getting stale and Stuffy used elsewhere in the app"))
                if goals.contains(.focus) {
                    PersonalLine(text: String(localized: "For focus: open a window before long work, not after.", comment: "Onboarding, Breath screen: personal line for users who chose the Focus goal"))
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
