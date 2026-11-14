#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation

/// The Live Activity's data: one reading, where, and when it was measured.
/// Shared by the app (which starts and updates it) and the widget extension
/// (which draws it on the Lock Screen and in the Dynamic Island).
struct AirActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var co2: Double
        var temperature: Double?
        var humidity: Double?
        var placeName: String
        var placeKanji: String
        var measuredAt: Date
        var limit: Double
    }

    var startedAt: Date
}

extension AirActivityAttributes.ContentState {
    init?(_ s: WidgetSnapshot) {
        guard let co2 = s.co2 else { return nil }
        self.init(co2: co2, temperature: s.temperature, humidity: s.humidity,
                  placeName: s.placeName, placeKanji: s.placeKanji,
                  measuredAt: s.measuredAt, limit: s.limit)
    }
}
#endif
