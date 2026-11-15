import Foundation
import UIKit

/// The introduction's screens, in order. "The line" (the ppm dial) lives
/// inside Breath, so the full path is nine screens.
enum OnboardingStep: String, CaseIterable, Codable {
    case welcome, questions, breath, night, listen, appleHome, place, furin, plan
}

// MARK: - Path

enum OnboardingPath {
    /// The demo path skips Apple Home.
    static func steps(demo: Bool) -> [OnboardingStep] {
        demo ? OnboardingStep.allCases.filter { $0 != .appleHome } : OnboardingStep.allCases
    }

    /// 0-based position of `step` on the path; nil if the path doesn't have it.
    static func index(of step: OnboardingStep, demo: Bool) -> Int? {
        steps(demo: demo).firstIndex(of: step)
    }

    static func next(after step: OnboardingStep, demo: Bool) -> OnboardingStep? {
        let path = steps(demo: demo)
        guard let i = path.firstIndex(of: step), i + 1 < path.count else { return nil }
        return path[i + 1]
    }

    static func previous(before step: OnboardingStep, demo: Bool) -> OnboardingStep? {
        let path = steps(demo: demo)
        guard let i = path.firstIndex(of: step), i > 0 else { return nil }
        return path[i - 1]
    }

    /// Where a relaunch picks up: the saved step — except Apple Home before
    /// it was ever asked for, which goes back to the screen that asks.
    static func resumeStep(saved: String?, homeKitRequested: Bool) -> OnboardingStep {
        guard let saved, let step = OnboardingStep(rawValue: saved) else { return .welcome }
        if step == .appleHome && !homeKitRequested { return .listen }
        return step
    }
}

// MARK: - Preselection

/// A place as the quiz needs it, without SwiftData.
struct PlaceRef: Equatable, Identifiable {
    let id: UUID
    let name: String
    let kanji: String
    let sortIndex: Int
}

enum OnboardingPreselect {
    /// Everyone starts at the usual line. A lower limit is only *suggested*
    /// (`suggestedLimit`), never chosen for the user. In replay the current
    /// limit is preselected.
    static func limit(goals: Set<AirGoal>?, current: Double? = nil) -> LimitChoice {
        if let current { return LimitChoice(ppm: current) }
        return .standard
    }

    /// The row that wears "Suggested for sleep".
    static func suggestedLimit(goals: Set<AirGoal>?) -> LimitChoice? {
        (goals ?? []).contains(.sleep) ? .sensitive : nil
    }

    static func place(places: [PlaceRef], homeKitRoom: String?, goals: Set<AirGoal>?, current: UUID?) -> PlaceChoice? {
        let sorted = places.sorted { $0.sortIndex < $1.sortIndex }
        let room = (homeKitRoom ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        func named(_ name: String) -> PlaceRef? {
            sorted.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }
        if !room.isEmpty {
            if let match = named(room) { return .existing(match.id) }
            return .newPlace(name: room)
        }
        let goals = goals ?? []
        // Seeded rooms are named in the language they were made in; their
        // kanji is the same in every language.
        func seeded(_ english: String, kanji: String) -> PlaceRef? {
            named(english) ?? sorted.first { $0.kanji == kanji }
        }
        if goals.contains(.sleep), let bedroom = seeded("Bedroom", kanji: "寝室") { return .existing(bedroom.id) }
        if goals.contains(.focus), let study = seeded("Study", kanji: "書斎") { return .existing(study.id) }
        if let current, sorted.contains(where: { $0.id == current }) { return .existing(current) }
        return sorted.first.map { .existing($0.id) }
    }

    /// People asleep in the bedroom simulator. One constant, kept as a hook.
    static func sleepers(goals: Set<AirGoal>?) -> Int { 2 }
}

// MARK: - Demo offer

enum OnboardingDemoOffer {
    /// Whether the introduction offers "Try the demo". Not in the replay of
    /// someone already on Apple Home (a sensor found, or access granted with
    /// the demo off): one tap there would switch a working sensor to the demo.
    static func shown(replay: Bool, useDemo: Bool, homeKitRequested: Bool,
                      homeDenied: Bool, hasSensors: Bool) -> Bool {
        guard replay, !useDemo else { return true }
        let connected = hasSensors || (homeKitRequested && !homeDenied)
        return !connected
    }
}

// MARK: - Plan

enum OnboardingPlatform: Equatable {
    case iPhone, iPad, mac

