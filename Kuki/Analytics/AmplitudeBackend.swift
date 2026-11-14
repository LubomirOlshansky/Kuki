import AmplitudeSwift
import Foundation
import os

/// The only file that knows about the Amplitude SDK: it creates the one
/// instance at launch and points the `Analytics` facade at it.
///
/// - EU data centre (`serverZone: .EU`).
/// - Autocapture: sessions and app lifecycle (installed / updated / opened /
///   backgrounded) only — screens are tracked by hand (`tab_viewed` …).
/// - Device ID: the SDK's default, the identifier for vendor. No IDFA.
/// - IP address left on: Amplitude derives country and city from it.
/// - No remote config and no SDK diagnostics: nothing is fetched or sent
///   beyond our own events.
///
/// Consent: with "Share usage data" off at launch the SDK isn't
/// even created; turned off later, `optOut` stops it (session and lifecycle
/// events included) and the facade drops everything before it gets here.
@MainActor
final class AmplitudeBackend {
    static let shared = AmplitudeBackend()

    private var amplitude: Amplitude?
    private let log = Logger(subsystem: "com.olshanskysoft.kuki", category: "analytics")

    /// Call once, at launch. Does nothing outside the real app or under tests.
    func start() {
        guard AnalyticsConfig.shouldStart() else {
            log.notice("analytics off: bundle \(Bundle.main.bundleIdentifier ?? "?", privacy: .public) or tests")
            return
        }
        Analytics.enabledChanged = { [weak self] on in self?.apply(enabled: on) }
        Analytics.sink = { [weak self] event, properties in
            self?.amplitude?.track(eventType: event, eventProperties: properties)
        }
        Analytics.userPropertiesSink = { [weak self] properties in
            self?.amplitude?.identify(userProperties: properties)
        }
        if Analytics.isEnabled { create() }
    }

    /// Hand queued events over (the app is going to the background).
    func flush() {
        amplitude?.flush()
    }

    var deviceID: String? { amplitude?.getDeviceId() }

    private func apply(enabled: Bool) {
        if enabled {
            if let amplitude {
                amplitude.configuration.optOut = false
            } else {
                create()
            }
            log.notice("analytics on")
        } else {
            amplitude?.configuration.optOut = true
            log.notice("analytics off (opted out)")
        }
    }

    private func create() {
        guard amplitude == nil else { return }
        #if DEBUG
        let level = LogLevelEnum.warn
        // Debug only: one line per uploaded event, so a live check can see
        // the server's answer (`log stream --predicate 'category == "analytics"'`).
        let callback: EventCallback = { event, code, message in
            Logger(subsystem: "com.olshanskysoft.kuki", category: "analytics")
                .notice("upload \(code) \(event.eventType, privacy: .public): \(message, privacy: .public)")
        }
        #else
        let level = LogLevelEnum.off
        let callback: EventCallback? = nil
        #endif
        let configuration = Configuration(
            apiKey: AnalyticsConfig.apiKey,
            optOut: !Analytics.isEnabled,
            logLevel: level,
            callback: callback,
            serverZone: .EU,
            autocapture: [.sessions, .appLifecycles],
            enableAutoCaptureRemoteConfig: false,
            enableDiagnostics: false
        )
        amplitude = Amplitude(configuration: configuration)
        #if DEBUG
        log.notice("amplitude started (EU), device \(self.deviceID ?? "?", privacy: .public)")
        #endif
    }
}
