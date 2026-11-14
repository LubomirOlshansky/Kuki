import Foundation
import SwiftData
import Testing
@testable import Kuki

private func freshDefaults() -> UserDefaults {
    let name = "kuki-analytics-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

/// Every key and string value in `properties`, flattened, for name checks.
private func everything(_ properties: [String: Any]) -> [String] {
    properties.flatMap { key, value -> [String] in
        if let list = value as? [String] { return [key] + list }
        return [key, "\(value)"]
    }
}

/// Installs a capturing sink (and isolated consent defaults) for one test,
/// and puts everything back afterwards. Synchronous tests on the main actor
/// can't interleave with other suites while it's installed.
@MainActor
private final class Capture {
    var events: [(name: String, properties: [String: Any])] = []
    var identifies: [[String: Any]] = []
    var enabledChanges: [Bool] = []
    private let saved: (Analytics.Sink?, Analytics.UserPropertiesSink?, ((Bool) -> Void)?, UserDefaults)

    init() {
        saved = (Analytics.sink, Analytics.userPropertiesSink, Analytics.enabledChanged, Analytics.defaults)
        Analytics.defaults = freshDefaults()
        Analytics.sink = { [unowned self] in events.append(($0, $1)) }
        Analytics.userPropertiesSink = { [unowned self] in identifies.append($0) }
        Analytics.enabledChanged = { [unowned self] in enabledChanges.append($0) }
    }

    func restore() {
        (Analytics.sink, Analytics.userPropertiesSink, Analytics.enabledChanged, Analytics.defaults) = saved
    }

    func named(_ name: String) -> [[String: Any]] { events.filter { $0.name == name }.map(\.properties) }
}

@MainActor
@Suite("Analytics — facade and consent", .serialized)
struct AnalyticsFacadeTests {
    @Test func sharingIsOnByDefault() {
        let c = Capture(); defer { c.restore() }
        #expect(Analytics.isEnabled)
        Analytics.track("tab_viewed", ["tab": "now"])
        #expect(c.named("tab_viewed").count == 1)
    }

    @Test func optingOutDropsEverythingAndOptingInResumes() {
        let c = Capture(); defer { c.restore() }
        Analytics.isEnabled = false
        #expect(c.enabledChanges == [false], "the SDK is told to opt out")
        #expect(Analytics.defaults.object(forKey: Analytics.enabledKey) as? Bool == false, "persisted")

        Analytics.track("tab_viewed", ["tab": "history"])
        Analytics.setUserProperties(["platform": "iphone"])
        OnboardingAnalytics.skipped(.breath, index: 2)
        #expect(c.events.isEmpty, "no events once off — not even a goodbye")
        #expect(c.identifies.isEmpty, "no user properties once off")

        Analytics.isEnabled = true
        #expect(c.enabledChanges == [false, true])
        Analytics.track("tab_viewed", ["tab": "now"])
        #expect(c.named("tab_viewed").count == 1)
    }

    @Test func settingTheSameValueDoesNotNotify() {
        let c = Capture(); defer { c.restore() }
        Analytics.isEnabled = true
        #expect(c.enabledChanges.isEmpty)
    }

    @Test func forbiddenKeysNeverReachTheSink() throws {
        let c = Capture(); defer { c.restore() }
        Analytics.track("place_added", [
            "places_count": 5, "name": "Anna's room", "place_name": "Anna's room",
            "sensor_name": "ALPSTUGA", "home": "Flat", "co2": 1234.0, "temperature": 21.5,
        ])
        Analytics.setUserProperties(["sensor_count": 1, "room": "Kitchen", "ppm": 900])
        let p = try #require(c.named("place_added").first)
        #expect(Set(p.keys) == ["places_count"])
        #expect(Set(c.identifies.first?.keys.map { $0 } ?? []) == ["sensor_count"])
        for props in c.events.map(\.properties) + c.identifies {
            #expect(Set(props.keys).isDisjoint(with: Analytics.forbiddenKeys))
        }
    }

    @Test func emptyUserPropertiesAreNotSent() {
        let c = Capture(); defer { c.restore() }
        Analytics.setUserProperties([:])
        #expect(c.identifies.isEmpty)
    }

    @Test func movingTheSensorSendsKeysNeverNames() throws {
        let c = Capture(); defer { c.restore() }
        let container = try ModelContainer(for: Place.self, Reading.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let recorder = Recorder(defaults: freshDefaults())
        recorder.configure(container: container)
        let context = container.mainContext
        let anna = Place(name: "Anna's room", sortIndex: 9)
        context.insert(anna)
        let bedroom = try #require(try context.fetch(FetchDescriptor<Place>()).first { $0.name == "Bedroom" })

        recorder.move(to: bedroom)
        recorder.move(to: anna, via: "menu_bar")
        let moves = c.named("place_moved")
        #expect(moves.count == 2)
        #expect(moves.first?["to"] as? String == "bedroom")
        #expect(moves.first?["from_kind"] as? String == "living_room")
        #expect(moves.first?["via"] as? String == "app")
        #expect(moves.last?["to"] as? String == "custom")
        #expect(moves.last?["via"] as? String == "menu_bar")
        #expect(!c.events.flatMap { everything($0.properties) }.contains { $0.contains("Anna") })
    }

    @Test func userPropertiesCarryNoNames() throws {
        let d = freshDefaults()
        d.set("sleep,focus", forKey: OnboardingKeys.airGoals)
        d.set("onceADay", forKey: OnboardingKeys.airingHabit)
        d.set(true, forKey: OnboardingKeys.hasCompleted)
        let recorder = Recorder(defaults: d)
        let p = UsageAnalytics.userProperties(recorder: recorder, placesCount: 4, defaults: d)
        #expect(p["goals"] as? [String] == ["focus", "sleep"])
        #expect(p["airing_habit"] as? String == "onceADay")
        #expect(p["onboarding_completed"] as? Bool == true)
        #expect(p["places_count"] as? Int == 4)
        #expect(p["co2_limit"] as? Int == 1000)
        #expect(p["record_interval_min"] as? Int == 1)
        #expect(["iphone", "ipad", "mac"].contains(p["platform"] as? String ?? ""))
        #expect(Set(p.keys).isDisjoint(with: Analytics.forbiddenKeys))
        // Only plain values: no Place, Reading or sensor objects slip in.
        for value in p.values {
            #expect(value is Bool || value is Int || value is String || value is [String])
        }
    }

    @Test func alertLevelsAreBuckets() {
        #expect(AnalyticsValues.alertLevel(ppm: 1050) == "getting_stale")
        #expect(AnalyticsValues.alertLevel(ppm: 1399) == "getting_stale")
        #expect(AnalyticsValues.alertLevel(ppm: 1400) == "stuffy")
        #expect(AnalyticsValues.levelName(.poor) == "stuffy")
        #expect(AnalyticsValues.levelName(.clear) == "clear")
    }

    @Test func onlyTheRealAppOutsideTestsReports() {
        #expect(AnalyticsConfig.shouldStart(bundleID: "com.olshanskysoft.kuki", runningTests: false))
        #expect(!AnalyticsConfig.shouldStart(bundleID: "com.someone.kuki", runningTests: false))
        #expect(!AnalyticsConfig.shouldStart(bundleID: nil, runningTests: false))
        #expect(!AnalyticsConfig.shouldStart(bundleID: "com.olshanskysoft.kuki", runningTests: true))
        #expect(AnalyticsConfig.isRunningTests)
        #expect(!AnalyticsConfig.shouldStart(), "never from the test host")
    }
}

@Suite("Analytics — daily heartbeat")
struct DailyHeartbeatTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        return c
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func oncePerCalendarDay() {
        let gate = DailyGate(key: "daily", defaults: freshDefaults(), calendar: calendar)
        #expect(gate.claim(now: at(14, 0, 5)), "the first look of the day sends")
        #expect(!gate.claim(now: at(14, 9)))
        #expect(!gate.claim(now: at(14, 23, 59)), "the Mac running all day still sends once")
        #expect(gate.claim(now: at(15, 0, 1)), "a new day sends again")
        #expect(!gate.claim(now: at(15, 12)))
    }

    @Test func survivesRelaunches() {
        let d = freshDefaults()
        #expect(DailyGate(key: "daily", defaults: d, calendar: calendar).claim(now: at(14, 8)))
        #expect(!DailyGate(key: "daily", defaults: d, calendar: calendar).claim(now: at(14, 20)))
    }

    @Test func isDueDoesNotClaim() {
        let gate = DailyGate(key: "daily", defaults: freshDefaults(), calendar: calendar)
        #expect(gate.isDue(now: at(14, 8)))
        #expect(gate.isDue(now: at(14, 9)))
        gate.mark(now: at(14, 9))
        #expect(!gate.isDue(now: at(14, 10)))
    }

    @Test func stampIsTheLocalDay() {
        #expect(DailyGate.stamp(at(14, 23, 30), calendar: calendar) == "2026-11-14")
        #expect(DailyGate.stamp(at(15, 0, 30), calendar: calendar) == "2026-11-15")
    }

    @Test func levelMostOfTheDay() {
        #expect(DailyStatus.levelMostOf([]) == "none")
        #expect(DailyStatus.levelMostOf([500, 600, 900]) == "clear")
        #expect(DailyStatus.levelMostOf([1100, 1200, 700]) == "stale")
        #expect(DailyStatus.levelMostOf([1500, 1600, 500]) == "stuffy")
        #expect(DailyStatus.levelMostOf([500, 1500]) == "stuffy", "a tie goes to the worse level")
    }

    @Test func heartbeatPropertiesAreCountsAndBuckets() {
        let p = DailyStatus.properties(readingCount: 1440, co2: [812, 905, 1210], sensorConnected: true,
                                       placesCount: 4, syncOn: false, demoOn: false)
        #expect(p["readings_today_count"] as? Int == 1440)
        #expect(p["level_most_of_today"] as? String == "fine")
        #expect(p["sensor_connected"] as? Bool == true)
        #expect(p["places_count"] as? Int == 4)
        #expect(p["sync_on"] as? Bool == false)
        #expect(Set(p.keys).isDisjoint(with: ["co2", "ppm", "value"]))
        #expect(!p.values.contains { "\($0)".contains("812") }, "no readings")
    }
}
