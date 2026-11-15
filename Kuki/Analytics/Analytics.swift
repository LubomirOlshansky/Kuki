import Foundation
import os

/// Product analytics, as a facade: every call site uses `Analytics.track`,
/// and nothing leaves the device until a sink is installed (the Amplitude
/// hookup in `AmplitudeBackend` sets `Analytics.sink` at launch). Without one
/// it's a no-op, so tests and forks stay SDK-free.
///
/// Privacy: properties never carry place, sensor or home names, or readings
/// from the user's sensor. `forbiddenKeys` strips the obvious ones as a last
/// line of defence; the call sites are written not to send them at all.
///
/// Consent: `isEnabled` ("Share usage data" in Settings, on by
/// default) is checked before anything reaches a sink. Off means nothing is
/// sent — no events, no user properties, and the SDK itself is opted out.
@MainActor
enum Analytics {
    typealias Sink = (_ event: String, _ properties: [String: Any]) -> Void
    typealias UserPropertiesSink = (_ properties: [String: Any]) -> Void

    /// Where events go. nil = nowhere.
    static var sink: Sink?
    /// Where user properties (an Amplitude Identify) go. nil = nowhere.
    static var userPropertiesSink: UserPropertiesSink?
    /// Told when the user turns sharing on or off (the SDK's `optOut`).
    static var enabledChanged: ((Bool) -> Void)?

    /// Where the consent switch lives. Tests swap in their own suite.
    static var defaults: UserDefaults = .standard
    static let enabledKey = "analyticsEnabled"

    /// "Share usage data". On unless the user turned it off.
    static var isEnabled: Bool {
        get { defaults.object(forKey: enabledKey) as? Bool ?? true }
        set {
            guard newValue != isEnabled else { return }
            defaults.set(newValue, forKey: enabledKey)
            enabledChanged?(newValue)
        }
    }

    /// Keys that would carry a name or a reading. Dropped from every event
    /// and user property, whatever the call site passed.
    static let forbiddenKeys: Set<String> = [
        "name", "place", "place_name", "room", "room_name", "home", "home_name",
        "sensor", "sensor_name", "accessory", "accessory_name",
        "co2", "ppm", "temperature", "humidity", "pm25", "pm2_5", "value", "reading",
        "text", "contents", "file", "file_name", "record_name", "device_id", "icloud_id", "user_id",
    ]

    private static let log = Logger(subsystem: "com.olshanskysoft.kuki", category: "analytics")

    static func track(_ event: String, _ properties: [String: Any] = [:]) {
        guard isEnabled else { return }
        let clean = scrub(properties)
        #if DEBUG
        let shown = clean.keys.sorted().map { "\($0)=\(clean[$0]!)" }.joined(separator: " ")
        log.debug("\(event, privacy: .public) \(shown, privacy: .public)")
        #endif
        sink?(event, clean)
    }

    /// Set user properties (only the ones given; others keep their values).
    static func setUserProperties(_ properties: [String: Any]) {
        guard isEnabled, !properties.isEmpty else { return }
        let clean = scrub(properties)
        #if DEBUG
        let shown = clean.keys.sorted().map { "\($0)=\(clean[$0]!)" }.joined(separator: " ")
        log.debug("identify \(shown, privacy: .public)")
        #endif
        userPropertiesSink?(clean)
    }

    static func scrub(_ properties: [String: Any]) -> [String: Any] {
        properties.filter { !forbiddenKeys.contains($0.key) }
    }

    // MARK: Debounce

    private static var pending: [String: Task<Void, Never>] = [:]

    /// Track `event` once things have settled: a later call with the same
    /// `key` within `delay` replaces this one (a stepper tapped five times
    /// is one change).
    static func trackDebounced(_ event: String, key: String? = nil, delay: Duration = .seconds(2),
                               _ properties: [String: Any] = [:]) {
        let key = key ?? event
        pending[key]?.cancel()
        pending[key] = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            pending[key] = nil
            track(event, properties)
        }
    }
}

