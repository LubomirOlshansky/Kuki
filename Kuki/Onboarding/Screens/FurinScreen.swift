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
        "System Settings › Notifications"
        #else
        "Settings › Notifications"
        #endif
    }

    private var rows: [(LimitChoice, String, String)] {
        var out: [(LimitChoice, String, String)] = [
            (.sensitive, "800 ppm · Sensitive", "For bedrooms and sleep. Close to Europe's strictest bedroom level."),
            (.standard, "1000 ppm · The usual line", "Where Germany's Umweltbundesamt stops calling air harmless."),
            (.relaxed, "1200 ppm · Relaxed", "Fewer chimes in busy rooms."),
        ]
        if model.mode == .replay, case .custom(let v) = LimitChoice(ppm: recorder.co2Limit) {
            out.append((.custom(v), "\(Metric.co2.format(v)) ppm · Your current limit", ""))
        }
        return out
    }

    var body: some View {
        @Bindable var recorder = recorder
        let suggested = OnboardingPreselect.suggestedLimit(goals: model.draft.answers.goals)
        VStack(alignment: .leading, spacing: OnboardingMetrics.block) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: OnboardingMetrics.titleToBody) {
                    Eyebrow(kanji: "鈴", word: "Fūrin")
                    ScreenTitle(text: "When should Kūki ring?")
                }
                Spacer(minLength: 12)
                FurinMark(sways: sways)
                    .frame(width: 72, height: 72)
            }

            VStack(spacing: 10) {
                ForEach(rows, id: \.0) { choice, title, subtitle in
                    ChoiceRow(title: title, subtitle: subtitle,
                              tag: choice == suggested ? "Suggested for sleep" : nil,
                              selected: model.draft.staged.limit == choice) {
                        model.draft.staged.limit = choice
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Toggle("Wind-chime sound", isOn: Binding(get: { model.draft.staged.soundOn ?? recorder.soundOn },
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
                    .accessibilityLabel("Play the chime")
                }
                Hairline()
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Also send a notification", isOn: $recorder.notifyOn)
                        .font(Typeface.body)
                        .foregroundStyle(Ink.ink)
                        .tint(Ink.switchOn)
                    Text("Your \(OnboardingCopy.device(platform)) will ask first.")
                        .font(.footnote)
                        .foregroundStyle(Ink.inkSoft)
                    if recorder.notificationsDenied {
                        Text("Notifications are turned off for Kūki. To get them, allow Kūki in \(Self.notificationSettingsPath), then turn \u{201C}Also send a notification\u{201D} on again.")
                            .font(.footnote)
                            .foregroundStyle(Ink.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 4)

            Text("It rings once per stuffy spell, then waits until the air has clearly recovered. Change any of this in Settings.")
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
            Text("鈴").font(Typeface.mincho(34)).foregroundStyle(Ink.inkSoft)
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
