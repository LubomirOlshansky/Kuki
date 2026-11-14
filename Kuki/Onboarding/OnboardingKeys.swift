import Foundation

/// Where the introduction keeps its state. The standard defaults, not the App
/// Group: widgets never need these.
enum OnboardingKeys {
    static let hasCompleted = "hasCompletedOnboarding"
    static let version = "onboardingVersion"
    static let resumeStep = "onboardingResumeStep"
    static let migrated = "onboardingMigrated"
    static let homeKitRequested = "homeKitRequested"
    static let airGoals = "airGoals"
    static let airingHabit = "airingHabit"

    /// Bumped when the introduction changes enough to be worth showing again.
    static let currentVersion = 1
}

/// Runs once per install, before the recorder seeds its places: an install
/// that already has places predates the introduction, so it skips it and keeps
/// talking to Apple Home as before.
enum OnboardingMigration {
    static func run(defaults: UserDefaults) {
        #if DEBUG
        // `-resetOnboarding YES` shows the introduction again (it doesn't reset
        // the HomeKit or notification permission itself).
        if defaults.bool(forKey: "resetOnboarding") {
            for key in [OnboardingKeys.hasCompleted, OnboardingKeys.version, OnboardingKeys.resumeStep,
                        OnboardingKeys.homeKitRequested, OnboardingKeys.airGoals, OnboardingKeys.airingHabit] {
                defaults.removeObject(forKey: key)
            }
            defaults.set(true, forKey: OnboardingKeys.migrated)
            applyDebugStep(defaults: defaults)
            return
        }
        applyDebugStep(defaults: defaults)
        #endif
        guard !defaults.bool(forKey: OnboardingKeys.migrated) else { return }
        defaults.set(true, forKey: OnboardingKeys.migrated)
        if defaults.object(forKey: "seededPlaces") != nil {
            defaults.set(true, forKey: OnboardingKeys.hasCompleted)
            defaults.set(true, forKey: OnboardingKeys.homeKitRequested)
        }
    }

    #if DEBUG
    /// `-onboardingStep <step>` opens the introduction at that screen (for
    /// screenshots); `appleHome` implies Apple Home was asked for.
    static var debugStep: OnboardingStep? {
        UserDefaults.standard.string(forKey: "onboardingStep").flatMap(OnboardingStep.init(rawValue:))
    }

    private static func applyDebugStep(defaults: UserDefaults) {
        guard defaults === UserDefaults.standard, let step = debugStep else { return }
        defaults.set(false, forKey: OnboardingKeys.hasCompleted)
        if step == .appleHome { defaults.set(true, forKey: OnboardingKeys.homeKitRequested) }
    }
    #endif
}
