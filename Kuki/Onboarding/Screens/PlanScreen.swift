import SwiftData
import SwiftUI

/// 始 — the answers read back as a plan, and the airing reminder offered.
struct PlanScreen: View {
    @Bindable var model: OnboardingModel
    let platform: OnboardingPlatform
    @Environment(Recorder.self) private var recorder
    @Query(sort: \Place.sortIndex) private var places: [Place]
    #if targetEnvironment(macCatalyst)
    @State private var openAtLogin = MenuBarBridge.shared.openAtLogin
    #endif

    private static var notificationSettingsPath: String {
        #if targetEnvironment(macCatalyst)
        "System Settings › Notifications"
        #else
        "Settings › Notifications"
        #endif
    }

    /// The usage-statistics disclosure, with the path to its switch.
    static var analyticsNote: String {
        #if targetEnvironment(macCatalyst)
        "Kūki shares usage statistics to improve the app. You can turn this off in Kūki › Settings… › Privacy."
        #else
        "Kūki shares usage statistics to improve the app. You can turn this off in Settings › Privacy."
        #endif
    }

    var body: some View {
        let answers = model.draft.answers
        let place = model.plannedPlace(places, current: recorder.currentPlaceID)
        let input = PlanInput(
            placeName: place?.name, placeKanji: place?.kanji ?? "",
            goals: answers.goals ?? [], habit: answers.habit,
            limit: answers.limit?.ppm ?? recorder.co2Limit,
            soundOn: answers.soundOn ?? recorder.soundOn, notifyOn: recorder.notifyOn,
            platform: platform, demo: model.demo || recorder.useDemo,
            cloudAvailable: CloudSync.isAvailable, cloudOn: CloudSync.userWantsSync,
            showInDock: recorder.showInDock)
        VStack(alignment: .leading, spacing: OnboardingMetrics.block) {
            VStack(alignment: .leading, spacing: OnboardingMetrics.titleToBody) {
                Eyebrow(kanji: "始", word: "Begin")
                ScreenTitle(text: "Your plan")
            }
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(OnboardingPlan.lines(input).enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Circle().fill(Ink.ink).frame(width: 6, height: 6)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                            .accessibilityHidden(true)
                        Text(Self.styled(line))
                            .font(Typeface.body)
                            .foregroundStyle(Ink.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let times = AiringReminder.suggestedTimes(for: answers.habit) {
                reminder(times: times, placeName: place?.name, suggested: AiringReminder.isSuggested(for: answers.habit))
            }

            #if targetEnvironment(macCatalyst)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Open at Login", isOn: Binding(get: { openAtLogin },
                                                      set: { on in
                                                          openAtLogin = MenuBarBridge.shared.setOpenAtLogin(on)
                                                          Analytics.track("open_at_login_toggled", ["on": openAtLogin])
                                                      }))
                    .font(Typeface.body)
                    .tint(Ink.switchOn)
                Text("So Kūki is back in the menu bar after a restart.")
                    .font(.footnote)
                    .foregroundStyle(Ink.inkSoft)
            }
            #endif

            Text(Self.analyticsNote)
                .font(.footnote)
                .foregroundStyle(Ink.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            if answers.habit != nil {
                SourcesDisclosure(sources: OnboardingSources.airing)
            }
        }
        .frame(maxWidth: OnboardingMetrics.maxColumn, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func reminder(times: [ReminderTime], placeName: String?, suggested: Bool) -> some View {
        let reminders = recorder.reminders
        let room = AiringReminder.title(placeName: placeName)
            .replacingOccurrences(of: "Time to air ", with: "")
        return NoteCard {
            if suggested { Text("Suggested for you").kukiLabel().foregroundStyle(Ink.ink) }
            Toggle(isOn: Binding(get: { reminders.isOn },
                                 set: { on in
                                     if on { reminders.enable(times: times) } else { reminders.isOn = false }
                                     OnboardingAnalytics.answered("reminder", on)
                                 })) {
                Text("Remind me to air \(room)")
                    .font(Typeface.body)
                    .foregroundStyle(Ink.ink)
            }
            .tint(Ink.switchOn)
            Text("Every day at \(AiringReminder.describe(reminders.isOn ? reminders.times : times)): \u{201C}open a window wide for 5 minutes.\u{201D} It's a reminder at set times, not a reading, so it may come when the air is already fresh. Change the times in Settings.")
                .font(.footnote)
                .foregroundStyle(Ink.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            if reminders.denied {
                Text("Notifications are turned off for Kūki. To get reminders, allow Kūki in \(Self.notificationSettingsPath), then turn this on again.")
                    .font(.footnote)
                    .foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The line with its key fact set a little heavier.
    static func styled(_ line: PlanLine) -> AttributedString {
        var text = AttributedString(line.text)
        if let key = line.key, let range = text.range(of: key) {
            text[range].font = Typeface.body.weight(.medium)
        }
        return text
    }
}
