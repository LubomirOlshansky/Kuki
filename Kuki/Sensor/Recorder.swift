import Foundation
import Observation
import SwiftData
import UIKit
import UserNotifications
import os

/// The heart of the app: watches the sensor, writes a reading every interval
/// tagged with the place the sensor is in, and rings the fūrin when CO₂
/// crosses the limit.
@MainActor
@Observable
final class Recorder {
    let homeKit = HomeKitSource()
    /// Remembers which place the ensō last painted for, so its one
    /// orchestrated moment survives tab switches and window resizes.
    let ensoPaint = EnsoPaintMemory()
    /// The opt-in airing reminder (time-based local notifications).
    let reminders: AiringReminders

    // MARK: Settings (persisted)

    var co2Limit: Double { didSet { defaults.set(co2Limit, forKey: Keys.co2Limit) } }
    var soundOn: Bool { didSet { defaults.set(soundOn, forKey: Keys.soundOn) } }
    var notifyOn: Bool {
        didSet {
            defaults.set(notifyOn, forKey: Keys.notifyOn)
            if notifyOn, !oldValue { requestNotifications() }
        }
    }
    var intervalMinutes: Int { didSet { defaults.set(intervalMinutes, forKey: Keys.interval) } }
    var settleMinutes: Int { didSet { defaults.set(settleMinutes, forKey: Keys.settle) } }
    var useDemo: Bool {
        didSet {
            defaults.set(useDemo, forKey: Keys.demo)
            // Turning the demo off *is* asking for Apple Home: a contextual request.
            if !useDemo, context != nil { connectHomeKit() }
            lastRecordedAt = nil
            updateStaleness()
        }
    }
    /// What the Mac menu bar shows, in order. CO₂ by default.
    var menuBarMetrics: [Metric] {
        didSet { defaults.set(menuBarMetrics.map(\.rawValue).joined(separator: ","), forKey: Keys.menuBar) }
    }
    var showInMenuBar: Bool { didSet { defaults.set(showInMenuBar, forKey: Keys.showMenuBar) } }
    /// Mac: false (default) = a menu bar app with no Dock icon. Apple Home
    /// keeps answering a menu-bar-only app even when its window is closed or
    /// behind other apps, so Kūki records around the clock. With a Dock icon
    /// it's a normal app, and Apple Home pauses it whenever it isn't in front.
    var showInDock: Bool {
        didSet {
            defaults.set(showInDock, forKey: Keys.showInDock)
            if !showInDock { showInMenuBar = true } // otherwise there'd be no way back in
        }
    }
    var selectedSensorID: UUID? {
        didSet { defaults.set(selectedSensorID?.uuidString, forKey: Keys.sensor); updateStaleness() }
    }
    private(set) var currentPlaceID: UUID? { didSet { defaults.set(currentPlaceID?.uuidString, forKey: Keys.place) } }
    private(set) var placeChangedAt: Date { didSet { defaults.set(placeChangedAt, forKey: Keys.placeChangedAt) } }
    /// The user has asked Kūki to use Apple Home (the onboarding primer, or
    /// the demo turned off). Until then HomeKit is never touched, so its
    /// system prompt can't appear unexplained at first launch.
    private(set) var homeKitRequested: Bool {
        didSet { defaults.set(homeKitRequested, forKey: Keys.homeKitRequested) }
    }
    /// While the introduction is still choosing a sensor and a place, nothing
    /// is recorded and nothing rings. Not persisted.
    var holdRecording = false

    // MARK: Live state

    private(set) var demo: DemoSensor
    private(set) var lastRecordedAt: Date?
    /// True while the sensor is out of reach (or silent for 10 minutes):
    /// nothing is recorded, nothing rings, the UI says so.
    private(set) var isSensorStale = false
    /// Just back from the background (or a short HomeKit blip): showing the
    /// last values while Apple Home catches up, not yet "out of reach".
    private(set) var isCatchingUp = false
    /// The user asked for notifications but the system said no.
    private(set) var notificationsDenied = false
    var lastAlertAt: Date? { AlertGate.load(from: defaults).lastAlertAt }
    var stationMode = false {
        didSet {
            applyStationMode()
            if stationMode != oldValue { reportStationMode() }
        }
    }

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastRefreshAt: Date?
    @ObservationIgnored private var reach = ReachJudge()
    @ObservationIgnored private let reachLog = Logger(subsystem: "com.olshanskysoft.kuki", category: "reach")
    @ObservationIgnored private var recheck: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var recordingActivity: NSObjectProtocol?
    @ObservationIgnored private var stationActivity: NSObjectProtocol?
    @ObservationIgnored private var stationStartedAt: Date?
    /// The last notification-permission request, so Settings can report its
    /// answer (`notifications_toggled`).
    @ObservationIgnored private(set) var notificationRequest: Task<Bool, Never>?
    /// iCloud history sync, when it's running. Tests leave it nil.
    @ObservationIgnored weak var syncHooks: RecorderSyncHooks?
    /// This device's sync id, stamped on every reading (nil in tests).
    @ObservationIgnored var originDeviceID: String?

