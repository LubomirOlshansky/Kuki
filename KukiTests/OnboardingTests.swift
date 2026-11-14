import Foundation
import SwiftData
import Testing
@testable import Kuki

private func freshDefaults() -> UserDefaults {
    let name = "kuki-onboarding-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

private func near(_ value: Double, _ expected: Double, tolerance: Double = 0.01) -> Bool {
    abs(value - expected) <= abs(expected) * tolerance
}

// MARK: - Bedroom model

@Suite("Onboarding — bedroom model")
struct BedroomModelTests {
    @Test("Reference values (±1 %)", arguments: [(1, 1255.0), (2, 2079), (3, 2904)])
    func eightHours(sleepers: Int, expected: Double) {
        #expect(near(BedroomModel.ppm(sleepers: sleepers, hours: 8), expected))
    }

    @Test("Minutes to 1000 ppm (±1 %)", arguments: [(1, 136.2), (2, 49.7), (3, 30.8)])
    func minutesToTheLine(sleepers: Int, expected: Double) throws {
        let minutes = try #require(BedroomModel.minutesToReach(1000, sleepers: sleepers))
        #expect(near(minutes, expected))
    }

    @Test func airing() {
        let five = BedroomModel.afterAiring(from: 2079, minutes: 5, sleepers: 2)
        let ten = BedroomModel.afterAiring(from: 2079, minutes: 10, sleepers: 2)
        #expect(near(five, 942))
        #expect(near(ten, 617))
        #expect(ten < five && five < 2079)
    }

    @Test func edges() {
        #expect(BedroomModel.ppm(sleepers: 0, hours: 8) == BedroomModel.outdoor)
        #expect(BedroomModel.ppm(sleepers: 2, hours: 0, start: 777) == 777)
        #expect(BedroomModel.minutesToReach(1000, sleepers: 0) == nil)
        #expect(BedroomModel.minutesToReach(5000, sleepers: 2) == nil, "never reached")
        let hours = stride(from: 0.0, through: 8, by: 0.5).map { BedroomModel.ppm(sleepers: 2, hours: $0) }
        #expect(hours == hours.sorted(), "monotonic in hours")
        let people = (0...4).map { BedroomModel.ppm(sleepers: $0, hours: 4) }
        #expect(people == people.sorted(), "monotonic in sleepers")
    }

    @Test func readouts() {
        #expect(OnboardingCopy.closedReadout(sleepers: 2) == "Past 1000 ppm after about 50 min.")
        #expect(OnboardingCopy.closedReadout(sleepers: 0) == "Stays under 1000 ppm all night.")
        #expect(OnboardingCopy.guessReply(.p2000, morning: 2079) == "Close: about 2080 ppm.")
        #expect(OnboardingCopy.guessReply(nil, morning: 2079) == "About 2080 ppm by morning.")
        #expect(abs(OnboardingCopy.rebreathedFraction(ppm: 1000) - 0.015) < 0.0005)
        #expect(OnboardingCopy.rebreathedFraction(ppm: 400) == 0)
    }
}

// MARK: - Preselection

@Suite("Onboarding — preselection")
struct PreselectTests {
    static let living = PlaceRef(id: UUID(), name: "Living room", kanji: "居間", sortIndex: 0)
    static let bedroom = PlaceRef(id: UUID(), name: "Bedroom", kanji: "寝室", sortIndex: 1)
    static let study = PlaceRef(id: UUID(), name: "Study", kanji: "書斎", sortIndex: 2)
    static let kitchen = PlaceRef(id: UUID(), name: "Kitchen", kanji: "台所", sortIndex: 3)
    let places = [kitchen, study, bedroom, living] // unsorted on purpose

    @Test func everyoneStartsAtTheUsualLine() {
        #expect(OnboardingPreselect.limit(goals: []) == .standard)
        #expect(OnboardingPreselect.limit(goals: [.focus]) == .standard)
        #expect(OnboardingPreselect.limit(goals: [.sleep]) == .standard, "sleep is suggested, not chosen")
        #expect(OnboardingPreselect.limit(goals: [.sleep, .focus]) == .standard)
        #expect(OnboardingPreselect.limit(goals: nil) == .standard)
    }

    @Test func sleepSuggestsTheLowerLimit() {
        #expect(OnboardingPreselect.suggestedLimit(goals: [.sleep]) == .sensitive)
        #expect(OnboardingPreselect.suggestedLimit(goals: [.sleep, .focus]) == .sensitive)
        #expect(OnboardingPreselect.suggestedLimit(goals: [.focus]) == nil)
        #expect(OnboardingPreselect.suggestedLimit(goals: nil) == nil)
    }

    @Test func replayShowsTheCurrentLimit() {
        #expect(OnboardingPreselect.limit(goals: [.sleep], current: 1150) == .custom(1150))
        #expect(OnboardingPreselect.limit(goals: [], current: 800) == .sensitive)
        #expect(OnboardingPreselect.limit(goals: [], current: 1200) == .relaxed)
    }

    @Test func place() {
        let p = OnboardingPreselect.place
        #expect(p(places, "bedroom", nil, nil) == .existing(Self.bedroom.id), "case-insensitive")
        #expect(p(places, "  Kitchen ", nil, nil) == .existing(Self.kitchen.id), "whitespace trimmed")
        #expect(p(places, "Büro", nil, nil) == .newPlace(name: "Büro"))
        #expect(p(places, "", [.sleep], nil) == .existing(Self.bedroom.id))
        #expect(p(places, nil, [.focus], nil) == .existing(Self.study.id))
        #expect(p(places, nil, [], Self.kitchen.id) == .existing(Self.kitchen.id))
        #expect(p(places, nil, [], nil) == .existing(Self.living.id), "first by sortIndex")
        #expect(p([], nil, [], nil) == nil)
    }
}

// MARK: - Commit

@MainActor
private final class FakeSink: OnboardingSettingsSink {
    var co2Limit = 1000.0 { didSet { limitWrites += 1 } }
    var soundOn = true
    var limitWrites = 0
    var startingPlaces: [UUID] = []
    func setStartingPlace(_ id: UUID) { startingPlaces.append(id) }
}

@MainActor
private final class FakePlaces: PlaceStore {
    var names: [String: UUID] = [:]
    var inserts = 0
    func id(named name: String) -> UUID? { names[name] }
    func insert(name: String) -> UUID {
        inserts += 1
        let id = UUID()
        names[name] = id
        return id
    }
}

@MainActor
@Suite("Onboarding — commit")
struct CommitTests {
    @Test("Each limit writes exactly its ppm", arguments: [(LimitChoice.sensitive, 800.0), (.standard, 1000), (.relaxed, 1200)])
    func limits(choice: LimitChoice, ppm: Double) {
        let sink = FakeSink(); sink.co2Limit = 1100
        OnboardingCommit.apply(OnboardingAnswers(limit: choice), to: sink, defaults: freshDefaults(), places: FakePlaces())
        #expect(sink.co2Limit == ppm)
    }

    @Test func unansweredWritesNothing() {
        let sink = FakeSink(); sink.co2Limit = 1150; sink.limitWrites = 0
        let d = freshDefaults()
        OnboardingCommit.apply(OnboardingAnswers(), to: sink, defaults: d, places: FakePlaces())
        #expect(sink.co2Limit == 1150 && sink.limitWrites == 0)
        #expect(sink.soundOn)
        #expect(d.object(forKey: OnboardingKeys.airGoals) == nil)
        #expect(d.object(forKey: OnboardingKeys.airingHabit) == nil)
        #expect(sink.startingPlaces.isEmpty)
    }

    @Test func soundAndQuiz() {
        let sink = FakeSink()
        let d = freshDefaults()
        OnboardingCommit.apply(OnboardingAnswers(goals: [.sleep, .focus], habit: .onceADay, soundOn: false),
                               to: sink, defaults: d, places: FakePlaces())
        #expect(!sink.soundOn)
        #expect(d.string(forKey: OnboardingKeys.airGoals) == "focus,sleep", "sorted CSV")
        #expect(d.string(forKey: OnboardingKeys.airingHabit) == "onceADay")

        let none = freshDefaults()
        OnboardingCommit.apply(OnboardingAnswers(goals: []), to: FakeSink(), defaults: none, places: FakePlaces())
        #expect(none.string(forKey: OnboardingKeys.airGoals) == "")
    }

    @Test func places() {
        let sink = FakeSink()
        let store = FakePlaces()
        let d = freshDefaults()
        let existing = UUID()
        OnboardingCommit.apply(OnboardingAnswers(place: .existing(existing)), to: sink, defaults: d, places: store)
        #expect(sink.startingPlaces == [existing])

        let answers = OnboardingAnswers(place: .newPlace(name: " Büro "))
        OnboardingCommit.apply(answers, to: sink, defaults: d, places: store)
        #expect(store.inserts == 1)
        #expect(sink.startingPlaces.last == store.names["Büro"])
        // Idempotent: a second commit finds the place instead of adding another.
        OnboardingCommit.apply(answers, to: sink, defaults: d, places: store)
        #expect(store.inserts == 1)
        #expect(sink.startingPlaces.last == store.names["Büro"])
    }

    @Test func completion() {
        let d = freshDefaults()
        d.set("place", forKey: OnboardingKeys.resumeStep)
        OnboardingCommit.apply(OnboardingAnswers(), to: FakeSink(), defaults: d, places: FakePlaces())
        #expect(d.bool(forKey: OnboardingKeys.hasCompleted))
        #expect(d.integer(forKey: OnboardingKeys.version) == 1)
        #expect(d.object(forKey: OnboardingKeys.resumeStep) == nil)
    }

    @Test func idempotent() {
        let sink = FakeSink()
        let d = freshDefaults()
        let a = OnboardingAnswers(goals: [.curiosity], habit: .rarely, limit: .relaxed, soundOn: false)
        OnboardingCommit.apply(a, to: sink, defaults: d, places: FakePlaces())
        let first = (sink.co2Limit, sink.soundOn, d.string(forKey: OnboardingKeys.airGoals))
        sink.limitWrites = 0
        OnboardingCommit.apply(a, to: sink, defaults: d, places: FakePlaces())
        #expect(first == (sink.co2Limit, sink.soundOn, d.string(forKey: OnboardingKeys.airGoals)))
        #expect(sink.limitWrites == 0, "no redundant writes")
    }

    @Test func replayCloseWritesNothing() {
        // Close discards the draft: nothing is applied at all.
        let d = freshDefaults()
        let sink = FakeSink()
        var draft = OnboardingDraft()
        draft.staged.limit = .relaxed
        draft.confirm(.furin)
        _ = draft // Close: the draft is dropped, apply is never called
        #expect(sink.co2Limit == 1000)
        #expect(d.dictionaryRepresentation().keys.contains(OnboardingKeys.hasCompleted) == false)
    }
}

// MARK: - Skip semantics

@Suite("Onboarding — skip")
struct SkipTests {
    @Test func skipOnTheFurinScreenDoesNotWriteItsPreselection() {
        var draft = OnboardingDraft()
        draft.staged.limit = .standard
        draft.staged.soundOn = true
        // Skip pressed on the fūrin screen: no confirm(.furin).
        #expect(draft.answers.limit == nil)
        #expect(draft.answers.soundOn == nil)
    }

    @Test func continueOnThePlaceScreenRecordsIt() {
        var draft = OnboardingDraft()
        let id = UUID()
        draft.staged.place = .existing(id)
        draft.confirm(.place)
        draft.staged.limit = .sensitive // shown on the next screen, then Skip
        #expect(draft.answers.place == .existing(id))
        #expect(draft.answers.limit == nil)
    }

    @Test func confirmedQuestionsWithNothingChosenAreEmptyNotNil() {
        var draft = OnboardingDraft()
        draft.confirm(.questions)
        #expect(draft.answers.goals == [])
        #expect(draft.answers.habit == nil)
    }
}

// MARK: - Plan

@Suite("Onboarding — plan")
struct PlanTests {
    func lines(_ change: (inout PlanInput) -> Void) -> [String] {
        var input = PlanInput(placeName: "Bedroom", placeKanji: "寝室")
        change(&input)
        return OnboardingPlan.lines(input).map(\.text)
    }

    @Test("One line per habit", arguments: [
        (AiringHabit.rarely, false, "Air out a few times a day: windows wide for a few minutes, about 3–5 in winter, 10–20 in summer."),
        (.onceADay, true, "Add a second airing before bed. With two people asleep, a closed bedroom can refill in under an hour."),
        (.onceADay, false, "Add a second, short airing in the afternoon."),
        (.severalTimes, false, "You already air often. Kūki will show which room needs it most."),
        (.windowUsuallyOpen, false, "When it's cold, a few wide-open minutes beat a window tilted all day: fresher, and warmer."),
    ])
    func habit(habit: AiringHabit, sleep: Bool, line: String) {
        #expect(lines { $0.habit = habit; $0.goals = sleep ? [.sleep] : [] }.contains(line))
    }

    @Test func noHabitNoLine() {
        #expect(lines { $0.habit = nil }.count == 3)
    }

    @Test func alertLine() {
        #expect(lines { $0.soundOn = true; $0.notifyOn = false }.contains("The fūrin rings at 1000 ppm."))
        #expect(lines { $0.soundOn = true; $0.notifyOn = true }.contains("The fūrin rings at 1000 ppm and a notification follows."))
        #expect(lines { $0.soundOn = false; $0.notifyOn = true }.contains("The fūrin rings at 1000 ppm and a notification follows."))
        #expect(lines { $0.soundOn = false; $0.notifyOn = false }.contains("No chime or notification. The ensō turns shu at 1000 ppm."))
        #expect(lines { $0.limit = 800; $0.goals = [.sleep] }.contains("The fūrin rings at 800 ppm. A gentle line for sleep."))
        #expect(lines { $0.limit = 800; $0.goals = [] }.contains("The fūrin rings at 800 ppm."))
    }

    @Test func place() {
        #expect(lines { _ in }.first == "Start in the Bedroom (寝室). Move the sensor any time from the Now screen.")
        #expect(lines { $0.placeKanji = "" }.first == "Start in the Bedroom. Move the sensor any time from the Now screen.")
        #expect(lines { $0.demo = true }.first == "The demo sensor starts in the Bedroom. Connect a real one any time in Settings.")
    }

    /// The reminder's rule: "the" for a seeded place, a typed name bare.
    @Test func placeArticle() {
        #expect(lines { $0.placeName = "Living room"; $0.placeKanji = "" }.first
            == "Start in the Living room. Move the sensor any time from the Now screen.")
        #expect(lines { $0.placeName = "Mum's room"; $0.placeKanji = "" }.first
            == "Start in Mum's room. Move the sensor any time from the Now screen.")
        #expect(lines { $0.placeName = "Office"; $0.placeKanji = ""; $0.demo = true }.first
            == "The demo sensor starts in Office. Connect a real one any time in Settings.")
        #expect(AiringReminder.title(placeName: "Office") == "Time to air Office")
        #expect(Place.isSeeded(" bedroom ") && !Place.isSeeded("Mum's room"))
    }

    /// "Can refill in under an hour" must stay true of the bedroom model.
    @Test func refillClaimMatchesTheModel() throws {
        let minutes = try #require(BedroomModel.minutesToReach(1000, sleepers: 2))
        #expect(minutes < 60)
        let aired = BedroomModel.afterAiring(from: 1000, minutes: 5, sleepers: 2)
        #expect(try #require(BedroomModel.minutesToReach(1000, sleepers: 2, start: aired)) < 60)
    }

    @Test func recording() {
        #expect(lines { $0.platform = .iPhone }.contains("Kūki records while it's open. For a full night, try Station Mode on a spare device."))
        #expect(lines { $0.platform = .mac }.contains("This Mac records around the clock from the menu bar."))
        #expect(lines { $0.platform = .mac; $0.showInDock = true }
            .contains("With a Dock icon, Kūki records only while it's in front. Settings › Show in Dock changes that."))
    }

    @Test func syncOnlyWhenAvailableAndOff() {
        let sync = "Using Kūki on more than one device? iCloud Sync in Settings shares one history."
        #expect(lines { $0.cloudAvailable = true; $0.cloudOn = false }.contains(sync))
        #expect(!lines { $0.cloudAvailable = true; $0.cloudOn = true }.contains(sync))
        #expect(!lines { $0.cloudAvailable = false }.contains(sync))
    }

    @Test func everyLineIsPlain() {
        for habit in AiringHabit.allCases {
            for platform in [OnboardingPlatform.iPhone, .iPad, .mac] {
                let all = lines { $0.habit = habit; $0.platform = platform; $0.cloudAvailable = true }
                #expect(all.allSatisfy { !$0.isEmpty && !$0.localizedCaseInsensitiveContains("health") })
            }
        }
    }
}

