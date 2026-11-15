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
        String(localized: "System Settings › Notifications", comment: "Path to the macOS notification settings; use Apple's own names for System Settings and Notifications in your language")
        #else
        String(localized: "Settings › Notifications", comment: "Path to the iOS notification settings; use Apple's own names for Settings and Notifications in your language")
        #endif
    }

    /// The usage-statistics disclosure, with the path to its switch.
    static var analyticsNote: String {
        #if targetEnvironment(macCatalyst)
        String(localized: "Kūki shares usage statistics to improve the app. You can turn this off in Kūki › Settings… › Privacy.",
               comment: "Onboarding, Plan screen, Mac: analytics disclosure. Kūki › Settings… › Privacy is the path to the app's own setting; Settings… and Privacy must match the menu item and the Settings section names")
        #else
        String(localized: "Kūki shares usage statistics to improve the app. You can turn this off in Settings › Privacy.",
               comment: "Onboarding, Plan screen: analytics disclosure. Settings › Privacy is the path to the app's own setting; Privacy must match the section name in the app's Settings")
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
                Eyebrow(kanji: "始", word: String(localized: "Begin", comment: "Onboarding, Plan screen: eyebrow label above the title, small capitals (one short word)"))
                ScreenTitle(text: String(localized: "Your plan", comment: "Onboarding, Plan screen: title"))
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
                Toggle(String(localized: "Open at Login", comment: "Onboarding, Plan screen, Mac: switch; use the standard macOS wording for opening an app at login"), isOn: Binding(get: { openAtLogin },
                                                      set: { on in
                                                          openAtLogin = MenuBarBridge.shared.setOpenAtLogin(on)
                                                          Analytics.track("open_at_login_toggled", ["on": openAtLogin])
                                                      }))
                    .font(Typeface.body)
                    .tint(Ink.switchOn)
                Text("So Kūki is back in the menu bar after a restart.", comment: "Onboarding, Plan screen, Mac: footnote under Open at Login")
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
        return NoteCard {
            if suggested {
                Text("Suggested for you", comment: "Onboarding, Plan screen: small-capitals tag above the reminder switch (short)")
                    .kukiLabel().foregroundStyle(Ink.ink)
            }
            Toggle(isOn: Binding(get: { reminders.isOn },
                                 set: { on in
                                     if on { reminders.enable(times: times) } else { reminders.isOn = false }
                                     OnboardingAnalytics.answered("reminder", on)
                                 })) {
                Text(Self.remindTitle(placeName: placeName))
                    .font(Typeface.body)
                    .foregroundStyle(Ink.ink)
            }
            .tint(Ink.switchOn)
            Text("Every day at \(AiringReminder.describe(reminders.isOn ? reminders.times : times)): \u{201C}open a window wide for 5 minutes.\u{201D} It's a reminder at set times, not a reading, so it may come when the air is already fresh. Change the times in Settings.",
                 comment: "Onboarding, Plan screen: under the reminder switch; the placeholder is a list of times, e.g. 9:00 and 20:00. The quoted words repeat the reminder notification's text.")
                .font(.footnote)
                .foregroundStyle(Ink.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            if reminders.denied {
                Text("Notifications are turned off for Kūki. To get reminders, allow Kūki in \(Self.notificationSettingsPath), then turn this on again.",
                     comment: "Onboarding, Plan screen: the placeholder is a settings path such as Settings › Notifications")
                    .font(.footnote)
                    .foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Remind me to air the bedroom": one sentence per seeded room (as the
    /// reminder's own title), so each language can inflect it; a typed name
    /// stays exactly as typed.
    static func remindTitle(placeName: String?) -> String {
        guard let name = placeName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return String(localized: "Remind me to air the room", comment: "Onboarding, Plan screen: airing reminder switch when no room is known; to air = to ventilate")
        }
        switch Place.seededIndex(name) {
        case 0: return String(localized: "Remind me to air the living room", comment: "Onboarding, Plan screen: airing reminder switch for the default Living room")
        case 1: return String(localized: "Remind me to air the bedroom", comment: "Onboarding, Plan screen: airing reminder switch for the default Bedroom")
        case 2: return String(localized: "Remind me to air the study", comment: "Onboarding, Plan screen: airing reminder switch for the default Study (home office)")
        case 3: return String(localized: "Remind me to air the kitchen", comment: "Onboarding, Plan screen: airing reminder switch for the default Kitchen")
        default:
            return String(localized: "Remind me to air \(name)", comment: "Onboarding, Plan screen: airing reminder switch; the placeholder is a room name the user typed, exactly as typed")
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
