import Foundation

/// Which Amplitude project a build reports to, and whether it reports at all.
///
/// The keys are Amplitude *client* keys: they ship inside every binary and
/// only allow sending events, never reading them.
enum AnalyticsConfig {
    /// Debug builds → "Kūki DEV"; Release (TestFlight, App Store) → "Kūki PROD".
    static var apiKey: String {
        #if DEBUG
        "86b11479190ba51a539cc58a63b9ad58"
        #else
        "b552113226280862f08b29c77050e474"
        #endif
    }

    /// Only the real app sends: someone who clones the public repo and builds
    /// it under their own bundle ID never reports into these projects.
    static let bundleIdentifier = "com.olshanskysoft.kuki"

    /// Never under XCTest (the unit tests run inside the app as host).
    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static func shouldStart(bundleID: String? = Bundle.main.bundleIdentifier,
                            runningTests: Bool = isRunningTests) -> Bool {
        bundleID == bundleIdentifier && !runningTests
    }
}