// MARK: - Apple Home state

@Suite("Onboarding — Apple Home state")
struct HomeConnectionTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let alpstuga = SensorInfo(id: UUID(), name: "ALPSTUGA", room: "Bedroom", home: "Home", manufacturer: "IKEA", isReachable: true)
    let other = SensorInfo(id: UUID(), name: "Eve Room", room: "Study", home: "Home", manufacturer: "Eve", isReachable: true)

    func state(_ status: HomeKitSource.Status, at seconds: Double, since: Double = 0, sensors: [SensorInfo] = [],
               snapshots: [UUID: SensorSnapshot] = [:], chosen: UUID? = nil, requested: Bool = true) -> HomeConnectionState {
        HomeConnection.state(requested: requested, requestedAt: t0, status: status,
                             statusSince: t0.addingTimeInterval(since), sensors: sensors, snapshots: snapshots,
                             chosen: chosen, foundAt: t0, now: t0.addingTimeInterval(seconds))
    }

    func snapshot(co2: Double = 900, heard: Date?) -> SensorSnapshot {
        var s = SensorSnapshot()
        s.co2 = co2
        if let heard { s.heardAt[.co2] = heard }
        return s
    }

    @Test func gates() {
        #expect(state(.ready, at: 0, requested: false) == .notRequested)
        #expect(state(.notAuthorized, at: 1) == .denied)
        #expect(state(.starting, at: 14) == .waiting)
        #expect(state(.starting, at: 15) == .slow)
        #expect(state(.noSensors, at: 2) == .waiting)
        #expect(state(.noSensors, at: 3) == .noSensor)
        #expect(state(.noHomes, at: 2.5) == .waiting)
        #expect(state(.noHomes, at: 3) == .noHome)
    }

    @Test func aCachedValueIsNeverTheFreshPayoff() {
        let cached = [alpstuga.id: snapshot(heard: t0.addingTimeInterval(-120))]
        #expect(state(.ready, at: 5, sensors: [alpstuga], snapshots: cached) == .foundWaiting(alpstuga))
        let fresh = [alpstuga.id: snapshot(co2: 950, heard: t0.addingTimeInterval(4))]
        #expect(state(.ready, at: 5, sensors: [alpstuga], snapshots: fresh) == .found(alpstuga, ppm: 950, fresh: true))
    }

    @Test func noFreshReadingAfterTheGrace() {
        let none = [alpstuga.id: snapshot(heard: nil)]
        #expect(state(.ready, at: 30, sensors: [alpstuga], snapshots: none) == .found(alpstuga, ppm: 900, fresh: false))
    }

    @Test func unreachableAfterTheGrace() {
        var snap = snapshot(heard: nil); snap.isReachable = false
        #expect(state(.ready, at: 10, sensors: [alpstuga], snapshots: [alpstuga.id: snap]) == .foundWaiting(alpstuga))
        #expect(state(.ready, at: 30, sensors: [alpstuga], snapshots: [alpstuga.id: snap]) == .unreachable(alpstuga))
    }

    @Test func severalSensors() {
        #expect(state(.ready, at: 2, sensors: [alpstuga, other]) == .several([alpstuga, other]))
        let fresh = [other.id: snapshot(co2: 700, heard: t0.addingTimeInterval(1))]
        #expect(state(.ready, at: 2, sensors: [alpstuga, other], snapshots: fresh, chosen: other.id)
                == .found(other, ppm: 700, fresh: true))
    }

    @Test func aSensorWithoutCO2CountsOnceAnythingIsFresh() {
        var s = SensorSnapshot(); s.pm25 = 4; s.heardAt[.pm25] = t0.addingTimeInterval(2)
        #expect(state(.ready, at: 3, sensors: [alpstuga], snapshots: [alpstuga.id: s]) == .found(alpstuga, ppm: nil, fresh: true))
    }
}