    private enum Keys {
        static let co2Limit = "co2Limit", soundOn = "soundOn", notifyOn = "notifyOn"
        static let interval = "intervalMinutes", settle = "settleMinutes", demo = "useDemo"
        static let sensor = "sensorID", place = "placeID", placeChangedAt = "placeChangedAt"
        static let seeded = "seededPlaces"
        static let menuBar = "menuBarMetrics", showMenuBar = "showInMenuBar", showInDock = "showInDock"
        static let homeKitRequested = OnboardingKeys.homeKitRequested
    }

    /// - Parameters:
    ///   - defaults: where settings live. Tests pass `UserDefaults(suiteName:)`.
    ///   - clock: the current time. Tests pass a controllable one.
    init(defaults d: UserDefaults = .standard, clock: @escaping () -> Date = { .now }) {
        // Before anything can seed places: an install with places predates
        // the introduction and skips it.
        OnboardingMigration.run(defaults: d)
        defaults = d
        self.clock = clock
        reminders = AiringReminders(defaults: d)
        d.register(defaults: [
            Keys.homeKitRequested: false,
            Keys.co2Limit: 1000.0, Keys.soundOn: true, Keys.notifyOn: false,
            Keys.interval: 1, Keys.settle: 10, Keys.demo: Self.isSimulator,
            Keys.menuBar: Metric.co2.rawValue, Keys.showMenuBar: true, Keys.showInDock: false,
        ])
        co2Limit = d.double(forKey: Keys.co2Limit)
        soundOn = d.bool(forKey: Keys.soundOn)
        notifyOn = d.bool(forKey: Keys.notifyOn)
        intervalMinutes = d.integer(forKey: Keys.interval)
        settleMinutes = d.integer(forKey: Keys.settle)
        useDemo = d.bool(forKey: Keys.demo)
        menuBarMetrics = Self.parseMetrics(d.string(forKey: Keys.menuBar))
        let dock = d.bool(forKey: Keys.showInDock)
        showInDock = dock
        // Without a Dock icon the menu bar item is the only way in.
        showInMenuBar = dock ? d.bool(forKey: Keys.showMenuBar) : true
        selectedSensorID = d.string(forKey: Keys.sensor).flatMap(UUID.init)
        currentPlaceID = d.string(forKey: Keys.place).flatMap(UUID.init)
        placeChangedAt = d.object(forKey: Keys.placeChangedAt) as? Date ?? .distantPast
        homeKitRequested = d.bool(forKey: Keys.homeKitRequested)
        demo = DemoSensor(now: clock())
        homeKit.onChange = { [weak self] in self?.updateStaleness() }
        reminders.placeName = { [weak self] in self?.currentPlace()?.name }
    }

    /// "co2,temperature" → [.co2, .temperature], in canonical order, unknown names dropped.
    nonisolated static func parseMetrics(_ raw: String?) -> [Metric] {
        let names = Set((raw ?? "").split(separator: ",").map(String.init))
        return Metric.allCases.filter { names.contains($0.rawValue) }
    }