    @MainActor static var current: OnboardingPlatform {
        #if targetEnvironment(macCatalyst)
        .mac
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        #endif
    }
}

/// What the plan screen describes: the settings the user is about to get.
struct PlanInput: Equatable {
    var placeName: String?
    var placeKanji = ""
    var goals: Set<AirGoal> = []
    var habit: AiringHabit?
    var limit: Double = 1000
    var soundOn = true
    var notifyOn = false
    var platform: OnboardingPlatform = .iPhone
    var demo = false
    var cloudAvailable = false
    var cloudOn = false
    var showInDock = false
}

/// One plan line; `key` is the part set in a heavier weight.
struct PlanLine: Equatable {
    var text: String
    var key: String?
}

extension PlanLine {
    /// A line whose key is marked in its (localized) text: "Start in **the
    /// Bedroom**." → text "Start in the Bedroom.", key "the Bedroom". The
    /// markers travel with the translation, so the key always matches.
    init(marked: String) {
        let parts = marked.components(separatedBy: "**")
        if parts.count >= 3 {
            self.init(text: parts.joined(), key: parts[1].isEmpty ? nil : parts[1])
        } else {
            self.init(text: marked, key: nil)
        }
    }
}

enum OnboardingPlan {
    static func lines(_ input: PlanInput) -> [PlanLine] {
        var out: [PlanLine] = []
        let limit = Metric.co2.format(input.limit)

        if let name = input.placeName {
            // The reminder's rule too: "the Bedroom", but "Mum's room".
            let marked = "**\(name)**"
            let place = Place.isSeeded(name)
                ? String(localized: "the \(marked)", comment: "A seeded room name used inside a sentence, e.g. 'the Bedroom'. Translate as just the placeholder if your language uses no article here.")
                : marked
            if input.demo {
                out.append(PlanLine(marked: String(localized: "The demo sensor starts in \(place). Connect a real one any time in Settings.",
                                                   comment: "Onboarding, Plan screen: the placeholder is a room name (may include an article, e.g. 'the Bedroom'). The demo is a simulated sensor.")))
            } else if input.placeKanji.isEmpty {
                out.append(PlanLine(marked: String(localized: "Start in \(place). Move the sensor any time from the Now screen.",
                                                   comment: "Onboarding, Plan screen: the placeholder is a room name (may include an article, e.g. 'the Bedroom'). Now = the app's main tab.")))
            } else {
                let kanji = input.placeKanji
                out.append(PlanLine(marked: String(localized: "Start in \(place) (\(kanji)). Move the sensor any time from the Now screen.",
                                                   comment: "Onboarding, Plan screen: the first placeholder is a room name (may include an article, e.g. 'the Bedroom'), the second its decorative kanji, e.g. 寝室 (do not translate). Now = the app's main tab.")))
            }
        }

        switch input.habit {
        case .rarely:
            out.append(PlanLine(marked: String(localized: "Air out a few times a day: **windows wide for a few minutes**, about 3–5 in winter, 10–20 in summer.", comment: "Onboarding, Plan screen: plan line for people who rarely air their rooms; the numbers are minutes. The text between ** and ** is set in a heavier weight; keep the two ** markers around the matching words.")))
        case .onceADay where input.goals.contains(.sleep):
            // BedroomModel: two sleepers take a fresh closed bedroom past
            // 1000 ppm in about 50 min (OnboardingTests pins it under 60).
            out.append(PlanLine(marked: String(localized: "Add **a second airing before bed**. With two people asleep, a closed bedroom can refill in under an hour.", comment: "Onboarding, Plan screen: plan line for people who air once a day and care about sleep; refill = with exhaled CO₂. The text between ** and ** is set in a heavier weight; keep the two ** markers around the matching words.")))
        case .onceADay:
            out.append(PlanLine(marked: String(localized: "Add **a second, short airing** in the afternoon.", comment: "Onboarding, Plan screen: plan line for people who air once a day. The text between ** and ** is set in a heavier weight; keep the two ** markers around the matching words.")))
        case .severalTimes:
            out.append(PlanLine(marked: String(localized: "**You already air often.** Kūki will show which room needs it most.", comment: "Onboarding, Plan screen: plan line for people who air several times a day. The text between ** and ** is set in a heavier weight; keep the two ** markers around the matching words.")))
        case .windowUsuallyOpen:
            out.append(PlanLine(marked: String(localized: "When it's cold, **a few wide-open minutes** beat a window tilted all day: fresher, and warmer.", comment: "Onboarding, Plan screen: plan line for people whose window is usually tilted open. The text between ** and ** is set in a heavier weight; keep the two ** markers around the matching words.")))
        case nil:
            break
        }

        var alert: String
        if !input.soundOn && !input.notifyOn {
            alert = String(localized: "No chime or notification. The ensō turns shu at **\(limit) ppm**.",
                           comment: "Onboarding, Plan screen: the placeholder is the CO₂ limit, e.g. 1000. Ensō = the Zen brush circle that shows CO₂, keep the word. Shu = the app's Japanese vermilion alert colour, keep the word. The text between ** and ** is set in a heavier weight; keep the two ** markers around the matching words.")
        } else if input.notifyOn {
            alert = String(localized: "The fūrin rings at **\(limit) ppm** and a notification follows.",
                           comment: "Onboarding, Plan screen: the placeholder is the CO₂ limit, e.g. 1000. Fūrin = the Japanese wind chime the app plays as its alert, keep the word. The text between ** and ** is set in a heavier weight; keep the two ** markers around the matching words.")
        } else {
            alert = String(localized: "The fūrin rings at **\(limit) ppm**.",
                           comment: "Onboarding, Plan screen: the placeholder is the CO₂ limit, e.g. 1000. Fūrin = the Japanese wind chime the app plays as its alert, keep the word. The text between ** and ** is set in a heavier weight; keep the two ** markers around the matching words.")
        }
        if input.limit == 800 && input.goals.contains(.sleep) {
            alert = String(localized: "\(alert) A gentle line for sleep.",
                           comment: "Onboarding, Plan screen: appended when the user chose the low 800 ppm limit for sleep; the placeholder is the previous sentence. Line = the CO₂ limit.")
        }
        out.append(PlanLine(marked: alert))

        switch input.platform {
        case .iPhone, .iPad:
            out.append(PlanLine(marked: String(localized: "Kūki records while it's open. For a full night, try **Station Mode** on a spare device.", comment: "Onboarding, Plan screen: plan line on iPhone and iPad. Station Mode = the app's always-on screen mode, use the same name as in Settings. The text between ** and ** is set in a heavier weight; keep the two ** markers around the matching words.")))
        case .mac where input.showInDock:
            out.append(PlanLine(marked: String(localized: "With a Dock icon, Kūki records **only while it's in front**. Settings › Show in Dock changes that.", comment: "Onboarding, Plan screen: plan line on Mac. Settings › Show in Dock is a path to a setting, use the same names as in Settings. The text between ** and ** is set in a heavier weight; keep the two ** markers around the matching words.")))
        case .mac:
            out.append(PlanLine(marked: String(localized: "This Mac records **around the clock** from the menu bar.", comment: "Onboarding, Plan screen: plan line on Mac. The text between ** and ** is set in a heavier weight; keep the two ** markers around the matching words.")))
        }

        if input.cloudAvailable && !input.cloudOn {
            out.append(PlanLine(marked: String(localized: "Using Kūki on more than one device? **iCloud Sync** in Settings shares one history.", comment: "Onboarding, Plan screen: plan line. iCloud Sync is the name of a setting, use the same name as in Settings. The text between ** and ** is set in a heavier weight; keep the two ** markers around the matching words.")))
        }
        return out
    }
}

// MARK: - Commit

/// The recorder settings the introduction writes. Recorder conforms.
@MainActor
protocol OnboardingSettingsSink: AnyObject {
    var co2Limit: Double { get set }
    var soundOn: Bool { get set }
    func setStartingPlace(_ id: UUID)
}

/// Where a new place is made — SwiftData in the app, a dictionary in tests.
@MainActor
protocol PlaceStore: AnyObject {
    func id(named name: String) -> UUID?
    func insert(name: String) -> UUID
}

enum OnboardingCommit {
    /// Writes the confirmed answers — and nothing for an unanswered one — then
    /// marks the introduction done. Runs on Begin and on Skip. Idempotent.
    @MainActor
    static func apply(_ answers: OnboardingAnswers, to sink: OnboardingSettingsSink,
                      defaults: UserDefaults, places: PlaceStore) {
        if let goals = answers.goals {
            defaults.set(goals.map(\.rawValue).sorted().joined(separator: ","), forKey: OnboardingKeys.airGoals)
        }
        if let habit = answers.habit {
            defaults.set(habit.rawValue, forKey: OnboardingKeys.airingHabit)
        }
        switch answers.place {
        case .existing(let id):
            sink.setStartingPlace(id)
        case .newPlace(let name):
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                sink.setStartingPlace(places.id(named: clean) ?? places.insert(name: clean))
            }
        case nil:
            break
        }
        if let limit = answers.limit, sink.co2Limit != limit.ppm { sink.co2Limit = limit.ppm }
        if let sound = answers.soundOn, sink.soundOn != sound { sink.soundOn = sound }
        complete(defaults: defaults)
    }

