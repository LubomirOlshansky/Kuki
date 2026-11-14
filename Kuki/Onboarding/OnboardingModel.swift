import Accessibility
import SwiftData
import SwiftUI
import UIKit

/// One button in the introduction's bottom bar.
struct OnboardingAction: Identifiable {
    let title: String
    let run: () -> Void
    var id: String { title }
}

/// The introduction's state: where it is, which way it last moved, what has
/// been answered, and the Apple Home clocks.
@MainActor
@Observable
final class OnboardingModel {
    enum Mode { case firstRun, replay, sheet }

    let mode: Mode
    private(set) var step: OnboardingStep
    /// The demo path (no Apple Home screen).
    var demo: Bool
    /// The direction of the last step change, for the transition.
    private(set) var forward = true
    var draft = OnboardingDraft()

    // Apple Home
    var requestedAt: Date?
    var slowFrom: Date?
    var foundAt: Date?
    /// The sensor picked on "Which sensor is yours?".
    var chosenSensor: UUID?
    /// The row highlighted on that list before Continue.
    var stagedSensor: UUID?
    var addAccessoryFailed = false
    /// The Home app's URL scheme was refused.
    var homeAppFailed = false
    /// Ticks once a second while the Apple Home screen is up.
    var clock = Date.now
    /// True from the primer's Continue until the system prompt can have been answered.
    var awaitingPrompt = false

    // One-time choreography, so going Back never replays it.
    var welcomePlayed = false
    var breathGlided = false
    var nightRevealed = false
    /// Bumped by Night's "Show me" button; the screen owns the reveal (its
    /// sweep), so it watches this instead of the model doing it.
    private(set) var nightRevealRequests = 0
    private var nightRevealRequestedAt: Date?
    /// The bottom button's opacity (the welcome fades it in; it's tappable throughout).
    var primaryOpacity = 1.0

    let canOpenHomeApp: Bool

    // Analytics bookkeeping (no names, no readings).
    let startedAt = Date.now
    /// The staged place as an analytics key ("bedroom" or "custom").
    var stagedPlaceKey = "custom"
    private var interacted: Set<OnboardingStep> = []
    var detectionReported: Set<String> = []
    var permissionReported = false

    init(mode: Mode, recorder: Recorder, defaults: UserDefaults = .standard) {
        self.mode = mode
        canOpenHomeApp = URL(string: "com.apple.home://").map { UIApplication.shared.canOpenURL($0) } ?? false
        switch mode {
        case .sheet:
            step = .appleHome
            demo = false
        case .replay:
            step = .welcome
            demo = recorder.useDemo
            chosenSensor = recorder.selectedSensorID
        case .firstRun:
            var start = OnboardingPath.resumeStep(saved: defaults.string(forKey: OnboardingKeys.resumeStep),
                                                  homeKitRequested: recorder.homeKitRequested)
            #if DEBUG
            if let debug = OnboardingMigration.debugStep { start = debug }
            #endif
            step = start
            let listen = OnboardingPath.index(of: .listen, demo: false) ?? 0
            let at = OnboardingPath.index(of: start, demo: false) ?? 0
            demo = at > listen && recorder.useDemo && !(start == .appleHome)
        }
        if mode == .replay {
            draft.staged.goals = OnboardingCommit.goals(from: defaults.string(forKey: OnboardingKeys.airGoals))
            draft.staged.habit = defaults.string(forKey: OnboardingKeys.airingHabit).flatMap(AiringHabit.init(rawValue:))
        }
    }

    var path: [OnboardingStep] { OnboardingPath.steps(demo: demo) }
    var index: Int { OnboardingPath.index(of: step, demo: demo) ?? 0 }

    // MARK: Navigation

