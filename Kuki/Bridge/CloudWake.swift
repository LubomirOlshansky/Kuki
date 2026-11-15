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
        // History sync (the KukiHistory zone, via CKSyncEngine's database
        // subscription) and the latest-reading mailbox (LatestAir query
        // subscription) share the one push channel.
        let isHistory = HistorySync.isHistoryNotification(userInfo)
        let appIsActive = application.applicationState == .active
        Task { @MainActor in
            let changed: Bool
            if isHistory {
                changed = await HistorySync.shared.fetchNow()
            } else {
                #if targetEnvironment(macCatalyst)
                changed = false // the Mac publishes the latest reading; it never follows it
                #else
                changed = await CloudWake.handle(appIsActive: appIsActive)
                #endif
            }
            completionHandler(changed ? .newData : .noData)
        }
    }
}

@MainActor
enum CloudWake {
    private static let log = Logger(subsystem: "com.olshanskysoft.kuki", category: "wake")

    /// Returns true when a newer reading arrived.
    @discardableResult
    static func handle(appIsActive: Bool, now: Date = .now) async -> Bool {
        guard let cloud = await CloudSync.fetchLatest() else { return false }
        let local = WidgetSnapshot.load()
        guard local.map({ cloud.measuredAt > $0.measuredAt }) ?? true else { return false }

        try? cloud.save()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        // Awaited: iOS may suspend the app as soon as the wake-up's
        // completion handler is called.
        await LiveAir.shared.updateAndWait(with: cloud)
        #endif

        // While the app is open it reads the sensor itself and alerts on its
        // own; the background path only speaks when the app can't.
        if !appIsActive { await alertIfNeeded(cloud, now: now) }
        return true
    }

    /// Same rules as the in-app chime — and the same gate (`AlertGate.load`),
    /// so opening the app during a spell this already announced doesn't
    /// announce it again: once per stuffy spell, quiet until the air recovers
    /// by 100 ppm, never twice within 20 minutes, and never on a reading that
    /// is already old. Returns the CO₂ to announce, if any.
    static func alertDue(_ s: WidgetSnapshot, now: Date, defaults: UserDefaults = .standard) -> Double? {
        guard defaults.bool(forKey: "notifyOn") else { return nil }
        let fresh = now.timeIntervalSince(s.measuredAt) < Freshness.maxAge
        let limit = defaults.object(forKey: "co2Limit") as? Double ?? s.limit
        let before = AlertGate.load(from: defaults)
        var gate = before
        let ring = gate.evaluate(co2: fresh ? s.co2 : nil, limit: limit, settling: false, now: now)
        if gate != before { gate.save(to: defaults) }
        return ring ? s.co2 : nil
    }

    static func alertIfNeeded(_ s: WidgetSnapshot, now: Date, defaults: UserDefaults = .standard) async {
        guard let co2 = alertDue(s, now: now, defaults: defaults) else { return }
        // Through the same gate as the in-app chime: once per spell.
        let limit = defaults.object(forKey: "co2Limit") as? Double ?? s.limit
        Analytics.track("co2_alert_fired", [
            "level": AnalyticsValues.alertLevel(ppm: co2),
            "via": "cloud_wake",
            "limit": Int(limit.rounded()),
        ])
        AmplitudeBackend.shared.flush() // the app may be suspended again any moment

        let content = UNMutableNotificationContent()
        let place = s.placeName.isEmpty ? String(localized: "The room", comment: "Stands in for the room name at the start of the CO₂ alert notification title when no room is known (\"The room: 1200 ppm CO₂\").") : s.placeName
        content.title = String(localized: "\(place): \(Metric.co2.format(co2)) ppm CO₂", comment: "CO₂ alert notification title. %1$@ = room name (or 'The room'), %2$@ = CO₂ value. Keep ppm and CO₂.")
        content.body = String(localized: "Time to open a window for a few minutes.", comment: "CO₂ alert notification body, sent when CO₂ crosses the user's limit.")
        // The app isn't running to ring the bell: the banner carries it.
        content.sound = Furin.notificationSound(appRings: false)
        content.threadIdentifier = "co2"
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "co2-high-cloud", content: content, trigger: nil))
            log.info("cloud alert posted at \(co2)")
        } catch {
            log.error("cloud alert not posted: \(error.localizedDescription, privacy: .public)")
        }
    }
}