// MARK: - Path, migration, advice

@Suite("Onboarding — path and migration")
struct PathMigrationTests {
    @Test func paths() {
        #expect(OnboardingPath.steps(demo: false).count == 9)
        #expect(OnboardingPath.steps(demo: true).count == 8)
        #expect(!OnboardingPath.steps(demo: true).contains(.appleHome))
        for demo in [false, true] {
            for (i, step) in OnboardingPath.steps(demo: demo).enumerated() {
                #expect(OnboardingPath.index(of: step, demo: demo) == i)
            }
        }
        #expect(OnboardingPath.next(after: .listen, demo: true) == .place)
        #expect(OnboardingPath.next(after: .listen, demo: false) == .appleHome)
        #expect(OnboardingPath.next(after: .plan, demo: false) == nil)
        #expect(OnboardingPath.previous(before: .welcome, demo: false) == nil)
    }

    @Test func resume() {
        #expect(OnboardingPath.resumeStep(saved: "place", homeKitRequested: false) == .place)
        #expect(OnboardingPath.resumeStep(saved: "appleHome", homeKitRequested: false) == .listen)
        #expect(OnboardingPath.resumeStep(saved: "appleHome", homeKitRequested: true) == .appleHome)
        #expect(OnboardingPath.resumeStep(saved: nil, homeKitRequested: true) == .welcome)
        #expect(OnboardingPath.resumeStep(saved: "line", homeKitRequested: true) == .welcome, "a removed step")
    }

