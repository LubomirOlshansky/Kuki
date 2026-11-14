import Foundation
import SwiftData
import SwiftUI

/// A spot in the home where the sensor sits for a while.
@Model
final class Place {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Optional kanji shown beside the name (居間, 寝室 …).
    var kanji: String
    var createdAt: Date
    var sortIndex: Int

    init(name: String, kanji: String = "", sortIndex: Int = 0) {
        self.id = UUID()
        self.name = name
        self.kanji = kanji
        self.createdAt = .now
        self.sortIndex = sortIndex
    }

    static let defaults: [(String, String)] = [
        ("Living room", "居間"),
        ("Bedroom", "寝室"),
        ("Study", "書斎"),
        ("Kitchen", "台所"),
    ]
}

/// One logged sample. The place is stored by id *and* name so exports stay
/// readable even if a place is later renamed or deleted.
@Model
final class Reading {
    var timestamp: Date
    var co2: Double?
    var temperature: Double?
    var humidity: Double?
    var pm25: Double?
    var placeID: UUID?
    var placeName: String
    /// True for samples taken shortly after the sensor was moved — the CO₂
    /// cell needs several minutes to reflect a new room, so stats skip these.
    var settling: Bool
    var sensorName: String

    init(timestamp: Date, co2: Double?, temperature: Double?, humidity: Double?, pm25: Double?,
         placeID: UUID?, placeName: String, settling: Bool, sensorName: String) {
        self.timestamp = timestamp
        self.co2 = co2
        self.temperature = temperature
        self.humidity = humidity
        self.pm25 = pm25
        self.placeID = placeID
        self.placeName = placeName
        self.settling = settling
        self.sensorName = sensorName
    }
}

/// A live set of values from a sensor.
///
/// Freshness is tracked per value: `heardAt[metric]` is when that value last
/// came *from the sensor* — a HomeKit notification or a successful read. A
/// value HomeKit only had cached (from before the app started) has no date,
/// so it can be shown, but is never logged and never rings the chime.
struct SensorSnapshot: Equatable {
    var co2: Double?
    var temperature: Double?
    var humidity: Double?
    var pm25: Double?
    var heardAt: [Metric: Date] = [:]
    var isReachable = true
    /// When Kūki first saw this sensor — cached values get a short grace
    /// period from here before the sensor counts as out of reach.
    var firstSeen: Date = .now

    var hasAnyValue: Bool { co2 != nil || temperature != nil || humidity != nil || pm25 != nil }

    /// The most recent moment anything was heard from the sensor.
    var lastHeard: Date? { heardAt.values.max() }

    subscript(metric: Metric) -> Double? {
        get {
            switch metric {
            case .co2: co2
            case .temperature: temperature
            case .humidity: humidity
            case .pm25: pm25
            }
        }
        set {
            switch metric {
            case .co2: co2 = newValue
            case .temperature: temperature = newValue
            case .humidity: humidity = newValue
            case .pm25: pm25 = newValue
            }
        }
    }

    /// A value that is both present and recently heard from a reachable sensor.
    func isFresh(_ metric: Metric, now: Date) -> Bool {
        isReachable && self[metric] != nil && Freshness.isFresh(heardAt[metric], now: now)
    }

    /// Fresh value or nil — what alerts and recordings are allowed to use.
    func freshValue(_ metric: Metric, now: Date) -> Double? {
        isFresh(metric, now: now) ? self[metric] : nil
    }

    /// The sensor is out of reach: HomeKit says so, or nothing has been heard
    /// for `Freshness.maxAge` (cached-only values get `startupGrace`).
    func isStale(now: Date) -> Bool {
        guard isReachable else { return true }
        if let lastHeard { return now.timeIntervalSince(lastHeard) > Freshness.maxAge }
        return now.timeIntervalSince(firstSeen) > Freshness.startupGrace
    }

    /// Only the values fresh enough to log (stale ones become nil), or nil
    /// when there is nothing worth logging.
    func recordable(now: Date) -> SensorSnapshot? {
        guard isReachable else { return nil }
        var out = self
        for metric in Metric.allCases where !isFresh(metric, now: now) { out[metric] = nil }
        return out.hasAnyValue ? out : nil
    }
}

/// Whether to *say* the sensor is out of reach. Raw staleness flickers in
/// two harmless cases: right after the app returns from the background
/// (values aged while iOS had it frozen, and Apple Home briefly reports
/// accessories unreachable while it reconnects), and on momentary HomeKit
/// blips. So staleness must persist through a grace period — counted from
/// the later of "first seen stale" and "app came back" — before the UI calls
/// it out of reach. Recording and alerts don't use this: they still accept
/// only genuinely fresh values.
enum SensorConnection: Equatable { case live, catchingUp, outOfReach }

struct ReachJudge: Equatable {
    static let grace: TimeInterval = 30
    private(set) var staleSince: Date?
    private(set) var resumedAt: Date?

    mutating func appResumed(at now: Date) { resumedAt = now }

    mutating func evaluate(rawStale: Bool, now: Date) -> SensorConnection {
        guard rawStale else { staleSince = nil; return .live }
        let since = staleSince ?? now
        staleSince = since
        let start = max(since, resumedAt ?? .distantPast)
        return now.timeIntervalSince(start) < Self.grace ? .catchingUp : .outOfReach
    }
}

