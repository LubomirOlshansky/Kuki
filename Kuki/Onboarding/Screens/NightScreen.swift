import Accessibility
import SwiftUI

/// 寝 — guess first, then watch a closed bedroom fill overnight, and air it.
struct NightScreen: View {
    @Bindable var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingViewport) private var viewport
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var ensoScaled: CGFloat = 220

    @State private var sleepers = 2
    @State private var hours = 8.0
    @State private var windowOpen = false
    @State private var wind = 0.0
    /// A running tween of the shown value: the opening sweep, or the airing.
    @State private var tween: Tween?
    @State private var showReply = false
    @State private var lastChange: Change = .none
    @State private var airingDone = false

    private enum Change { case none, hours, people }

    private struct Tween: Equatable {
        enum Kind { case sweep, airing }
        let kind: Kind
        let from: Double
        let to: Double
        let start: Date
        let duration: Double

        func value(at date: Date, sleepers: Int, hours: Double) -> Double {
            let u = min(1, max(0, date.timeIntervalSince(start) / duration))
            switch kind {
            case .sweep:
                let p = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
                return BedroomModel.ppm(sleepers: sleepers, hours: hours * p)
            case .airing:
                // A fast drop that settles, like exponential decay.
                let p = 1 - pow(1 - u, 3)
                return from + (to - from) * p
            }
        }
    }

    private var closedPPM: Double { BedroomModel.ppm(sleepers: sleepers, hours: hours) }
    private var targetPPM: Double {
        windowOpen ? BedroomModel.afterAiring(from: closedPPM, minutes: 5, sleepers: sleepers) : closedPPM
    }

    var body: some View {
        let wide = WideReader.isWide(viewport, dynamicTypeSize)
        VStack(alignment: .leading, spacing: OnboardingMetrics.block) {
            VStack(alignment: .leading, spacing: OnboardingMetrics.titleToBody) {
                Eyebrow(kanji: "寝", word: String(localized: "Night", comment: "Onboarding, Night screen: eyebrow label above the title, small capitals (one short word)"))
                ScreenTitle(text: String(localized: "A closed bedroom fills up fast.", comment: "Onboarding, Night screen: title; fills up = with exhaled CO₂"))
            }
            .frame(maxWidth: wide ? OnboardingMetrics.maxWide : OnboardingMetrics.maxColumn, alignment: .leading)
            if model.nightRevealed {
                ScienceColumns {
                    simulator
                } words: {
                    facts
                }
                .transition(.opacity)
            } else {
                guess
                    .frame(maxWidth: OnboardingMetrics.maxColumn, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            sleepers = OnboardingPreselect.sleepers(goals: model.draft.answers.goals)
            if model.nightRevealed { showReply = true }
        }
        .onChange(of: model.nightRevealRequests) {
            if !model.nightRevealed { reveal() }
        }
    }

    // MARK: Phase A

    private var guess: some View {
        VStack(alignment: .leading, spacing: OnboardingMetrics.bodyToControl) {
            Text("Guess first: two people asleep, window shut, eight hours. Where does CO₂ end up?", comment: "Onboarding, Night screen: quiz question; the answers are CO₂ values in ppm")
                .font(Typeface.title)
                .foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
            // One row when it fits, two when it doesn't, a list at accessibility sizes.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) { chips(BedroomGuess.allCases) }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { chips(BedroomGuess.allCases) }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) { chips([.p600, .p1000]) }
                        HStack(spacing: 10) { chips([.p2000, .p4000]) }
                    }
                }
            }
            // "Show me" is the bottom bar's button (see `nightPrimary`).
        }
    }

    private func chips(_ guesses: [BedroomGuess]) -> some View {
        ForEach(guesses, id: \.self) { g in
            Chip(title: Metric.co2.format(Double(g.rawValue)), accessibilityText: String(localized: "\(Metric.co2.format(Double(g.rawValue))) ppm", comment: "A CO₂ value with its unit, e.g. 812 ppm. Keep ppm."),
                 selected: model.draft.staged.guess == g) {
                model.draft.staged.guess = g
                model.noteInteraction("guess")
                reveal()
            }
        }
    }

    private func reveal() {
        withAnimation(.easeInOut(duration: 0.4)) { model.nightRevealed = true }
        guard !reduceMotion else { showReply = true; return }
        let sweep = Tween(kind: .sweep, from: BedroomModel.outdoor, to: closedPPM, start: .now.addingTimeInterval(0.4),
                          duration: 2.4)
        tween = sweep
        Task {
            try? await Task.sleep(for: .seconds(2.8))
            if tween == sweep { tween = nil }
            withAnimation(.easeOut(duration: 0.6)) { showReply = true }
        }
    }

    // MARK: Phase B

    private var simulator: some View {
        let column = WideReader.isWide(viewport, dynamicTypeSize) ? viewport.width / 2 : min(viewport.width, OnboardingMetrics.maxColumn)
        let size = HeroSize.science(scaled: ensoScaled, viewport: viewport, column: column,
                                    accessibility: dynamicTypeSize.isAccessibilitySize)
        return VStack(spacing: 18) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: tween == nil)) { context in
                let shown = tween?.value(at: context.date, sleepers: sleepers, hours: hours) ?? targetPPM
                VStack(spacing: 12) {
                    AirHero(ppm: shown, size: size, fractionAnimation: fractionAnimation,
                            colorAnimation: .easeInOut(duration: tween == nil ? 0.4 : 0.5),
                            wind: wind, rolling: tween == nil)
                    LevelLine(level: CO2Level(ppm: shown), quick: tween == nil)
                }
                .sensoryFeedback(.selection, trigger: CO2Level(ppm: shown))
            }
            if showReply {
                Text(OnboardingCopy.guessReply(model.draft.staged.guess, morning: BedroomModel.ppm(sleepers: 2, hours: 8)))
                    .font(.subheadline)
                    .foregroundStyle(Ink.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.inkDiffuseOrFade(reduceMotion: reduceMotion))
            }
            controls
        }
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity)
    }

    private var fractionAnimation: Animation? {
        if tween != nil { return nil }
        switch lastChange {
        case .people: return .smooth(duration: 0.6)
        case .hours: return .interactiveSpring(response: 0.25, dampingFraction: 0.9)
        case .none: return .timingCurve(0.2, 0, 0, 1, duration: 1.6)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("People asleep", comment: "Onboarding, Night screen: label above a 1/2/3 picker, small capitals").kukiLabel()
                Picker(String(localized: "People asleep", comment: "Onboarding, Night screen: label above a 1/2/3 picker, small capitals"), selection: Binding(get: { sleepers }, set: { v in
                    lastChange = .people; sleepers = v
                    model.noteInteraction("people")
                })) {
                    ForEach(1...3, id: \.self) { Text($0.formatted()).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityValue(String(localized: "\(sleepers) people", comment: "Onboarding, Night screen: VoiceOver value of the people-asleep picker (plural)"))
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Hours asleep", comment: "Onboarding, Night screen: label above the hours slider, small capitals").kukiLabel()
                    Spacer()
                    Text(hoursText).font(.subheadline.monospacedDigit()).foregroundStyle(Ink.ink)
                }
                Slider(value: Binding(get: { hours }, set: { v in
                    lastChange = .hours; tween = nil; hours = (v * 2).rounded() / 2
                    model.noteInteraction("hours_slider")
                }), in: 0...8) { Text("Hours asleep", comment: "Onboarding, Night screen: label above the hours slider, small capitals") }
                    .tint(CO2Level(ppm: targetPPM).color)
                    .accessibilityValue(String(localized: "\(hoursSpoken), \(Metric.co2.spoken(targetPPM)), \(CO2Level(ppm: targetPPM).title)", comment: "Onboarding, Night screen: VoiceOver value of the hours slider: hours asleep, the spoken CO₂ reading, then the air level name"))
            }
            HStack {
                Spacer()
                OutlineButton(title: windowOpen
                                ? String(localized: "Close the window", comment: "Onboarding, Night screen: button in the bedroom simulator (keep short)")
                                : String(localized: "Open the window · 5 min", comment: "Onboarding, Night screen: button in the bedroom simulator; airs the room for 5 minutes (keep short)"),
                              systemImage: windowOpen ? "window.horizontal.closed" : "wind") { toggleWindow() }
                Spacer()
            }
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: windowOpen) { _, open in open }

            Text(readout)
                .font(.subheadline)
                .foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: readout)
            Text("Estimate for a 30 m³ bedroom with the window shut.", comment: "Onboarding, Night screen: footnote under the simulator")
                .font(.footnote)
                .foregroundStyle(Ink.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hoursNumber: String { hours.formatted(.number.precision(.fractionLength(0...1))) }

    private var hoursText: String {
        String(localized: "\(hoursNumber) h", comment: "Onboarding, Night screen: hours asleep, abbreviated, e.g. 8 h or 1.5 h (very short)")
    }

    private var hoursSpoken: String {
        if hours == hours.rounded() {
            return String(localized: "\(Int(hours)) hours", comment: "Onboarding, Night screen: hours asleep, spoken by VoiceOver (plural)")
        }
        return String(localized: "\(hoursNumber) hours", comment: "Onboarding, Night screen: a fractional number of hours asleep such as 1.5, spoken by VoiceOver")
    }

    private var readout: String {
        if windowOpen && airingDone {
            let before = Metric.co2.format((closedPPM / 10).rounded() * 10)
            let after = Metric.co2.format((targetPPM / 10).rounded() * 10)
            return String(localized: "Window wide for 5 minutes: \(before) → \(after) ppm.", comment: "Onboarding, Night screen: simulator readout; CO₂ before → after airing, in ppm")
        }
        return OnboardingCopy.closedReadout(sleepers: sleepers)
    }

    private func toggleWindow() {
        let before = targetPPM
        model.noteInteraction("window")
        lastChange = .none
        if windowOpen {
            windowOpen = false
            airingDone = false
            tween = nil
            return
        }
        windowOpen = true
        let after = targetPPM
        guard !reduceMotion else {
            airingDone = true
            announce(after)
            return
        }
        let airing = Tween(kind: .airing, from: before, to: after, start: .now, duration: 1.6)
        tween = airing
        withAnimation(.easeIn(duration: 0.4)) { wind = 1 }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.4)) { wind = 0 }
            if tween == airing { tween = nil }
            try? await Task.sleep(for: .seconds(0.4))
            withAnimation { airingDone = true }
            announce(after)
        }
    }

    private func announce(_ after: Double) {
        AccessibilityNotification.Announcement(
            String(localized: "Window open for 5 minutes. CO₂ falls to \(Metric.co2.format((after / 10).rounded() * 10)) ppm.",
                   comment: "Onboarding, Night screen: VoiceOver announcement after airing in the simulator; the placeholder is a CO₂ value")).post()
    }

    // MARK: Facts

    private var facts: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyText(String(localized: "In one study, student bedrooms averaged 2585 ppm with the window shut and 660 ppm with it open. With fresher air, students slept better and felt less sleepy the next day.", comment: "Onboarding, Night screen: lead paragraph"), ink: true)
            BodyText(String(localized: "In a sleep lab, nights at 1000 ppm or more brought slightly less efficient sleep than nights at 750. Small studies, but they point the same way.", comment: "Onboarding, Night screen: body paragraph"))
            if (model.draft.answers.goals ?? []).contains(.sleep),
               OnboardingPreselect.suggestedLimit(goals: model.draft.answers.goals) != nil {
                PersonalLine(text: String(localized: "You chose sleep. Kūki will suggest a lower limit for you.", comment: "Onboarding, Night screen: personal line for users who chose the Sleep goal; limit = CO₂ alert limit"))
            }
            SourcesDisclosure(sources: OnboardingSources.night)
                .padding(.top, 6)
        }
    }
}