/// Small shared vocabulary for event properties.
enum AnalyticsValues {
    /// clear / fine / stale / stuffy — the level names the events use.
    static func levelName(_ level: CO2Level) -> String {
        switch level {
        case .clear: "clear"
        case .fine: "fine"
        case .stale: "stale"
        case .poor: "stuffy"
        }
    }

    /// The alert's level: getting_stale below the "stuffy" band, stuffy in it.
    static func alertLevel(ppm: Double) -> String {
        CO2Level(ppm: ppm) == .poor ? "stuffy" : "getting_stale"
    }
}

/// The introduction's events and their properties — built here so the
/// privacy rules live in one place and tests can check them.
@MainActor
enum OnboardingAnalytics {
    static func platformName(_ platform: OnboardingPlatform) -> String {
        switch platform {
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .mac: "mac"
        }
    }

    /// A seeded place's stable key ("bedroom", "living_room"), or "custom"
    /// for anything the user typed or Apple Home named. Never the name itself.
    static func placeKey(_ name: String?) -> String {
        // Matches the English name or the current language's seeded name, so
        // the key stays English ("bedroom") on a German or Japanese device.
        guard let name, let i = Place.seededIndex(name) else { return "custom" }
        return Place.defaults[i].0.lowercased().replacingOccurrences(of: " ", with: "_")
    }

    static func goals(_ goals: Set<AirGoal>?) -> [String] {
        (goals ?? []).map(\.rawValue).sorted()
    }

    static func started(replay: Bool, platform: OnboardingPlatform) {
        Analytics.track("onboarding_started", ["is_replay": replay, "platform": platformName(platform)])
    }

    static func stepViewed(_ step: OnboardingStep, index: Int, total: Int) {
        Analytics.track("onboarding_step_viewed", ["step": step.rawValue, "index": index, "total": total])
    }

    static func answered(_ question: String, _ answer: Any) {
        Analytics.track("onboarding_quiz_answered", ["question": question, "answer": answer])
    }

    static func scienceInteracted(_ step: OnboardingStep, control: String) {
        Analytics.track("onboarding_science_interacted", ["screen": step.rawValue, "control": control])
    }

    static func skipped(_ step: OnboardingStep, index: Int) {
        Analytics.track("onboarding_skipped", ["step": step.rawValue, "index": index])
    }

    static func demoChosen(_ step: OnboardingStep) {
        Analytics.track("onboarding_demo_chosen", ["step": step.rawValue])
    }

    static func completedProperties(answers: OnboardingAnswers, demo: Bool, seconds: Int, limit: Double,
                                    reminderOn: Bool, notificationsOn: Bool) -> [String: Any] {
        [
            "path": demo ? "demo" : "sensor",
            "seconds": seconds,
            "goals": goals(answers.goals),
            "habit": answers.habit?.rawValue ?? "none",
            "limit": Int(limit.rounded()),
            "reminder_on": reminderOn,
            "notifications_on": notificationsOn,
        ]
    }

    static func completed(answers: OnboardingAnswers, demo: Bool, seconds: Int, limit: Double,
                          reminderOn: Bool, notificationsOn: Bool) {
        Analytics.track("onboarding_completed", completedProperties(
            answers: answers, demo: demo, seconds: seconds, limit: limit,
            reminderOn: reminderOn, notificationsOn: notificationsOn))
    }

    /// The detection outcome's name for `sensor_detection_result`, or nil
    /// while Apple Home is still being asked.
    static func detectionResult(_ state: HomeConnectionState) -> String? {
        switch state {
        case .found, .foundWaiting, .unreachable: "found_one"
        case .several: "found_several"
        case .noSensor: "none"
        case .noHome: "no_home"
        case .denied: "denied"
        case .slow: "slow"
        case .notRequested, .waiting: nil
        }
    }
}
