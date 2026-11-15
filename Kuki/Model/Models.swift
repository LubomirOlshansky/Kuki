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

    /// The seeded names in the user's language, in the same order as
    /// `defaults` (which stays English: analytics and tests key off it).
    /// New places are seeded with these, so a German Mac starts with
    /// "Wohnzimmer", not "Living room".
    static var localizedDefaultNames: [String] {
        [
            String(localized: "Living room", comment: "Default room name seeded on first launch; also the sample room in the widget gallery preview."),
            String(localized: "Bedroom", comment: "Default room name seeded on first launch."),
            String(localized: "Study", comment: "Default room name seeded on first launch: a room for working or reading (home office)."),
            String(localized: "Kitchen", comment: "Default room name seeded on first launch."),
        ]
    }

    /// Index into `defaults` of a seeded name, in English or in the current
    /// language; nil for a name the user typed.
    static func seededIndex(_ name: String) -> Int? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        func same(_ a: String) -> Bool { a.compare(clean, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if let i = defaults.firstIndex(where: { same($0.0) }) { return i }
        return localizedDefaultNames.firstIndex(where: same)
    }

    /// Whether `name` is one of the seeded places. Those read as ordinary
    /// nouns and take "the" in a sentence ("the Bedroom"); a name the user
    /// typed ("Mum's room", "Office") is used bare.
    static func isSeeded(_ name: String) -> Bool { seededIndex(name) != nil }

    /// The name to show. A seeded place that is still untouched (`SeedNames`)
    /// reads in the user's language, whatever language it was made in: an
    /// install from before localization keeps "Living room" in its store, and
    /// a merge can leave a German "Wohnzimmer" on an English Mac. Display
    /// only — the stored name is what syncs, so it never churns between
    /// devices in different languages.
    var displayName: String { SeedNames.bundled.displayName(name: name, kanji: kanji) }

    /// Whether a typed or Apple Home room name is this place — by its stored
    /// name or the name it is shown by.
    func isNamed(_ other: String) -> Bool {
        let other = other.trimmingCharacters(in: .whitespacesAndNewlines)
        return [name, displayName].contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(other, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }
}

/// Which seeded place (index into `Place.defaults`) a place still is, in any
/// language. Two devices in different languages seed "Living room" and
/// "Wohnzimmer": different names, the same room. The kanji is the same
/// everywhere and syncs with the place, so it is the identity; the name
/// shows the user hasn't made the place their own.
///
/// **The rule:** a place is the seeded place *i* while its kanji is still
/// `Place.defaults[i]`'s kanji **and** its name is still one of seed *i*'s
/// names — English or any language the app ships. Renamed to anything else
/// ("Büro", "Mum's room"), or its kanji changed or cleared, it is the user's
/// own place: it merges by its exact name only, like any other. A kanji on
/// its own never makes two places one — a custom "Lounge" 居間 stays apart
/// from a seeded "Living room" 居間.
struct SeedNames: Sendable, Equatable {
    /// Per seed index: every name it may carry, normalized
    /// (`PlaceResolver.normalized`).
    let names: [Set<String>]

    /// `names[i]` are seed *i*'s names in any language; English is always
    /// added, so a table missing a language still knows the English seed.
    init(names: [[String]]) {
        self.names = Place.defaults.indices.map { i in
            Set(([Place.defaults[i].0] + (i < names.count ? names[i] : [])).map(PlaceResolver.normalized))
        }
    }

    /// English, the current language, and every language in the app bundle.
    /// Every device on the same build reads the same table, so the merge
    /// stays symmetric.
    static let bundled: SeedNames = {
        let english = Place.defaults.map(\.0)
        var table = Place.localizedDefaultNames.map { [$0] }
        for language in Bundle.main.localizations {
            guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { continue }
            for (i, key) in english.enumerated() {
                table[i].append(bundle.localizedString(forKey: key, value: key, table: nil))
            }
        }
        return SeedNames(names: table)
    }()

    /// The seed index a place still is, or nil for the user's own place.
    func identity(name: String, kanji: String) -> Int? {
        let kanji = kanji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kanji.isEmpty, let i = Place.defaults.firstIndex(where: { $0.1 == kanji }) else { return nil }
        return names[i].contains(PlaceResolver.normalized(name)) ? i : nil
    }

    /// The seed index a name alone points to, when exactly one seed has it —
    /// for a reading, which carries its place's name but not its kanji.
    func index(ofName name: String) -> Int? {
        let key = PlaceResolver.normalized(name)
        let hits = names.indices.filter { names[$0].contains(key) }
        return hits.count == 1 ? hits[0] : nil
    }

    /// The seeded place in the user's language, or `name` as it is.
    func displayName(name: String, kanji: String) -> String {
        guard let i = identity(name: name, kanji: kanji) else { return name }
        return Place.localizedDefaultNames[i]
    }
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
    /// Which device recorded this reading (iCloud sync). nil = recorded here
    /// before sync existed — treated as this device's own. Optional, so the
    /// store migrates lightweight.
    var originDeviceID: String?

    init(timestamp: Date, co2: Double?, temperature: Double?, humidity: Double?, pm25: Double?,
         placeID: UUID?, placeName: String, settling: Bool, sensorName: String, originDeviceID: String? = nil) {
        self.timestamp = timestamp
        self.co2 = co2
        self.temperature = temperature
        self.humidity = humidity
        self.pm25 = pm25
        self.placeID = placeID
        self.placeName = placeName
        self.settling = settling
        self.sensorName = sensorName
        self.originDeviceID = originDeviceID
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
        case .temperature: String(localized: "Temp", comment: "Short metric label for temperature (deliberately abbreviated): chart picker, stat chips, menu bar. Keep as short as possible.")
        case .humidity: String(localized: "Humidity", comment: "Short metric label: chart picker, stat chips, menu bar. Keep short.")
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
        guard let v else { return "—" }
        switch self {
        case .co2: return format(v)
        case .temperature: return format(v) + "°"
        // Locale-aware percent: "48%", "48 %" (fr), "%48" (tr).
        case .humidity: return (v.rounded() / 100).formatted(.percent.precision(.fractionLength(0)).grouping(.never))
        case .pm25: return format(v)
        }
    }

    var longTitle: String {
        switch self {
        case .co2: String(localized: "Carbon dioxide (CO₂)", comment: "Full metric name, e.g. in History and exports. Keep the formula CO₂.")
        case .temperature: String(localized: "Temperature", comment: "Full metric name, e.g. in History and exports.")
        case .humidity: String(localized: "Humidity", comment: "Short metric label: chart picker, stat chips, menu bar. Keep short.")
        case .pm25: String(localized: "Fine particles (PM2.5)", comment: "Full metric name for PM2.5 particulate matter, e.g. in History and exports. Keep PM2.5.")
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
        case .co2: String(localized: "parts per million", comment: "VoiceOver: the unit ppm spoken in full.")
        case .temperature: String(localized: "degrees Celsius", comment: "VoiceOver: the unit °C spoken in full.")
        case .humidity: String(localized: "percent", comment: "VoiceOver: the unit % spoken in full.")
        case .pm25: String(localized: "micrograms per cubic metre", comment: "VoiceOver: the unit µg/m³ spoken in full.")
        }
    }

    /// The metric's name as VoiceOver says it.
    private var spokenName: String {
        switch self {
        case .co2: String(localized: "CO₂", comment: "VoiceOver: the metric name carbon dioxide before a value. Keep CO₂ unless your language reads it differently.")
        case .temperature: String(localized: "Temperature", comment: "Full metric name, e.g. in History and exports.")
        case .humidity: String(localized: "Humidity", comment: "Short metric label: chart picker, stat chips, menu bar. Keep short.")
        case .pm25: "PM2.5"
        }
    }

    /// "CO₂ 812 parts per million".
    func spoken(_ v: Double?) -> String {
        let name = spokenName
        guard v != nil else {
            return String(localized: "\(name), no reading", comment: "VoiceOver: a metric with no value yet. %@ = metric name, e.g. CO₂ or Temperature.")
        }
        return String(localized: "spoken.metricReading", defaultValue: "\(name) \(format(v)) \(spokenUnit)", comment: "VoiceOver: a metric reading, e.g. 'CO₂ 812 parts per million'. %1$@ = metric name, %2$@ = number, %3$@ = unit spoken in full.")
    }

    func format(_ v: Double?) -> String {
        guard let v else { return "—" }
        // Localized digits, never grouped ("1234", not "1,234"): a reading,
        // not an amount. Machine-readable exports use their own formatting.
        switch self {
        case .co2, .humidity, .pm25: return Int(v.rounded()).formatted(.number.grouping(.never))
        case .temperature: return v.formatted(.number.precision(.fractionLength(1)).grouping(.never))
        }
    }
}