/// How old a value may be before Kūki stops trusting it.
enum Freshness {
    /// Ten minutes: a flat line drawn from an old value would lie.
    static let maxAge: TimeInterval = 10 * 60
    /// How long cached-only values may stand in while HomeKit answers.
    static let startupGrace: TimeInterval = 60

    static func isFresh(_ heard: Date?, now: Date) -> Bool {
        guard let heard else { return false }
        return now.timeIntervalSince(heard) <= maxAge
    }
}

/// When the next reading is due.
enum RecordSchedule {
    /// Ticks arrive every 15 s, slightly late; a little slack keeps a 5-minute
    /// interval at 5 minutes instead of 5¼.
    static let slack: TimeInterval = 2

    static func isDue(lastRecordedAt: Date?, intervalMinutes: Int, now: Date) -> Bool {
        guard let last = lastRecordedAt else { return true }
        let interval = Double(max(1, intervalMinutes)) * 60
        return now.timeIntervalSince(last) >= interval - slack
    }
}

/// The fūrin's conscience: ring once when CO₂ reaches the limit, stay quiet
/// until the air has clearly recovered (hysteresis at limit − 100), never
/// more than once per cooldown, never while the sensor is still settling
/// into a new room. Moving the sensor re-arms it.
struct AlertGate: Equatable, Codable {
    static let hysteresis: Double = 100
    static let cooldown: TimeInterval = 20 * 60

    private(set) var armed = true
    private(set) var lastAlertAt: Date?

    /// Feed the latest *fresh* CO₂ (nil when unknown or stale). Returns true
    /// when the chime should ring now.
    mutating func evaluate(co2: Double?, limit: Double, settling: Bool, now: Date) -> Bool {
        guard let co2 else { return false }
        if co2 < limit - Self.hysteresis { armed = true }
        guard co2 >= limit, armed, !settling else { return false }
        if let last = lastAlertAt, now.timeIntervalSince(last) < Self.cooldown { return false }
        armed = false
        lastAlertAt = now
        return true
    }

    /// The sensor was carried to a new room: judge that room afresh.
    mutating func rearm() { armed = true }
}

/// Which readings a view or export is about. Demo readings and real ones
/// never mix: with the demo sensor on you see only demo data, otherwise only
/// what real sensors recorded.
enum SensorFilter: Hashable, Sendable {
    case demoOnly
    case excludingDemo

    init(useDemo: Bool) { self = useDemo ? .demoOnly : .excludingDemo }

    func includes(sensorName: String) -> Bool {
        switch self {
        case .demoOnly: sensorName == DemoSensor.name
        case .excludingDemo: sensorName != DemoSensor.name
        }
    }
}

/// Which value a chart or stat is about.
enum Metric: String, CaseIterable, Identifiable, Sendable {
    case co2, temperature, humidity, pm25
    var id: String { rawValue }

    var title: String {
        switch self {
        case .co2: "CO₂"
        case .temperature: "Temp"
        case .humidity: "Humidity"
        case .pm25: "PM2.5"
        }
    }

    var kanji: String {
        switch self {
        case .co2: "炭"
        case .temperature: "温"
        case .humidity: "湿"
        case .pm25: "塵"
        }
    }

    var unit: String {
        switch self {
        case .co2: "ppm"
        case .temperature: "°C"
        case .humidity: "%"
        case .pm25: "µg/m³"
        }
    }

    /// SF Symbol for menus and compact places.
    var symbol: String {
        switch self {
        case .co2: "carbon.dioxide.cloud"
        case .temperature: "thermometer.medium"
        case .humidity: "humidity"
        case .pm25: "aqi.medium"
        }
    }

    /// Short form for the menu bar: "812", "21.4°", "48%", "6".
    func compact(_ v: Double?) -> String {
        guard v != nil else { return "—" }
        switch self {
        case .co2: return format(v)
        case .temperature: return format(v) + "°"
        case .humidity: return format(v) + "%"
        case .pm25: return format(v)
        }
    }

    var longTitle: String {
        switch self {
        case .co2: "Carbon dioxide (CO₂)"
        case .temperature: "Temperature"
        case .humidity: "Humidity"
        case .pm25: "Fine particles (PM2.5)"
        }
    }

    func value(of r: Reading) -> Double? {
        switch self {
        case .co2: r.co2
        case .temperature: r.temperature
        case .humidity: r.humidity
        case .pm25: r.pm25
        }
    }

    func value(of s: SensorSnapshot) -> Double? { s[self] }

    /// How VoiceOver should say the unit.
    var spokenUnit: String {
        switch self {
        case .co2: "parts per million"
        case .temperature: "degrees Celsius"
        case .humidity: "percent"
        case .pm25: "micrograms per cubic metre"
        }
    }

    /// "CO₂ 812 parts per million".
    func spoken(_ v: Double?) -> String {
        let name = self == .temperature ? "Temperature" : title
        guard v != nil else { return "\(name), no reading" }
        return "\(name) \(format(v)) \(spokenUnit)"
    }

    func format(_ v: Double?) -> String {
        guard let v else { return "—" }
        switch self {
        case .co2: return String(Int(v.rounded()))
        case .temperature: return String(format: "%.1f", v)
        case .humidity: return String(Int(v.rounded()))
        case .pm25: return String(Int(v.rounded()))
        }
    }
}