    static func complete(defaults: UserDefaults) {
        defaults.set(true, forKey: OnboardingKeys.hasCompleted)
        defaults.set(OnboardingKeys.currentVersion, forKey: OnboardingKeys.version)
        defaults.removeObject(forKey: OnboardingKeys.resumeStep)
    }

    /// "focus,sleep" → [.focus, .sleep]; unknown names dropped.
    static func goals(from raw: String?) -> Set<AirGoal>? {
        guard let raw else { return nil }
        return Set(raw.split(separator: ",").compactMap { AirGoal(rawValue: String($0)) })
    }
}

// MARK: - Personal lines

enum OnboardingCopy {
    /// "Your iPhone will ask first." / "your iPad" / "your Mac".
    static func device(_ platform: OnboardingPlatform) -> String {
        switch platform {
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .mac: "Mac"
        }
    }

    /// The rebreathed share at `ppm`, after Rudnick & Milton 2003:
    /// (C − outdoor) ÷ the CO₂ that breathing adds (38,000 ppm).
    static func rebreathedFraction(ppm: Double) -> Double {
        max(0, (ppm - BedroomModel.outdoor) / 38_000)
    }

    /// The note under the dial, by band.
    static func bandNote(ppm: Double) -> String {
        switch ppm {
        case ..<800: String(localized: "Close to outdoor air.", comment: "Onboarding, Breath screen: note under the CO₂ dial, under 800 ppm")
        case ..<1000: String(localized: "Comfortable. Kūki starts suggesting a window.", comment: "Onboarding, Breath screen: note under the CO₂ dial, 800–1000 ppm")
        case ..<1400: String(localized: "Above the line Germany's Umweltbundesamt calls harmless.", comment: "Onboarding, Breath screen: note under the CO₂ dial, 1000–1400 ppm. Umweltbundesamt = German Environment Agency, keep the name")
        case ..<2000: String(localized: "Well past the line. Open a window wide.", comment: "Onboarding, Breath screen: note under the CO₂ dial, 1400–2000 ppm")
        default: String(localized: "The Umweltbundesamt calls this unacceptable.", comment: "Onboarding, Breath screen: note under the CO₂ dial, over 2000 ppm. Umweltbundesamt = German Environment Agency, keep the name")
        }
    }