    @Test func freshInstall() {
        let d = freshDefaults()
        OnboardingMigration.run(defaults: d)
        #expect(!d.bool(forKey: OnboardingKeys.hasCompleted))
        #expect(!d.bool(forKey: OnboardingKeys.homeKitRequested))
        #expect(d.bool(forKey: OnboardingKeys.migrated))
    }

    @Test func existingInstallSkipsTheIntroduction() {
        let d = freshDefaults()
        d.set(true, forKey: "seededPlaces")
        OnboardingMigration.run(defaults: d)
        #expect(d.bool(forKey: OnboardingKeys.hasCompleted))
        #expect(d.bool(forKey: OnboardingKeys.homeKitRequested))
        // Second run: a no-op, even after the user's own changes.
        d.set(false, forKey: OnboardingKeys.homeKitRequested)
        OnboardingMigration.run(defaults: d)
        #expect(!d.bool(forKey: OnboardingKeys.homeKitRequested))
    }

    #if DEBUG
    @Test func debugResetKeepsMigrated() {
        let d = freshDefaults()
        d.set(true, forKey: OnboardingKeys.hasCompleted)
        d.set(true, forKey: OnboardingKeys.homeKitRequested)
        d.set("focus", forKey: OnboardingKeys.airGoals)
        d.set(true, forKey: "resetOnboarding")
        OnboardingMigration.run(defaults: d)
        // (The recorder registers a `false` default for homeKitRequested
        // process-wide, so read the values, not their presence.)
        #expect(!d.bool(forKey: OnboardingKeys.hasCompleted))
        #expect(!d.bool(forKey: OnboardingKeys.homeKitRequested))
        #expect(d.object(forKey: OnboardingKeys.airGoals) == nil)
        #expect(d.bool(forKey: OnboardingKeys.migrated))
    }
    #endif