    func go(to new: OnboardingStep, forward isForward: Bool, reduceMotion: Bool) {
        guard new != step else { return }
        forward = isForward
        // Let the outgoing page pick up the new direction before it leaves.
        Task { @MainActor in
            withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .smooth(duration: 0.45)) {
                self.step = new
            }
            AccessibilityNotification.ScreenChanged().post()
        }
    }

    func next(reduceMotion: Bool) {
        draft.confirm(step)
        reportAnswers(for: step)
        if let n = OnboardingPath.next(after: step, demo: demo) { go(to: n, forward: true, reduceMotion: reduceMotion) }
    }

    /// Night's primary button: "Show me" until the guess is revealed, then
    /// "Continue".
    var nightPrimaryTitle: String { nightRevealed ? "Continue" : "Show me" }

    /// "Show me" asks for the reveal; "Continue" moves on — but not in the
    /// same breath as the reveal, so a double tap doesn't skip the sweep.
    func nightPrimary(reduceMotion: Bool, now: Date = .now) {
        if nightRevealed {
            if let asked = nightRevealRequestedAt, now.timeIntervalSince(asked) < 0.6 { return }
            next(reduceMotion: reduceMotion)
        } else {
            noteInteraction("show_me")
            nightRevealRequestedAt = now
            nightRevealRequests += 1
        }
    }

    func back(reduceMotion: Bool) {
        if let p = OnboardingPath.previous(before: step, demo: demo) { go(to: p, forward: false, reduceMotion: reduceMotion) }
    }

    // MARK: Apple Home

    func homeState(_ recorder: Recorder) -> HomeConnectionState {
        let hk = recorder.homeKit
        return HomeConnection.state(
            requested: recorder.homeKitRequested && !recorder.useDemo && hk.isStarted,
            requestedAt: requestedAt, status: hk.status, statusSince: hk.statusChangedAt,
            sensors: hk.sensors, snapshots: hk.snapshots, chosen: chosenSensor,
            foundAt: foundAt, now: clock, slowFrom: slowFrom)
    }

    /// Call when the Apple Home screen opens: an Apple Home already asked for
    /// starts straight in detection.
    func enterAppleHome(_ recorder: Recorder) {
        clock = .now
        if recorder.homeKitRequested {
            if recorder.useDemo || !recorder.homeKit.isStarted { recorder.connectHomeKit() }
        }
        noteFound(recorder)
    }

    /// The primer's Continue: the system prompt appears.
    func connect(_ recorder: Recorder) {
        requestedAt = .now
        slowFrom = nil
        awaitingPrompt = true
        recorder.connectHomeKit()
        clock = .now
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            self.awaitingPrompt = false
        }
    }

    func checkAgain(_ recorder: Recorder) {
        slowFrom = .now
        clock = .now
        recorder.homeKit.recheck()
    }

    func noteFound(_ recorder: Recorder) {
        if foundAt == nil, recorder.homeKit.status == .ready, !recorder.homeKit.sensors.isEmpty { foundAt = .now }
    }

    /// Whether "Try the demo" is offered (see `OnboardingDemoOffer`).
    func offersDemo(_ recorder: Recorder) -> Bool {
        OnboardingDemoOffer.shown(replay: mode == .replay, useDemo: recorder.useDemo,
                                  homeKitRequested: recorder.homeKitRequested,
                                  homeDenied: recorder.homeKit.status == .notAuthorized,
                                  hasSensors: !recorder.homeKit.sensors.isEmpty)
    }

    func tryDemo(_ recorder: Recorder, reduceMotion: Bool) {
        OnboardingAnalytics.demoChosen(step)
        recorder.useDemo = true
        demo = true
        go(to: .place, forward: true, reduceMotion: reduceMotion)
    }

    // MARK: Analytics

    /// The first hands-on moment on a science screen (once per screen per run).
    func noteInteraction(_ control: String) {
        guard !interacted.contains(step) else { return }
        interacted.insert(step)
        OnboardingAnalytics.scienceInteracted(step, control: control)
    }

    private func reportAnswers(for step: OnboardingStep) {
        let a = draft.answers
        switch step {
        case .questions:
            OnboardingAnalytics.answered("goals", OnboardingAnalytics.goals(a.goals))
            OnboardingAnalytics.answered("habit", a.habit?.rawValue ?? "none")
        case .place:
            if a.place != nil { OnboardingAnalytics.answered("place", stagedPlaceKey) }
        case .furin:
            if let limit = a.limit { OnboardingAnalytics.answered("limit", Int(limit.ppm.rounded())) }
            if let sound = a.soundOn { OnboardingAnalytics.answered("chime", sound) }
        default:
            break
        }
    }

    /// Apple Home's answers, each reported once per run.
    func reportHome(_ state: HomeConnectionState, recorder: Recorder) {
        let hk = recorder.homeKit
        if requestedAt != nil, !permissionReported, hk.status != .starting {
            permissionReported = true
            let result = hk.status == .notAuthorized ? (hk.isRestricted ? "restricted" : "denied") : "granted"
            Analytics.track("home_permission_result", ["result": result])
        }
        guard let result = OnboardingAnalytics.detectionResult(state), !detectionReported.contains(result) else { return }
        detectionReported.insert(result)
        let since = requestedAt ?? startedAt
        Analytics.track("sensor_detection_result", [
            "result": result,
            "sensor_count": hk.sensors.count,
            "seconds": max(0, Int(Date.now.timeIntervalSince(since).rounded())),
        ])
    }

    // MARK: Plan

    /// The place the commit will set, as a name and kanji.
    func plannedPlace(_ places: [Place], current: UUID?) -> (name: String, kanji: String)? {
        switch draft.answers.place ?? draft.staged.place {
        case .existing(let id):
            return places.first { $0.id == id }.map { ($0.name, $0.kanji) }
        case .newPlace(let name):
            return (name, "")
        case nil:
            return places.first { $0.id == current }.map { ($0.name, $0.kanji) }
        }
    }

    /// Begin (or Skip): write the answers and finish.
    func commit(recorder: Recorder, context: ModelContext, defaults: UserDefaults = .standard) {
        OnboardingCommit.apply(draft.answers, to: recorder, defaults: defaults,
                               places: SwiftDataPlaceStore(context: context, recorder: recorder))
    }
}

/// New places from the introduction, in SwiftData.
@MainActor
final class SwiftDataPlaceStore: PlaceStore {
    let context: ModelContext
    let recorder: Recorder

    init(context: ModelContext, recorder: Recorder) {
        self.context = context
        self.recorder = recorder
    }

    func id(named name: String) -> UUID? {
        let all = (try? context.fetch(FetchDescriptor<Place>())) ?? []
        return all.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }?.id
    }

    func insert(name: String) -> UUID {
        let all = (try? context.fetch(FetchDescriptor<Place>())) ?? []
        let place = Place(name: name, sortIndex: (all.map(\.sortIndex).max() ?? -1) + 1)
        context.insert(place)
        try? context.save()
        recorder.placeEdited(place)
        return place.id
    }
}

// MARK: - Viewport

private struct OnboardingViewportKey: EnvironmentKey {
    static let defaultValue = CGSize(width: 390, height: 800)
}

extension EnvironmentValues {
    /// The introduction's visible area (inside the bars), for hero sizes.
    var onboardingViewport: CGSize {
        get { self[OnboardingViewportKey.self] }
        set { self[OnboardingViewportKey.self] = newValue }
    }
}
