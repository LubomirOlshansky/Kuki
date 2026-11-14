import SwiftUI

/// 問 — what fresher air is for, and how often the rooms are aired now.
struct QuestionsScreen: View {
    @Bindable var model: OnboardingModel

    private let goals: [(AirGoal, String, String, String)] = [
        (.sleep, "眠", "Sleep", "Fresher air at night"),
        (.focus, "集", "Focus", "Long days at a desk"),
        (.freshness, "爽", "Feeling fresh", "Rooms that don't feel stuffy"),
        (.curiosity, "知", "Curiosity", "Seeing what the air does"),
    ]
    private let habits: [(AiringHabit, String, String?)] = [
        (.rarely, "Rarely", "Windows mostly stay shut"),
        (.onceADay, "Once a day", nil),
        (.severalTimes, "A few times a day", nil),
        (.windowUsuallyOpen, "A window is usually open", "Tilted or ajar"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: OnboardingMetrics.block) {
            VStack(alignment: .leading, spacing: OnboardingMetrics.titleToBody) {
                Eyebrow(kanji: "問", word: "Questions")
                ScreenTitle(text: "First, two questions")
            }

            VStack(alignment: .leading, spacing: 10) {
                heading("What would you like fresher air for?", hint: "Choose any")
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
                heading("How often do you air your rooms now?", hint: "Choose one")
                ForEach(habits, id: \.0) { habit, title, subtitle in
                    ChoiceRow(title: title, subtitle: subtitle, selected: model.draft.staged.habit == habit) {
                        model.draft.staged.habit = habit
                    }
                }
            }

            Text("Your answers shape the tips and your plan. Change them any time in Settings.")
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
