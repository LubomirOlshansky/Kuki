import Foundation

/// 問 Q1 — what fresher air is for. Multi-select.
enum AirGoal: String, CaseIterable, Codable {
    case sleep, focus, freshness, curiosity
}

/// 問 Q2 — how often the rooms are aired today.
enum AiringHabit: String, CaseIterable, Codable {
    case rarely, onceADay, severalTimes, windowUsuallyOpen
}

/// 鈴 Q4 — the CO₂ limit the fūrin rings at.
enum LimitChoice: Equatable, Codable, Hashable {
    case sensitive, standard, relaxed
    /// Only in replay, when the current limit is none of the three.
    case custom(Double)

    var ppm: Double {
        switch self {
        case .sensitive: 800
        case .standard: 1000
        case .relaxed: 1200
        case .custom(let value): value
        }
    }

    static let offered: [LimitChoice] = [.sensitive, .standard, .relaxed]

    init(ppm: Double) {
        switch ppm {
        case 800: self = .sensitive
        case 1000: self = .standard
        case 1200: self = .relaxed
        default: self = .custom(ppm)
        }
    }
}

/// 所 Q3 — where the sensor is.
enum PlaceChoice: Equatable, Hashable {
    case existing(UUID)
    case newPlace(name: String)
}

/// 寝 The bedroom guess: learning only, never written.
enum BedroomGuess: Int, CaseIterable {
    case p600 = 600, p1000 = 1000, p2000 = 2000, p4000 = 4000
}

/// What the user has confirmed so far. nil = not answered: commit writes
/// nothing for it.
struct OnboardingAnswers: Equatable {
    /// nil = screen 2 not confirmed; [] = confirmed with none chosen.
    var goals: Set<AirGoal>? = nil
    var habit: AiringHabit? = nil
    var guess: BedroomGuess? = nil
    var place: PlaceChoice? = nil
    var limit: LimitChoice? = nil
    var soundOn: Bool? = nil
}

/// The answers a screen shows (`staged`, its preselection or the user's taps)
/// and the ones that count (`answers`). A screen's staged values become
/// answers only when its primary button is tapped — Skip on a screen never
/// records what that screen was showing.
struct OnboardingDraft: Equatable {
    var answers = OnboardingAnswers()
    var staged = OnboardingAnswers()

    mutating func confirm(_ step: OnboardingStep) {
        switch step {
        case .questions:
            answers.goals = staged.goals ?? []
            answers.habit = staged.habit
        case .night:
            answers.guess = staged.guess
        case .place:
            answers.place = staged.place
        case .furin:
            answers.limit = staged.limit
            answers.soundOn = staged.soundOn
        case .welcome, .breath, .listen, .appleHome, .plan:
            break
        }
    }
}
