import Foundation
import SwiftData
import WidgetKit

/// Hands each recorded reading to the widgets (via the App Group file) and,
/// when iCloud sync is on, to the user's other devices.
///
/// Widget reloads and iCloud uploads are throttled: every 5 minutes, or at
/// once when something the eye would notice changes (CO₂ level band, place).
@MainActor
final class WidgetFeed {
    static let shared = WidgetFeed()

    private var lastPushAt: Date = .distantPast
    private var lastLevel: CO2Level?
    private var lastPlace: String?

    func publish(co2: Double?, temperature: Double?, humidity: Double?, pm25: Double?,
                 measuredAt: Date, place: Place?, limit: Double, filter: SensorFilter,
                 isDemo: Bool, container: ModelContainer?, now: Date = .now) {
        var recent: [Double] = []
        if let container {
            let rows = (try? Exporter.fetchRows(container: container, since: now.addingTimeInterval(-3 * 3600), filter: filter)) ?? []
            recent = WidgetSnapshot.thin(rows.compactMap(\.co2), to: 36)
        }
        let snapshot = WidgetSnapshot(
            co2: co2, temperature: temperature, humidity: humidity, pm25: pm25,
            placeName: place?.displayName ?? "", placeKanji: place?.kanji ?? "",
            measuredAt: measuredAt, recentCO2: recent, limit: limit, isDemo: isDemo)
        try? snapshot.save()
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        LiveAir.shared.update(with: snapshot)
        #endif

        let level = co2.map(CO2Level.init(ppm:))
        let placeName = place?.displayName
        let due = now.timeIntervalSince(lastPushAt) >= 5 * 60 || level != lastLevel || placeName != lastPlace
        guard due else { return }
        lastPushAt = now
        lastLevel = level
        lastPlace = placeName
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
        Task.detached { await CloudSync.publish(snapshot) }
    }
}
