import Foundation

/// The little parcel the app leaves for its widgets: the latest reading,
/// where the sensor is, and a short CO₂ trace. Widgets can't read HomeKit
/// themselves, so this file *is* their whole world.
///
/// Lives in an App Group container shared by the app and the widget
/// extension; plain JSON so either side can read it without SwiftData.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    var co2: Double?
    var temperature: Double?
    var humidity: Double?
    var pm25: Double?
    var placeName: String
    var placeKanji: String
    /// When the sensor last really reported (not when the file was written).
    var measuredAt: Date
    /// CO₂ over the last ~3 hours, oldest first, evenly spaced-ish.
    var recentCO2: [Double]
    var limit: Double
    var isDemo: Bool

    static let appGroup = "group.com.olshanskysoft.kuki"
    static let widgetKind = "KukiAir"
    /// After this long without a fresh reading the widget fades and says so.
    static let staleAfter: TimeInterval = 30 * 60

    func isStale(at date: Date = .now) -> Bool {
        date.timeIntervalSince(measuredAt) > Self.staleAfter
    }

    static var fileURL: URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? URL.applicationSupportDirectory.appending(path: "Kuki", directoryHint: .isDirectory)
        return base.appending(path: "widget-snapshot.json")
    }

    static func load(from url: URL = fileURL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    func save(to url: URL = Self.fileURL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Reduce a long series to at most `count` points by averaging buckets,
    /// so the widget's tiny line stays smooth and the file stays small.
    static func thin(_ values: [Double], to count: Int) -> [Double] {
        guard values.count > count, count > 0 else { return values }
        let size = Double(values.count) / Double(count)
        return (0..<count).map { i in
            let lo = Int(Double(i) * size)
            let hi = max(lo + 1, Int(Double(i + 1) * size))
            let slice = values[lo..<min(hi, values.count)]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    /// What the gallery and previews show before any real reading exists.
    static let placeholder = WidgetSnapshot(
        co2: 742, temperature: 21.4, humidity: 47, pm25: 6,
        placeName: "Living room", placeKanji: "居間", measuredAt: .now,
        recentCO2: [610, 630, 655, 690, 720, 760, 790, 810, 800, 770, 750, 742],
        limit: 1000, isDemo: false)
}