    /// The reply to the bedroom guess.
    static func guessReply(_ guess: BedroomGuess?, morning: Double) -> String {
        let value = Metric.co2.format((morning / 10).rounded() * 10)
        switch guess {
        case .p2000:
            return String(localized: "Close: about \(value) ppm.",
                          comment: "Onboarding, Night screen: reply to the user's guess of bedroom CO₂ by morning (they guessed 2000); the placeholder is the modelled value")
        case .p4000:
            return String(localized: "Lower than that: about \(value) ppm. Air leaks in even with the window shut.",
                          comment: "Onboarding, Night screen: reply to the user's guess of bedroom CO₂ by morning (they guessed 4000); the placeholder is the modelled value")
        case .p600, .p1000:
            return String(localized: "Most people guess lower: about \(value) ppm.",
                          comment: "Onboarding, Night screen: reply to the user's low guess of bedroom CO₂ by morning; the placeholder is the modelled value")
        case nil:
            return String(localized: "About \(value) ppm by morning.",
                          comment: "Onboarding, Night screen: modelled bedroom CO₂ by morning when no guess was made; the placeholder is a number")
        }
    }

    /// "Past 1000 ppm after about 50 min." — rounded to 5 minutes.
    static func closedReadout(sleepers: Int) -> String {
        guard let minutes = BedroomModel.minutesToReach(1000, sleepers: sleepers), minutes <= 8 * 60 else {
            return String(localized: "Stays under 1000 ppm all night.",
                          comment: "Onboarding, Night screen: readout for a closed bedroom that never reaches 1000 ppm")
        }
        let rounded = max(5, Int((minutes / 5).rounded()) * 5)
        let duration = Duration.seconds(rounded * 60).formatted(.units(allowed: [.minutes], width: .abbreviated))
        return String(localized: "Past 1000 ppm after about \(duration).",
                      comment: "Onboarding, Night screen: readout for a closed bedroom; the placeholder is a short duration such as 50 min")
    }

    /// "{room} · {home}", dropping empty parts.
    static func roomAndHome(room: String, home: String) -> String {
        [room, home].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
