import SwiftUI

/// 鈴 — when the fūrin rings, and whether a notification follows.
struct FurinScreen: View {
    @Bindable var model: OnboardingModel
    let platform: OnboardingPlatform
    @Environment(Recorder.self) private var recorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sways = 0

    private static var notificationSettingsPath: String {
        #if targetEnvironment(macCatalyst)
        String(localized: "System Settings › Notifications", comment: "Path to the macOS notification settings; use Apple's own names for System Settings and Notifications in your language")
        #else
        String(localized: "Settings › Notifications", comment: "Path to the iOS notification settings; use Apple's own names for Settings and Notifications in your language")
        #endif
    }

    private var rows: [(LimitChoice, String, String)] {
        var out: [(LimitChoice, String, String)] = [
            (.sensitive,
             String(localized: "\(Metric.co2.format(800)) ppm · Sensitive", comment: "Onboarding, Fūrin screen: CO₂ limit choice; the placeholder is 800"),
             String(localized: "For bedrooms and sleep. Close to Europe's strictest bedroom level.", comment: "Onboarding, Fūrin screen: subtitle of the 800 ppm limit")),
            (.standard,
             String(localized: "\(Metric.co2.format(1000)) ppm · The usual line", comment: "Onboarding, Fūrin screen: CO₂ limit choice; the placeholder is 1000; line = limit"),
             String(localized: "Where Germany's Umweltbundesamt stops calling air harmless.", comment: "Onboarding, Fūrin screen: subtitle of the 1000 ppm limit. Umweltbundesamt = German Environment Agency, keep the name")),
            (.relaxed,
             String(localized: "\(Metric.co2.format(1200)) ppm · Relaxed", comment: "Onboarding, Fūrin screen: CO₂ limit choice; the placeholder is 1200"),
             String(localized: "Fewer chimes in busy rooms.", comment: "Onboarding, Fūrin screen: subtitle of the 1200 ppm limit")),
        ]
        if model.mode == .replay, case .custom(let v) = LimitChoice(ppm: recorder.co2Limit) {
            out.append((.custom(v), String(localized: "\(Metric.co2.format(v)) ppm · Your current limit", comment: "Onboarding replay, Fūrin screen: the user's own CO₂ limit; the placeholder is a number"), ""))
        }
        return out
    }

    var body: some View {
        @Bindable var recorder = recorder
        let suggested = OnboardingPreselect.suggestedLimit(goals: model.draft.answers.goals)
        VStack(alignment: .leading, spacing: OnboardingMetrics.block) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: OnboardingMetrics.titleToBody) {
                    Eyebrow(kanji: "鈴", word: String(localized: "Fūrin", comment: "Onboarding, Fūrin screen: eyebrow label above the title, small capitals. Fūrin = the Japanese wind chime the app plays as its alert, keep the word"))
                    ScreenTitle(text: String(localized: "When should Kūki ring?", comment: "Onboarding, Fūrin screen: title; ring = play the chime alert"))
                }
                Spacer(minLength: 12)
                FurinMark(sways: sways)
                    .frame(width: 72, height: 72)
            }

            VStack(spacing: 10) {
                ForEach(rows, id: \.0) { choice, title, subtitle in
                    ChoiceRow(title: title, subtitle: subtitle,
                              tag: choice == suggested ? String(localized: "Suggested for sleep", comment: "Onboarding, Fūrin screen: small-capitals tag above a limit choice (short)") : nil,
                              selected: model.draft.staged.limit == choice) {
                        model.draft.staged.limit = choice
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Toggle(String(localized: "Wind-chime sound", comment: "Onboarding, Fūrin screen: switch for the alert sound"), isOn: Binding(get: { model.draft.staged.soundOn ?? recorder.soundOn },
                                                             set: { model.draft.staged.soundOn = $0 }))
                        .font(Typeface.body)
                        .foregroundStyle(Ink.ink)
                        .tint(Ink.switchOn)
                    Button {
                        recorder.previewAlert()
                        sways += 1
                    } label: {
                        Image(systemName: "speaker.wave.2")
                            .font(.body)
                            .foregroundStyle(Ink.ai)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .quietHover(Circle())
                    }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityLabel(Text("Play the chime", comment: "Onboarding, Fūrin screen: VoiceOver label of the speaker button"))
                }
                Hairline()
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(String(localized: "Also send a notification", comment: "Onboarding, Fūrin screen: switch; must match the quoted name in the notifications-off message"), isOn: $recorder.notifyOn)
                        .font(Typeface.body)
                        .foregroundStyle(Ink.ink)
                        .tint(Ink.switchOn)
                    Text("Your \(OnboardingCopy.device(platform)) will ask first.", comment: "Onboarding, Fūrin screen: footnote under the notification switch; the placeholder is iPhone, iPad or Mac")
                        .font(.footnote)
                        .foregroundStyle(Ink.inkSoft)
                    if recorder.notificationsDenied {
                        Text("Notifications are turned off for Kūki. To get them, allow Kūki in \(Self.notificationSettingsPath), then turn \u{201C}Also send a notification\u{201D} on again.", comment: "Onboarding, Fūrin screen: the placeholder is a settings path such as Settings › Notifications; the quoted name must match the switch label Also send a notification")
                            .font(.footnote)
                            .foregroundStyle(Ink.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 4)

            Text("It rings once per stuffy spell, then waits until the air has clearly recovered. Change any of this in Settings.", comment: "Onboarding, Fūrin screen: footnote; it = the chime; stuffy spell = a period of stale indoor air")
                .font(.footnote)
                .foregroundStyle(Ink.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            SourcesDisclosure(sources: OnboardingSources.limits)
        }
        .frame(maxWidth: OnboardingMetrics.maxColumn, alignment: .leading)
        .frame(maxWidth: .infinity)
        .onAppear {
            if model.draft.staged.limit == nil {
                model.draft.staged.limit = OnboardingPreselect.limit(
                    goals: model.draft.answers.goals, current: model.mode == .replay ? recorder.co2Limit : nil)
            }
            if model.draft.staged.soundOn == nil { model.draft.staged.soundOn = recorder.soundOn }
        }
    }
}

/// 鈴 with a paper strip (tanzaku) under it; it sways when the chime plays.
private struct FurinMark: View {
    let sways: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 2) {
            Text(verbatim: "鈴").font(Typeface.mincho(34)).foregroundStyle(Ink.inkSoft)
                .sway(sways, amplitude: 1, lag: 0, off: reduceMotion)
            Rectangle().fill(Ink.hairline).frame(width: 6, height: 22)
                .overlay(Rectangle().stroke(Ink.inkFaint, lineWidth: 0.5))
                .sway(sways, amplitude: 1.4, lag: 0.08, off: reduceMotion)
        }
        .accessibilityHidden(true)
    }
}

private extension View {
    func sway(_ trigger: Int, amplitude: Double, lag: Double, off: Bool) -> some View {
        keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, angle in
            view.rotationEffect(.degrees(off ? 0 : angle * amplitude), anchor: .top)
        } keyframes: { _ in
            CubicKeyframe(0, duration: max(0.001, lag))
            CubicKeyframe(7, duration: 0.18)
            CubicKeyframe(-5, duration: 0.30)
            CubicKeyframe(3.5, duration: 0.30)
            CubicKeyframe(-2, duration: 0.30)
            CubicKeyframe(0, duration: 0.40)
        }
    }
}