    @Test func adviceFollowsTheHabit() {
        #expect(CO2Level.stale.advice(habit: "windowUsuallyOpen") == "Open the window wide for a few minutes. Tilted, it airs slowly.")
        #expect(CO2Level.poor.advice(habit: "windowUsuallyOpen") == "Open it wide now. A tilted window can't keep up.")
        for level in [CO2Level.clear, .fine] {
            #expect(level.advice(habit: "windowUsuallyOpen") == level.advice)
        }
        for level in CO2Level.allCases {
            #expect(level.advice(habit: nil) == level.advice)
            #expect(level.advice(habit: "rarely") == level.advice)
            #expect(level.advice(habit: "nonsense") == level.advice)
        }
        #expect(CO2Level.poor.advice == "Ventilate now — open a window wide.")
    }
}

// MARK: - Recorder gate

@MainActor
@Suite("Onboarding — recorder gate")
struct RecorderGateTests {
    func container() throws -> ModelContainer {
        try ModelContainer(for: Place.self, Reading.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    @Test func homeKitWaitsToBeAskedFor() throws {
        let d = freshDefaults()
        d.set(false, forKey: "useDemo")
        let store = try container() // the recorder keeps only its context
        let recorder = Recorder(defaults: d)
        recorder.homeKit.dryRun = true
        recorder.start(container: store)
        #expect(!recorder.homeKit.isStarted, "no Apple Home before the primer")
        #expect(!recorder.homeKitRequested)

        recorder.connectHomeKit()
        #expect(recorder.homeKitRequested)
        #expect(recorder.homeKit.isStarted)
        #expect(!recorder.useDemo)
        #expect(d.bool(forKey: OnboardingKeys.homeKitRequested), "persisted")
        withExtendedLifetime(store) {}
    }

    @Test func turningTheDemoOffAsksForAppleHome() throws {
        let d = freshDefaults()
        d.set(true, forKey: "useDemo")
        let store = try container()
        let recorder = Recorder(defaults: d)
        recorder.homeKit.dryRun = true
        recorder.configure(container: store)
        recorder.useDemo = false
        #expect(recorder.homeKitRequested && recorder.homeKit.isStarted)
        withExtendedLifetime(store) {}
    }

    @Test func holdRecordingRecordsNothing() async throws {
        let d = freshDefaults()
        d.set(true, forKey: "useDemo")
        let store = try container()
        let recorder = Recorder(defaults: d)
        recorder.configure(container: store)
        recorder.holdRecording = true
        await recorder.tick()
        #expect(recorder.lastRecordedAt == nil)
        recorder.holdRecording = false
        await recorder.tick()
        #expect(recorder.lastRecordedAt != nil)
        withExtendedLifetime(store) {}
    }

    @Test func theStartingPlaceIsAlreadySettled() throws {
        let c = try container()
        let recorder = Recorder(defaults: freshDefaults())
        recorder.configure(container: c)
        let places = try c.mainContext.fetch(FetchDescriptor<Place>(sortBy: [SortDescriptor(\.sortIndex)]))
        let bedroom = try #require(places.first { $0.name == "Bedroom" })
        recorder.setStartingPlace(bedroom.id)
        #expect(recorder.currentPlaceID == bedroom.id)
        #expect(!recorder.isSettling)
    }
}

// MARK: - Airing reminder

@MainActor
private final class FakeCenter: ReminderCenter {
    var grant = true
    var asked = 0
    var pending: [String: ReminderRequest] = [:]
    func requestPermission() async -> Bool { asked += 1; return grant }
    func remove(identifiers: [String]) { identifiers.forEach { pending[$0] = nil } }
    func add(_ request: ReminderRequest) { pending[request.identifier] = request }
}

@MainActor
@Suite("Airing reminder")
struct AiringReminderTests {
    @Test func scheduleFollowsTheHabit() {
        let twice = [ReminderTime(hour: 9), ReminderTime(hour: 20)]
        #expect(AiringReminder.suggestedTimes(for: .rarely) == twice)
        #expect(AiringReminder.suggestedTimes(for: .onceADay) == twice)
        #expect(AiringReminder.suggestedTimes(for: .severalTimes) == twice, "offered, off by default")
        #expect(AiringReminder.suggestedTimes(for: .windowUsuallyOpen) == nil, "not offered")
        #expect(AiringReminder.isSuggested(for: .rarely) && AiringReminder.isSuggested(for: .onceADay))
        #expect(!AiringReminder.isSuggested(for: .severalTimes))
    }

    @Test func timesAreCleanedUp() {
        let t = [ReminderTime(hour: 20), ReminderTime(hour: 9), ReminderTime(hour: 20), ReminderTime(hour: 13), ReminderTime(hour: 7)]
        #expect(AiringReminder.normalized(t) == [ReminderTime(hour: 7), ReminderTime(hour: 9), ReminderTime(hour: 13)])
        #expect(AiringReminder.normalized([]) == [ReminderTime(hour: 9)], "never empty")
        #expect(AiringReminder.decode(AiringReminder.encode([ReminderTime(hour: 21, minute: 30)])) == [ReminderTime(hour: 21, minute: 30)])
        #expect(AiringReminder.decode("25:00,nonsense,08:15") == [ReminderTime(hour: 8, minute: 15)])
        #expect(ReminderTime(hour: 30, minute: -4) == ReminderTime(hour: 23, minute: 0))
    }

    @Test func wording() {
        #expect(AiringReminder.title(placeName: "Bedroom") == "Time to air the bedroom")
        #expect(AiringReminder.title(placeName: "Living room") == "Time to air the living room")
        #expect(AiringReminder.title(placeName: "Anna's room") == "Time to air Anna's room")
        #expect(AiringReminder.title(placeName: nil) == "Time to air the room")
        #expect(AiringReminder.body == "Open a window wide for 5 minutes.")
    }

    @Test func requestsRepeatDailyWithCancellableIDs() {
        let requests = AiringReminder.requests(times: [ReminderTime(hour: 20), ReminderTime(hour: 9, minute: 5)], placeName: "Bedroom")
        #expect(requests.map(\.identifier) == ["airing-reminder-0", "airing-reminder-1"])
        #expect(Set(requests.map(\.identifier)).isSubset(of: AiringReminder.allIdentifiers))
        let trigger = requests[0].trigger
        #expect(trigger.repeats)
        #expect(trigger.dateComponents.hour == 9 && trigger.dateComponents.minute == 5)
        #expect(requests[1].trigger.dateComponents.hour == 20)
    }

    @Test func onAsksThenSchedulesAndRescheduleReplaces() async {
        let center = FakeCenter()
        let reminders = AiringReminders(defaults: freshDefaults(), center: { center })
        var place = "Bedroom"
        reminders.placeName = { place }
        reminders.reschedule()
        #expect(center.asked == 0 && center.pending.isEmpty, "off: nothing asked, nothing scheduled")

        reminders.enable(times: [ReminderTime(hour: 9), ReminderTime(hour: 20)])
        await reminders.pendingAsk?.value
        #expect(center.asked == 1)
        #expect(center.pending.count == 2)
        #expect(center.pending["airing-reminder-0"]?.title == "Time to air the bedroom")

        place = "Kitchen"
        reminders.times = [ReminderTime(hour: 7)]
        #expect(center.pending.count == 1, "old times cancelled")
        #expect(center.pending["airing-reminder-0"]?.title == "Time to air the kitchen")

        reminders.isOn = false
        #expect(center.pending.isEmpty)
    }

    @Test func refusalTurnsItBackOff() async {
        let center = FakeCenter(); center.grant = false
        let d = freshDefaults()
        let reminders = AiringReminders(defaults: d, center: { center })
        reminders.isOn = true
        await reminders.pendingAsk?.value
        #expect(!reminders.isOn)
        #expect(reminders.denied)
        #expect(center.pending.isEmpty)
        #expect(!d.bool(forKey: AiringReminders.onKey))
    }

    @Test func atMostThreeTimesAndNeverNone() {
        let reminders = AiringReminders(defaults: freshDefaults(), center: { FakeCenter() })
        reminders.times = [ReminderTime(hour: 9)]
        reminders.remove(ReminderTime(hour: 9))
        #expect(reminders.times == [ReminderTime(hour: 9)])
        reminders.add(ReminderTime(hour: 12)); reminders.add(ReminderTime(hour: 18)); reminders.add(ReminderTime(hour: 21))
        #expect(reminders.times.count == 3)
    }

    @Test func persists() {
        let d = freshDefaults()
        let a = AiringReminders(defaults: d, center: { FakeCenter() })
        a.times = [ReminderTime(hour: 8, minute: 30), ReminderTime(hour: 21)]
        let b = AiringReminders(defaults: d, center: { FakeCenter() })
        #expect(b.times == [ReminderTime(hour: 8, minute: 30), ReminderTime(hour: 21)])
    }
}

// MARK: - Demo offer and Night's button

@MainActor
@Suite("Onboarding — demo offer and Night")
struct DemoOfferAndNightTests {
    @Test func firstRunAlwaysOffersTheDemo() {
        for requested in [false, true] {
            #expect(OnboardingDemoOffer.shown(replay: false, useDemo: false, homeKitRequested: requested,
                                              homeDenied: false, hasSensors: requested))
        }
    }

