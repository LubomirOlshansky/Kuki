import SwiftUI

/// 問 — what fresher air is for, and how often the rooms are aired now.
struct QuestionsScreen: View {
    @Bindable var model: OnboardingModel

    private let goals: [(AirGoal, String, String, String)] = [
        (.sleep, "眠", String(localized: "Sleep", comment: "Onboarding, Questions screen: goal choice title (short)"), String(localized: "Fresher air at night", comment: "Onboarding, Questions screen: subtitle of the Sleep goal")),
        (.focus, "集", String(localized: "Focus", comment: "Onboarding, Questions screen: goal choice title, concentration at work (short)"), String(localized: "Long days at a desk", comment: "Onboarding, Questions screen: subtitle of the Focus goal")),
        (.freshness, "爽", String(localized: "Feeling fresh", comment: "Onboarding, Questions screen: goal choice title (short)"), String(localized: "Rooms that don't feel stuffy", comment: "Onboarding, Questions screen: subtitle of the Feeling fresh goal; stuffy = stale indoor air")),
        (.curiosity, "知", String(localized: "Curiosity", comment: "Onboarding, Questions screen: goal choice title (short)"), String(localized: "Seeing what the air does", comment: "Onboarding, Questions screen: subtitle of the Curiosity goal")),
    ]
    private let habits: [(AiringHabit, String, String?)] = [
        (.rarely, String(localized: "Rarely", comment: "Onboarding, Questions screen: answer to how often rooms are aired"), String(localized: "Windows mostly stay shut", comment: "Onboarding, Questions screen: subtitle of the Rarely answer")),
        (.onceADay, String(localized: "Once a day", comment: "Onboarding, Questions screen: answer to how often rooms are aired"), nil),
        (.severalTimes, String(localized: "A few times a day", comment: "Onboarding, Questions screen: answer to how often rooms are aired"), nil),
        (.windowUsuallyOpen, String(localized: "A window is usually open", comment: "Onboarding, Questions screen: answer to how often rooms are aired"), String(localized: "Tilted or ajar", comment: "Onboarding, Questions screen: subtitle; a window tilted open at the top (tilt-and-turn window) or slightly open")),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: OnboardingMetrics.block) {
            VStack(alignment: .leading, spacing: OnboardingMetrics.titleToBody) {
                Eyebrow(kanji: "問", word: String(localized: "Questions", comment: "Onboarding, Questions screen: eyebrow label above the title, small capitals (one short word)"))
                ScreenTitle(text: String(localized: "First, two questions", comment: "Onboarding, Questions screen: title"))
            }

            VStack(alignment: .leading, spacing: 10) {
                heading(String(localized: "What would you like fresher air for?", comment: "Onboarding, Questions screen: question heading"), hint: String(localized: "Choose any", comment: "Onboarding, Questions screen: hint under a multiple-choice question, small capitals (short)"))
                ForEach(goals, id: \.0) { goal, kanji, title, subtitle in
                    let chosen = model.draft.staged.goals?.contains(goal) ?? false
                    ChoiceRow(kanji: kanji, title: title, subtitle: subtitle, selected: chosen, multiSelect: true) {
                        var set = model.draft.staged.goals ?? []
                        if chosen { set.remove(goal) } else { set.insert(goal) }
                        model.draft.staged.goals = set
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                heading(String(localized: "How often do you air your rooms now?", comment: "Onboarding, Questions screen: question heading; to air = ventilate by opening windows"), hint: String(localized: "Choose one", comment: "Onboarding, Questions screen: hint under a single-choice question, small capitals (short)"))
                ForEach(habits, id: \.0) { habit, title, subtitle in
                    ChoiceRow(title: title, subtitle: subtitle, selected: model.draft.staged.habit == habit) {
                        model.draft.staged.habit = habit
                    }
                }
            }

            Text("Your answers shape the tips and your plan. Change them any time in Settings.", comment: "Onboarding, Questions screen: footnote")
                .font(.footnote)
                .foregroundStyle(Ink.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: OnboardingMetrics.maxColumn, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func heading(_ text: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(Typeface.title)
                .foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(hint).kukiLabel()
        }
        .padding(.bottom, 4)
    }
}
