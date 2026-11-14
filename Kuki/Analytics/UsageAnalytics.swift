import Foundation
import Observation
import SwiftData
import UIKit
import UserNotifications
#if !targetEnvironment(macCatalyst)
import WidgetKit
#endif

/// Once per calendar day (in the device's own calendar), kept in the
/// defaults. Used by the daily heartbeat, the menu-bar sample and the widget
/// census.
struct DailyGate {
    let key: String
    let defaults: UserDefaults
    var calendar: Calendar = .current

    static func stamp(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func isDue(now: Date) -> Bool {
        defaults.string(forKey: key) != Self.stamp(now, calendar: calendar)
    }

    func mark(now: Date) {
        defaults.set(Self.stamp(now, calendar: calendar), forKey: key)
    }

    /// True (and marked) the first time it's asked on a given day.
    func claim(now: Date) -> Bool {
        guard isDue(now: now) else { return false }
        mark(now: now)
        return true
    }
}

/// The daily heartbeat's properties — counts and buckets only, never values.
enum DailyStatus {
    /// clear / fine / stale / stuffy: the level most of the CO₂ readings
    /// fell in (ties go to the worse level), or "none" without any.
    static func levelMostOf(_ co2: [Double]) -> String {
        guard !co2.isEmpty else { return "none" }
        var counts: [CO2Level: Int] = [:]
        for ppm in co2 { counts[CO2Level(ppm: ppm), default: 0] += 1 }
        let order = CO2Level.allCases // clear … poor: later = worse
        let best = order.max { a, b in
            let (ca, cb) = (counts[a] ?? 0, counts[b] ?? 0)
            if ca != cb { return ca < cb }
            return order.firstIndex(of: a)! < order.firstIndex(of: b)!
        }!
        return AnalyticsValues.levelName(best)
    }

    static func properties(readingCount: Int, co2: [Double], sensorConnected: Bool, placesCount: Int,
                           syncOn: Bool, demoOn: Bool) -> [String: Any] {
        [
            "sensor_connected": sensorConnected,
            "readings_today_count": readingCount,
            "level_most_of_today": levelMostOf(co2),
            "places_count": placesCount,
            "sync_on": syncOn,
            "demo_on": demoOn,
        ]
    }
}

/// Everything analytics needs to *watch* rather than be told: user
/// properties, the daily heartbeat, Home access changes, debounced History
/// views, the Live Activity's end and the once-a-day menu-bar sample.
///
/// Nothing here runs per reading. The only timer is the heartbeat's check,
/// every 30 minutes, which sends at most once a day.
@MainActor
final class UsageAnalytics {
    static let shared = UsageAnalytics()

    private weak var recorder: Recorder?
    private var container: ModelContainer?
    private var started = false
    private var lastSent: [String: String] = [:]
    private var pendingIdentify: Task<Void, Never>?
    private var heartbeatLoop: Task<Void, Never>?
    /// The heartbeat waits a minute after launch, so Apple Home has had time
    /// to report the sensor before `sensor_connected` is read.
    private var heartbeatReady = false
    private let defaults = UserDefaults.standard

    /// Settings › ⌘, on iPad switches to the Settings tab: say how it opened.
    var pendingSettingsVia: String?

    private enum Keys {
        static let dailyStatus = "analyticsDailyStatusDay"
        static let menuOpened = "analyticsMenuOpenedDay"
        static let widgetsDay = "analyticsWidgetsDay"
        static let widgets = "analyticsWidgets"
        static let homeAccess = "analyticsHomeAccessState"
    }