    func setMenuBar(_ metric: Metric, shown: Bool) {
        var set = Set(menuBarMetrics)
        if shown { set.insert(metric) } else { set.remove(metric) }
        if set.isEmpty { set.insert(.co2) } // never an empty item; hide it with the toggle instead
        menuBarMetrics = Metric.allCases.filter { set.contains($0) }
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    // MARK: Derived

    var activeSensor: SensorInfo? {
        if let id = selectedSensorID, let s = homeKit.sensors.first(where: { $0.id == id }) { return s }
        return homeKit.sensors.first
    }

    /// The latest values, stale or not — check `isSensorStale` (or the
    /// snapshot's own dates) before trusting them.
    var current: SensorSnapshot? {
        if useDemo { return demo.snapshot }
        guard let id = activeSensor?.id, let s = homeKit.snapshots[id], s.hasAnyValue else { return nil }
        return s
    }

    /// The current values only while the sensor is live — what the menu bar
    /// shows.
    var live: SensorSnapshot? { isSensorStale ? nil : current }

    var sensorName: String {
        useDemo ? DemoSensor.name : (activeSensor?.name ?? "Sensor")
    }

    /// Which readings history, stats and exports should show.
    var sensorFilter: SensorFilter { SensorFilter(useDemo: useDemo) }

    var isSettling: Bool {
        clock().timeIntervalSince(placeChangedAt) < Double(settleMinutes) * 60
    }

    var settleRemaining: TimeInterval {
        max(0, Double(settleMinutes) * 60 - clock().timeIntervalSince(placeChangedAt))
    }

    // MARK: Lifecycle

    /// Attach the store and seed places — everything `start` does except
    /// talking to HomeKit and starting the loop (tests stop here).
    func configure(container: ModelContainer) {
        guard context == nil else { return }
        context = container.mainContext
        seedPlacesIfNeeded()
        ensureCurrentPlace()
    }

    func start(container: ModelContainer) {
        guard loop == nil else { return }
        configure(container: container)
        // HomeKit starts only when it's needed: a demo-only run (or a build
        // signed without the HomeKit entitlement) never touches Apple Home.
        if !useDemo && homeKitRequested { homeKit.start() }
        #if DEBUG
        // `-seedDemoOnLaunch YES` fills three days of demo history (UI checks).
        if defaults.bool(forKey: "seedDemoOnLaunch") { seedDemoHistory() }
        // `-stationOnLaunch YES` opens Station Mode at launch (crash repro / UI checks).
        if defaults.bool(forKey: "stationOnLaunch") { stationMode = true }
        #endif
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        if notifyOn { requestNotifications() }
        reminders.reschedule()
        #if targetEnvironment(macCatalyst)
        // Without this, App Nap throttles the 15-second loop to minutes as
        // soon as the window is hidden — and the log gets holes.
        recordingActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Recording air quality")
        #endif

        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Ask Apple Home (the onboarding primer's Continue, or the demo turned
    /// off). Idempotent.
    func connectHomeKit() {
        homeKitRequested = true
        if useDemo { useDemo = false } // the simulator defaults to the demo
        homeKit.start()
    }

    func tick() async {
        let now = clock()
        if useDemo {
            demo.step(now: now)
        } else if Self.mayReadHomeKit, lastRefreshAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            // Ask once a minute even if notifications are quiet: a successful
            // read is what keeps the values counted as fresh.
            lastRefreshAt = now
            DebugLog.write("tick", "refresh (app \(Self.appStateName))")
            reachLog.notice("tick: refresh (app \(Self.appStateName, privacy: .public))")
            await homeKit.refresh()
        }
        updateStaleness()
        if !holdRecording { checkAlert() }
        #if targetEnvironment(macCatalyst)
        MenuBarBridge.shared.refresh() // picks up added / renamed places
        #endif

        if !holdRecording, RecordSchedule.isDue(lastRecordedAt: lastRecordedAt, intervalMinutes: intervalMinutes, now: clock()) {
            record(current, at: clock())
        }
    }

    /// Not out of reach — Apple Home simply won't talk to a background app.
    var isPausedInBackground: Bool { !useDemo && homeKit.refusedInBackground }

    /// iOS refuses HomeKit reads from a background app ("Missing entitlement
    /// for API"), so don't ask then — the app reads again the moment it's in
    /// front (`appBecameActive`). The Mac app keeps reading in the background.
    static var mayReadHomeKit: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        UIApplication.shared.applicationState != .background
        #endif
    }

    static var appStateName: String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "?"
        }
    }

    func updateStaleness() {
        let now = clock()
        let raw = current.map { $0.isStale(now: now) } ?? false
        let state = reach.evaluate(rawStale: raw, now: now)
        let out = state == .outOfReach
        let catching = state == .catchingUp
        if out != isSensorStale || catching != isCatchingUp {
            let age = current?.lastHeard.map { Int(now.timeIntervalSince($0)) } ?? -1
            reachLog.notice("state → \(String(describing: state), privacy: .public) (raw stale: \(raw), last heard \(age) s ago)")
            DebugLog.write("reach", "state → \(state) (raw stale: \(raw), last heard \(age) s ago, app: \(Self.appStateName))")
        }
        if out != isSensorStale { isSensorStale = out }
        if catching != isCatchingUp { isCatchingUp = catching }
        // Decide promptly when the grace runs out, not at the next tick.
        recheck?.cancel()
        if catching {
            recheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(ReachJudge.grace + 1))
                guard !Task.isCancelled else { return }
                self?.updateStaleness()
            }
        }
    }

    /// The app is in front again (iOS froze it in the background): ask Apple
    /// Home right away instead of at the next minute, and give it a moment to
    /// answer before calling the sensor out of reach.
    func appBecameActive() {
        guard context != nil, !useDemo else { return }
        reach.appResumed(at: clock())
        let age = current?.lastHeard.map { Int(clock().timeIntervalSince($0)) } ?? -1
        reachLog.notice("app active — last heard \(age) s ago; asking Apple Home now")
        DebugLog.write("reach", "app active — last heard \(age) s ago; asking Apple Home now")
        updateStaleness()
        lastRefreshAt = clock()
        Task { [weak self] in
            await self?.homeKit.refresh()
            self?.updateStaleness()
        }
    }

    /// Log one reading — only values heard recently from a reachable sensor.
    /// Returns whether anything was written.
    @discardableResult
    func record(_ snapshot: SensorSnapshot?, at now: Date) -> Bool {
        guard let context, let values = snapshot?.recordable(now: now) else { return false }
        // Never a reading without a place: if the store lost them (or the
        // current one), seed / fall back to the first place first.
        let place = currentPlace() ?? {
            seedPlacesIfNeeded()
            ensureCurrentPlace()
            return currentPlace()
        }()
        context.insert(Reading(
            timestamp: now,
            co2: values.co2, temperature: values.temperature,
            humidity: values.humidity, pm25: values.pm25,
            placeID: place?.id, placeName: place?.name ?? ReadingPlaces.unplacedName,
            settling: isSettling, sensorName: sensorName, originDeviceID: originDeviceID
        ))
        try? context.save()
        lastRecordedAt = now
        syncHooks?.recorderDidRecord(at: now, sensorName: sensorName)
        WidgetFeed.shared.publish(
            co2: values.co2, temperature: values.temperature, humidity: values.humidity, pm25: values.pm25,
            measuredAt: snapshot?.lastHeard ?? now, place: place, limit: co2Limit,
            filter: sensorFilter, isDemo: useDemo, container: context.container, now: now)
        return true
    }

    // MARK: Places

    func currentPlace() -> Place? {
        guard let context, let id = currentPlaceID else { return nil }
        let descriptor = FetchDescriptor<Place>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    /// The sensor has been carried somewhere else. `via`: app / menu_bar,
    /// for analytics.
    func move(to place: Place, via: String = "app") {
        guard place.id != currentPlaceID else { return }
        Analytics.track("place_moved", [
            "to": OnboardingAnalytics.placeKey(place.name),
            "via": via,
            "from_kind": currentPlace().map { OnboardingAnalytics.placeKey($0.name) } ?? "none",
        ])
        currentPlaceID = place.id
        placeChangedAt = clock()
        updateAlertGate { $0.rearm() }
        lastRecordedAt = nil // log the new place right away
        syncHooks?.recorderDidMove(to: place.id, at: placeChangedAt)
        reminders.reschedule()
    }

    /// The introduction's answer to "Where is the sensor?" — like a move, but
    /// already settled: the sensor has presumably been sitting there.
    func setStartingPlace(_ id: UUID) {
        guard id != currentPlaceID else { return }
        currentPlaceID = id
        placeChangedAt = clock().addingTimeInterval(-Double(settleMinutes) * 60)
        updateAlertGate { $0.rearm() }
        lastRecordedAt = nil
        syncHooks?.recorderDidMove(to: id, at: placeChangedAt)
        reminders.reschedule()
    }

    func forgetPlace(_ place: Place) { forgetPlace(id: place.id) }

    func forgetPlace(id: UUID) {
        if currentPlaceID == id { currentPlaceID = nil }
    }

    /// A place was added, renamed or re-ordered (Places sheet).
    func placeEdited(_ place: Place) {
        syncHooks?.recorderDidEditPlace(place)
        if place.id == currentPlaceID { reminders.reschedule() } // a renamed room
    }

    /// A place is about to be deleted (Places sheet).
    func placeDeleted(_ place: Place) {
        forgetPlace(place)
        syncHooks?.recorderDidDeletePlace(place)
    }

    /// Another device moved the sensor, later than the last move here: follow
    /// it, with settling counted from *its* moment. Not sent back. Returns
    /// whether anything changed.
    @discardableResult
    func applyRemoteMove(to id: UUID, changedAt: Date) -> Bool {
        guard changedAt > placeChangedAt else { return false }
        let moved = id != currentPlaceID
        if moved {
            let from = currentPlace()
            let target = FetchDescriptor<Place>(predicate: #Predicate { $0.id == id })
            let to = try? context?.fetch(target).first
            Analytics.track("place_moved", [
                "to": OnboardingAnalytics.placeKey(to?.name),
                "via": "sync",
                "from_kind": from.map { OnboardingAnalytics.placeKey($0.name) } ?? "none",
            ])
        }
        currentPlaceID = id
        placeChangedAt = changedAt
        if moved {
            updateAlertGate { $0.rearm() }
            lastRecordedAt = nil
            reminders.reschedule()
        }
        return true
    }

    /// Two places turned out to be one (sync merge): follow the survivor
    /// without counting it as a move.
    func replacePlace(_ old: UUID, with new: UUID) {
        if currentPlaceID == old { currentPlaceID = new }
    }

    /// Places changed outside the Places sheet (sync).
    func placesDidChange() { ensureCurrentPlace() }

    private func seedPlacesIfNeeded() {
        // Seed whenever the store has no places at all — a fresh install, or
        // a new store location — not only on the very first launch.
        guard let context, ((try? context.fetchCount(FetchDescriptor<Place>())) ?? 0) == 0 else { return }
        for (i, item) in Place.defaults.enumerated() {
            context.insert(Place(name: item.0, kanji: item.1, sortIndex: i))
        }
        try? context.save()
        defaults.set(true, forKey: Keys.seeded)
        if let first = try? context.fetch(FetchDescriptor<Place>(sortBy: [SortDescriptor(\.sortIndex)])).first {
            currentPlaceID = first.id
            placeChangedAt = .distantPast
        }
    }

    /// The sensor is always *somewhere*: if no place is chosen (fresh store,
    /// or the chosen one was deleted), start with the first place.
    private func ensureCurrentPlace() {
        guard let context, currentPlace() == nil,
              let first = try? context.fetch(FetchDescriptor<Place>(sortBy: [SortDescriptor(\.sortIndex)])).first
        else { return }
        currentPlaceID = first.id
        placeChangedAt = .distantPast
    }

    func seedDemoHistory() {
        guard let context else { return }
        let places = (try? context.fetch(FetchDescriptor<Place>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
        DemoSensor.seedHistory(into: context, places: places)
    }

    func deleteReadings(demoOnly: Bool) {
        guard let context else { return }
        let demoName = DemoSensor.name
        if demoOnly {
            try? context.delete(model: Reading.self, where: #Predicate { $0.sensorName == demoName })
        } else {
            // Before they go: sync reads which hours to delete from iCloud.
            syncHooks?.recorderWillDeleteAllReadings()
            try? context.delete(model: Reading.self)
        }
        try? context.save()
    }

    // MARK: Alert

    private func checkAlert() {
        let now = clock()
        // Only a value actually heard from the sensor may ring the bell.
        let co2 = current?.freshValue(.co2, now: now)
        guard alertDue(co2: co2, now: now), let co2 else { return }
        // Once per spell (the gate): a level bucket and the limit, never the value.
        Analytics.track("co2_alert_fired", [
            "level": AnalyticsValues.alertLevel(ppm: co2),
            "via": "app",
            "limit": Int(co2Limit.rounded()),
        ])
        if soundOn { Chime.shared.ring() }
        if notifyOn { postNotification(co2: co2) }
    }

    /// Whether this fresh CO₂ value rings now. The gate is the one the
    /// cloud-wake alert uses too (`AlertGate.load`), kept in the defaults:
    /// a stuffy spell already announced by an iCloud wake-up — or before
    /// a relaunch — isn't announced again.
    func alertDue(co2: Double?, now: Date) -> Bool {
        updateAlertGate { $0.evaluate(co2: co2, limit: co2Limit, settling: isSettling, now: now) }
    }

    /// Read, change and (only if it changed) write the shared gate.
    private func updateAlertGate<T>(_ change: (inout AlertGate) -> T) -> T {
        let before = AlertGate.load(from: defaults)
        var gate = before
        let result = change(&gate)
        if gate != before { gate.save(to: defaults) }
        return result
    }

    func previewAlert() {
        Chime.shared.ring()
    }

    private func requestNotifications() {
        notificationRequest = Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            notificationsDenied = !granted
            // A switch that's on but can't do anything would be a lie.
            if !granted { notifyOn = false }
            return granted
        }
    }

    private func postNotification(co2: Double) {
        let content = UNMutableNotificationContent()
        let place = currentPlace()?.name ?? "The room"
        content.title = "\(place): \(Metric.co2.format(co2)) ppm CO₂"
        content.body = "Time to open a window for a few minutes."
        // The app rings the fūrin itself when the sound is on; the banner
        // then stays silent so the bell never sounds twice.
        content.sound = Furin.notificationSound(appRings: soundOn)
        let request = UNNotificationRequest(identifier: "co2-high", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Station mode

    private func reportStationMode() {
        if stationMode {
            stationStartedAt = clock()
            Analytics.track("station_mode_started")
        } else if let started = stationStartedAt {
            stationStartedAt = nil
            Analytics.track("station_mode_ended", ["minutes": Int((clock().timeIntervalSince(started) / 60).rounded())])
        }
    }

    /// Keeps the system *and the display* awake while the station shows.
    nonisolated static let stationActivityOptions: ProcessInfo.ActivityOptions =
        [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled]

    /// Keep the phone (or Mac) awake so recording never stops while you leave
    /// it in a room for hours.
    private func applyStationMode() {
        UIApplication.shared.isIdleTimerDisabled = stationMode
        #if targetEnvironment(macCatalyst)
        if stationMode, stationActivity == nil {
            // The display too, not just the system: a station is something
            // you look at.
            stationActivity = ProcessInfo.processInfo.beginActivity(
                options: Self.stationActivityOptions,
                reason: "Recording air quality in Station Mode")
        } else if !stationMode, let activity = stationActivity {
            ProcessInfo.processInfo.endActivity(activity)
            stationActivity = nil
        }
        // HIG › Going full screen: use the system's full screen, not a
        // window-sized cover.
        MenuBarBridge.shared.setFullScreen(stationMode)
        #endif
    }
}

/// Shows the CO₂ notification even while Kūki is in front — on a Mac the
/// window is often open on another Space.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        Furin.presentationOptions(appRings: UserDefaults.standard.bool(forKey: "soundOn"))
    }
}

/// One alert gate for the whole app: the in-app chime (`Recorder`) and the
/// iCloud wake-up alert (`CloudWake`) both read and write it, so one stuffy
/// spell rings once. Both run in the app, so the app's own defaults reach
/// both; it survives relaunches.
extension AlertGate {
    static let defaultsKey = "alertGate"
    /// Where the cloud-wake alert kept its own gate before they were shared.
    static let legacyCloudKey = "cloudAlertGate"

    static func load(from defaults: UserDefaults) -> AlertGate {
        let data = defaults.data(forKey: defaultsKey) ?? defaults.data(forKey: legacyCloudKey)
        return data.flatMap { try? JSONDecoder().decode(AlertGate.self, from: $0) } ?? AlertGate()
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// What the recorder tells iCloud history sync. Implemented by `HistorySync`.
@MainActor
protocol RecorderSyncHooks: AnyObject {
    func recorderDidRecord(at time: Date, sensorName: String)
    func recorderDidMove(to placeID: UUID, at time: Date)
    func recorderDidEditPlace(_ place: Place)
    func recorderDidDeletePlace(_ place: Place)
    /// "Delete all recordings", called just before the readings go.
    func recorderWillDeleteAllReadings()
}

extension Recorder: OnboardingSettingsSink {}
