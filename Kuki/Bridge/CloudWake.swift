import Foundation
import os
import UIKit
import UserNotifications
import WidgetKit

/// Receives the iCloud wake-ups (silent pushes) that fire when another
/// device — typically the Mac recording around the clock — publishes a
/// reading. iOS can't read HomeKit in the background, but it can do this:
/// fetch the Mac's reading, refresh the widget and the Live Activity, and
/// post the CO₂ alert if the air crossed your limit.
final class KukiAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if !targetEnvironment(macCatalyst)
        // Only the phone follows; the Mac is the one publishing.
        if CloudSync.isEnabled {
            application.registerForRemoteNotifications()
            Task { await CloudSync.ensureSubscription() }
        }
        #endif
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            let changed = await CloudWake.handle(appIsActive: application.applicationState == .active)
            completionHandler(changed ? .newData : .noData)
        }
    }
}

@MainActor
enum CloudWake {
    private static let log = Logger(subsystem: "com.olshanskysoft.kuki", category: "wake")
    private static let gateKey = "cloudAlertGate"

    /// Returns true when a newer reading arrived.
    @discardableResult
    static func handle(appIsActive: Bool, now: Date = .now) async -> Bool {
        guard let cloud = await CloudSync.fetchLatest() else { return false }
        let local = WidgetSnapshot.load()
        guard local.map({ cloud.measuredAt > $0.measuredAt }) ?? true else { return false }

        try? cloud.save()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        LiveAir.shared.update(with: cloud)
        #endif

        // While the app is open it reads the sensor itself and alerts on its
        // own; the background path only speaks when the app can't.
        if !appIsActive { alertIfNeeded(cloud, now: now) }
        return true
    }

    /// Same rules as the in-app chime: once per stuffy spell, quiet until the
    /// air recovers by 100 ppm, never twice within 20 minutes, and never on
    /// a reading that is already old.
    static func alertIfNeeded(_ s: WidgetSnapshot, now: Date, defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: "notifyOn") else { return }
        let fresh = now.timeIntervalSince(s.measuredAt) < Freshness.maxAge
        let limit = defaults.object(forKey: "co2Limit") as? Double ?? s.limit
        var gate = (defaults.data(forKey: gateKey)).flatMap { try? JSONDecoder().decode(AlertGate.self, from: $0) } ?? AlertGate()
        let ring = gate.evaluate(co2: fresh ? s.co2 : nil, limit: limit, settling: false, now: now)
        if let data = try? JSONEncoder().encode(gate) { defaults.set(data, forKey: gateKey) }
        guard ring, let co2 = s.co2 else { return }

        let content = UNMutableNotificationContent()
        let place = s.placeName.isEmpty ? "The room" : s.placeName
        content.title = "\(place): \(Metric.co2.format(co2)) ppm CO₂"
        content.body = "Time to open a window for a few minutes."
        // The app isn't running to ring the bell: the banner carries it.
        content.sound = Furin.notificationSound(appRings: false)
        content.threadIdentifier = "co2"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "co2-high-cloud", content: content, trigger: nil))
        log.info("cloud alert posted at \(co2)")
    }
}