    func start(recorder: Recorder, container: ModelContainer) {
        guard !started else { return }
        started = true
        self.recorder = recorder
        self.container = container
        observeProperties()
        refreshWidgets()
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        LiveAir.shared.observeExisting()
        #endif
        heartbeatLoop = Task { [weak self] in
            // Give Apple Home a minute to report the sensor before the first
            // look, then check every half hour; it sends once a day.
            try? await Task.sleep(for: .seconds(60))
            self?.heartbeatReady = true
            while !Task.isCancelled {
                self?.reportHomeAccessIfChanged()
                self?.heartbeatIfDue()
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }

    // MARK: User properties

    static var platform: String {
        #if targetEnvironment(macCatalyst)
        "mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
    }

    /// The user properties as they are now. Names never: counts, switches
    /// and choices only.
    func currentProperties() -> [String: Any] {
        guard let recorder else { return [:] }
        var p = Self.userProperties(recorder: recorder, placesCount: placesCount(), defaults: defaults)
        #if !targetEnvironment(macCatalyst)
        p["widgets"] = defaults.stringArray(forKey: Keys.widgets) ?? []
        #if canImport(ActivityKit)
        p["live_activity_active"] = LiveAir.shared.isRunning
        #endif
        #endif
        return p
    }

    /// The part of the user properties that comes from settings (tests use
    /// this directly).
    static func userProperties(recorder: Recorder, placesCount: Int, defaults: UserDefaults) -> [String: Any] {
        var p: [String: Any] = [
            "platform": platform,
            "sensor_connected": !recorder.homeKit.sensors.isEmpty,
            "sensor_count": recorder.homeKit.sensors.count,
            "demo_on": recorder.useDemo,
            "sync_on": CloudSync.isEnabled,
            "chime_on": recorder.soundOn,
            "notifications_on": recorder.notifyOn,
            "airing_reminder_on": recorder.reminders.isOn,
            "co2_limit": Int(recorder.co2Limit.rounded()),
            "record_interval_min": recorder.intervalMinutes,
            "places_count": placesCount,
            "goals": (defaults.string(forKey: OnboardingKeys.airGoals) ?? "")
                .split(separator: ",").map(String.init).sorted(),
            "airing_habit": defaults.string(forKey: OnboardingKeys.airingHabit) ?? "none",
            "onboarding_completed": defaults.bool(forKey: OnboardingKeys.hasCompleted),
        ]
        #if targetEnvironment(macCatalyst)
        p["mac_mode"] = recorder.showInDock ? "dock" : "menu_bar"
        p["menu_bar_metrics"] = recorder.showInMenuBar ? recorder.menuBarMetrics.map(\.rawValue) : []
        #endif
        return p
    }

    /// Re-read the properties whenever an observed recorder setting changes.
    private func observeProperties() {
        withObservationTracking {
            _ = currentProperties()
        } onChange: {
            Task { @MainActor in
                UsageAnalytics.shared.refreshProperties()
                UsageAnalytics.shared.observeProperties()
            }
        }
        refreshProperties()
    }

    /// Send what changed since the last Identify, a moment later so a burst
    /// of changes is one Identify. Call after anything the observation can't
    /// see (iCloud switch, places, onboarding, Live Activity).
    func refreshProperties() {
        guard started else { return }
        pendingIdentify?.cancel()
        pendingIdentify = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let now = self.currentProperties()
            let sent = self.lastSent
            let changed = now.filter { sent[$0.key] != String(describing: $0.value) }
            guard !changed.isEmpty, Analytics.isEnabled else { return }
            Analytics.setUserProperties(changed)
            for (key, value) in changed { self.lastSent[key] = String(describing: value) }
        }
    }

    /// Sharing was turned back on: send the whole set again.
    func resendUserProperties() {
        lastSent = [:]
        refreshProperties()
    }

    private func placesCount() -> Int {
        (try? container?.mainContext.fetchCount(FetchDescriptor<Place>())) ?? 0
    }

    /// The installed widgets, as "kind.family" — at most once a day (iOS).
    private func refreshWidgets() {
        #if !targetEnvironment(macCatalyst)
        let gate = DailyGate(key: Keys.widgetsDay, defaults: defaults)
        guard gate.isDue(now: .now) else { return }
        WidgetCenter.shared.getCurrentConfigurations { result in
            guard case let .success(infos) = result else { return }
            let kinds = Array(Set(infos.map { "\($0.kind).\(String(describing: $0.family))" })).sorted()
            Task { @MainActor in
                UserDefaults.standard.set(kinds, forKey: Keys.widgets)
                gate.mark(now: .now)
                UsageAnalytics.shared.refreshProperties()
            }
        }
        #endif
    }

    // MARK: Lifecycle

    /// The app came to the front.
    func appBecameActive() {
        guard started else { return }
        refreshWidgets()
        refreshProperties()
        heartbeatIfDue()
    }

    // MARK: Daily heartbeat

    /// `daily_status`, at most once per calendar day per device, while the
    /// app is active (the Mac's menu-bar app always counts as active).
    func heartbeatIfDue(now: Date = .now) {
        guard started, heartbeatReady, Analytics.isEnabled, let recorder, let container else { return }
        #if !targetEnvironment(macCatalyst)
        guard UIApplication.shared.applicationState == .active else { return }
        #endif
        let gate = DailyGate(key: Keys.dailyStatus, defaults: defaults)
        guard gate.claim(now: now) else { return }
        // The last 24 hours, so a Mac that sends just after midnight still
        // says whether it recorded: what *this* device recorded from a real
        // sensor (demo readings and other devices' synced ones excluded).
        let since = now.addingTimeInterval(-24 * 3600)
        let demoName = DemoSensor.name
        let mine = recorder.originDeviceID
        let descriptor = FetchDescriptor<Reading>(
            predicate: #Predicate { $0.timestamp >= since && $0.sensorName != demoName })
        let rows = ((try? container.mainContext.fetch(descriptor)) ?? [])
            .filter { $0.originDeviceID == nil || $0.originDeviceID == mine }
        Analytics.track("daily_status", DailyStatus.properties(
            readingCount: rows.count, co2: rows.compactMap(\.co2),
            sensorConnected: !recorder.homeKit.sensors.isEmpty, placesCount: placesCount(),
            syncOn: CloudSync.isEnabled, demoOn: recorder.useDemo))
    }

    // MARK: Apple Home access

    /// `home_access_state`, once per launch and only when it changed since
    /// the last report.
    private var homeAccessChecked = false

    private func reportHomeAccessIfChanged() {
        guard !homeAccessChecked, Analytics.isEnabled, let recorder else { return }
        homeAccessChecked = true
        let state = recorder.homeKit.accessState
        guard defaults.string(forKey: Keys.homeAccess) != state else { return }
        defaults.set(state, forKey: Keys.homeAccess)
        Analytics.track("home_access_state", ["state": state])
    }

    // MARK: Navigation

    func tabViewed(_ tab: AppTab) {
        let name = switch tab {
        case .now: "now"
        case .history: "history"
        case .export: "export"
        case .settings: "settings"
        }
        Analytics.track("tab_viewed", ["tab": name])
        if tab == .settings {
            Analytics.track("settings_opened", ["via": pendingSettingsVia ?? "tab"])
        }
        pendingSettingsVia = nil
    }

    func historyViewed(range: ChartRange, metric: Metric) {
        Analytics.trackDebounced("history_viewed", ["range": range.rawValue, "metric": metric.rawValue])
    }

    // MARK: Mac menu bar

    /// The menu bar item's menu opened — sampled, once a day.
    func menuBarMenuOpened() {
        guard Analytics.isEnabled else { return }
        guard DailyGate(key: Keys.menuOpened, defaults: defaults).claim(now: .now) else { return }
        Analytics.track("menu_bar_menu_opened")
    }

    // MARK: Export

    private var lastExport: (key: String, at: Date)?

    /// One export, however many times the share sheet asks for the file.
    func exportPerformed(format: ExportFile.Kind, action: String, range: String) {
        let formatName = format == .csv ? "csv" : "markdown"
        let key = "\(formatName)|\(action)|\(range)"
        if let lastExport, lastExport.key == key, Date.now.timeIntervalSince(lastExport.at) < 5 { return }
        lastExport = (key, .now)
        Analytics.track("export_performed", ["format": formatName, "action": action, "range": range])
    }
}

/// granted / denied / not_determined, for `notifications_toggled`.
enum NotificationPermission {
    static func current() async -> String {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral: return "granted"
        case .denied: return "denied"
        case .notDetermined: return "not_determined"
        @unknown default: return "not_determined"
        }
    }
}