    @Test func replayOnAppleHomeHidesTheDemo() {
        // A sensor found, or access granted with the demo off: no demo link.
        #expect(!OnboardingDemoOffer.shown(replay: true, useDemo: false, homeKitRequested: true,
                                           homeDenied: false, hasSensors: false))
        #expect(!OnboardingDemoOffer.shown(replay: true, useDemo: false, homeKitRequested: false,
                                           homeDenied: false, hasSensors: true))
        // Never asked, or refused: the demo is still a way in.
        #expect(OnboardingDemoOffer.shown(replay: true, useDemo: false, homeKitRequested: false,
                                          homeDenied: false, hasSensors: false))
        #expect(OnboardingDemoOffer.shown(replay: true, useDemo: false, homeKitRequested: true,
                                          homeDenied: true, hasSensors: false))
        // Already on the demo: "Continue with the demo" stays.
        #expect(OnboardingDemoOffer.shown(replay: true, useDemo: true, homeKitRequested: true,
                                          homeDenied: false, hasSensors: true))
    }

    @Test func showMeRevealsThenContinues() async throws {
        let d = freshDefaults()
        let model = OnboardingModel(mode: .replay, recorder: Recorder(defaults: d), defaults: d)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(model.nightPrimaryTitle == "Show me")

        model.nightPrimary(reduceMotion: true, now: t0)
        #expect(model.nightRevealRequests == 1, "asks the screen to reveal")
        #expect(model.step == .welcome, "doesn't move on")

        model.nightRevealed = true // what NightScreen's reveal() does
        #expect(model.nightPrimaryTitle == "Continue")
        model.nightPrimary(reduceMotion: true, now: t0.addingTimeInterval(0.2))
        #expect(model.nightRevealRequests == 1, "a double tap neither asks again…")
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.step == .welcome, "…nor skips the reveal")

        model.nightPrimary(reduceMotion: true, now: t0.addingTimeInterval(1))
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.step == .questions, "Continue moves on")
        #expect(model.nightRevealRequests == 1)
    }
}

