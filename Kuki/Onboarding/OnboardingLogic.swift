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
        if goals.contains(.sleep), let bedroom = named("Bedroom") { return .existing(bedroom.id) }
        if goals.contains(.focus), let study = named("Study") { return .existing(study.id) }
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

enum OnboardingPlan {
    static func lines(_ input: PlanInput) -> [PlanLine] {
        var out: [PlanLine] = []
        let limit = Metric.co2.format(input.limit)

        if let name = input.placeName {
            // The reminder's rule too: "the Bedroom", but "Mum's room".
            let place = Place.isSeeded(name) ? "the \(name)" : name
            if input.demo {
                out.append(PlanLine(text: "The demo sensor starts in \(place). Connect a real one any time in Settings.",
                                    key: name))
            } else {
                let kanji = input.placeKanji.isEmpty ? "" : " (\(input.placeKanji))"
                out.append(PlanLine(text: "Start in \(place)\(kanji). Move the sensor any time from the Now screen.",
                                    key: name))
            }
        }

        switch input.habit {
        case .rarely:
            out.append(PlanLine(text: "Air out a few times a day: windows wide for a few minutes, about 3–5 in winter, 10–20 in summer.",
                                key: "windows wide for a few minutes"))
        case .onceADay where input.goals.contains(.sleep):
            // BedroomModel: two sleepers take a fresh closed bedroom past
            // 1000 ppm in about 50 min (OnboardingTests pins it under 60).
            out.append(PlanLine(text: "Add a second airing before bed. With two people asleep, a closed bedroom can refill in under an hour.",
                                key: "a second airing before bed"))
        case .onceADay:
            out.append(PlanLine(text: "Add a second, short airing in the afternoon.", key: "a second, short airing"))
        case .severalTimes:
            out.append(PlanLine(text: "You already air often. Kūki will show which room needs it most.",
                                key: "You already air often."))
        case .windowUsuallyOpen:
            out.append(PlanLine(text: "When it's cold, a few wide-open minutes beat a window tilted all day: fresher, and warmer.",
                                key: "a few wide-open minutes"))
        case nil:
            break
        }

        var alert: String
        if !input.soundOn && !input.notifyOn {
            alert = "No chime or notification. The ensō turns shu at \(limit) ppm."
        } else {
            alert = "The fūrin rings at \(limit) ppm" + (input.notifyOn ? " and a notification follows." : ".")
        }
        if input.limit == 800 && input.goals.contains(.sleep) { alert += " A gentle line for sleep." }
        out.append(PlanLine(text: alert, key: "\(limit) ppm"))

        switch input.platform {
        case .iPhone, .iPad:
            out.append(PlanLine(text: "Kūki records while it's open. For a full night, try Station Mode on a spare device.",
                                key: "Station Mode"))
        case .mac where input.showInDock:
            out.append(PlanLine(text: "With a Dock icon, Kūki records only while it's in front. Settings › Show in Dock changes that.",
                                key: "only while it's in front"))
        case .mac:
            out.append(PlanLine(text: "This Mac records around the clock from the menu bar.", key: "around the clock"))
        }

        if input.cloudAvailable && !input.cloudOn {
            out.append(PlanLine(text: "Using Kūki on more than one device? iCloud Sync in Settings shares one history.",
                                key: "iCloud Sync"))
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
        case ..<800: "Close to outdoor air."
        case ..<1000: "Comfortable. Kūki starts suggesting a window."
        case ..<1400: "Above the line Germany's Umweltbundesamt calls harmless."
        case ..<2000: "Well past the line. Open a window wide."
        default: "The Umweltbundesamt calls this unacceptable."
        }
    }

    /// The reply to the bedroom guess.
    static func guessReply(_ guess: BedroomGuess?, morning: Double) -> String {
        let value = Metric.co2.format((morning / 10).rounded() * 10)
        switch guess {
        case .p2000: return "Close: about \(value) ppm."
        case .p4000: return "Lower than that: about \(value) ppm. Air leaks in even with the window shut."
        case .p600, .p1000: return "Most people guess lower: about \(value) ppm."
        case nil: return "About \(value) ppm by morning."
        }
    }

    /// "Past 1000 ppm after about 50 min." — rounded to 5 minutes.
    static func closedReadout(sleepers: Int) -> String {
        guard let minutes = BedroomModel.minutesToReach(1000, sleepers: sleepers), minutes <= 8 * 60 else {
            return "Stays under 1000 ppm all night."
        }
        let rounded = max(5, Int((minutes / 5).rounded()) * 5)
        return "Past 1000 ppm after about \(rounded) min."
    }

    /// "{room} · {home}", dropping empty parts.
    static func roomAndHome(room: String, home: String) -> String {
        [room, home].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