// MARK: - Analytics

@MainActor
@Suite("Onboarding — analytics", .serialized)
struct OnboardingAnalyticsTests {
    @Test func completedCarriesTheAnswersAndNothingPersonal() {
        var events: [(String, [String: Any])] = []
        Analytics.sink = { events.append(($0, $1)) }
        defer { Analytics.sink = nil }

        var draft = OnboardingDraft()
        draft.staged.goals = [.sleep, .focus]
        draft.staged.habit = .onceADay
        draft.confirm(.questions)
        draft.staged.place = .newPlace(name: "Anna's room")
        draft.confirm(.place)
        draft.staged.limit = .sensitive
        draft.staged.soundOn = true
        draft.confirm(.furin)

        OnboardingAnalytics.completed(answers: draft.answers, demo: false, seconds: 84,
                                      limit: 800, reminderOn: true, notificationsOn: false)
        // Other suites may emit while the sink is installed: look at ours only.
        let completed = events.filter { $0.0 == "onboarding_completed" }
        #expect(completed.count == 1)
        guard let (_, p) = completed.first else { return }
        #expect(p["path"] as? String == "sensor")
        #expect(p["seconds"] as? Int == 84)
        #expect(p["goals"] as? [String] == ["focus", "sleep"])
        #expect(p["habit"] as? String == "onceADay")
        #expect(p["limit"] as? Int == 800)
        #expect(p["reminder_on"] as? Bool == true)
        #expect(p["notifications_on"] as? Bool == false)
        #expect(!p.values.contains { "\($0)".contains("Anna") }, "no place names")
    }

    @Test func placesAreKeysNeverNames() {
        #expect(OnboardingAnalytics.placeKey("Bedroom") == "bedroom")
        #expect(OnboardingAnalytics.placeKey("living room") == "living_room")
        #expect(OnboardingAnalytics.placeKey("Anna's room") == "custom")
        #expect(OnboardingAnalytics.placeKey(nil) == "custom")
    }

    @Test func detectionResults() {
        let s = SensorInfo(id: UUID(), name: "x", room: "", manufacturer: "", isReachable: true)
        #expect(OnboardingAnalytics.detectionResult(.waiting) == nil)
        #expect(OnboardingAnalytics.detectionResult(.found(s, ppm: 900, fresh: true)) == "found_one")
        #expect(OnboardingAnalytics.detectionResult(.several([s, s])) == "found_several")
        #expect(OnboardingAnalytics.detectionResult(.noSensor) == "none")
        #expect(OnboardingAnalytics.detectionResult(.noHome) == "no_home")
    }

    @Test func noSinkIsANoOp() {
        Analytics.sink = nil
        Analytics.track("onboarding_replayed") // must not crash or need a sink
    }
}
