import Foundation
import SwiftData

/// A pretend ALPSTUGA so the app can be tried (and designed) without a real
/// sensor — e.g. in the Simulator, which has no Apple Home.
struct DemoSensor {
    static let name = "Demo sensor"

    private(set) var snapshot: SensorSnapshot

    init(now: Date = .now) {
        snapshot = SensorSnapshot(co2: 620, temperature: 21.6, humidity: 48, pm25: 6,
                                  heardAt: Self.heard(at: now), firstSeen: now)
    }

    private static func heard(at date: Date) -> [Metric: Date] {
        Dictionary(uniqueKeysWithValues: Metric.allCases.map { ($0, date) })
    }

    /// Drift a little, like a room with someone breathing in it.
    mutating func step(now: Date = .now) {
        var s = snapshot
        let co2 = (s.co2 ?? 600) + Double.random(in: -14...22)
        s.co2 = min(max(co2, 430), 1900)
        s.temperature = min(max((s.temperature ?? 21.5) + Double.random(in: -0.05...0.05), 18), 26)
        s.humidity = min(max((s.humidity ?? 48) + Double.random(in: -0.4...0.4), 30), 70)
        s.pm25 = min(max((s.pm25 ?? 6) + Double.random(in: -0.8...0.8), 1), 40)
        s.heardAt = Self.heard(at: now)
        snapshot = s
    }

    /// Three days of plausible history across the default places, so the
    /// charts and the export have something to show straight away.
    static func seedHistory(into context: ModelContext, places: [Place]) {
        guard !places.isEmpty else { return }
        let now = Date.now
        let start = now.addingTimeInterval(-3 * 24 * 3600)
        var t = start
        var co2 = 600.0
        var temp = 21.0
        var hum = 47.0
        var pm = 6.0
        var placeIndex = 0
        var nextMove = t.addingTimeInterval(5 * 3600)
        var movedAt = t

        while t < now {
            if t >= nextMove {
                placeIndex = (placeIndex + 1) % places.count
                nextMove = t.addingTimeInterval(Double.random(in: 4...9) * 3600)
                movedAt = t
            }
            let place = places[placeIndex]
            let hour = Calendar.current.component(.hour, from: t)
            // Bedrooms climb overnight with the door shut; kitchens spike at meals.
            let target: Double = switch place.name {
            case "Bedroom": (hour >= 23 || hour < 7) ? 1450 : 700
            case "Kitchen": [8, 13, 19].contains(hour) ? 1100 : 650
            case "Study": (9..<18).contains(hour) ? 1050 : 600
            default: 750
            }
            co2 += (target - co2) * 0.04 + Double.random(in: -12...12)
            temp += ((place.name == "Bedroom" ? 19.5 : 21.8) - temp) * 0.03 + Double.random(in: -0.05...0.05)
            hum += ((place.name == "Kitchen" ? 56 : 46) - hum) * 0.03 + Double.random(in: -0.3...0.3)
            pm += ((place.name == "Kitchen" && [8, 13, 19].contains(hour) ? 22 : 5) - pm) * 0.06 + Double.random(in: -0.6...0.6)

            context.insert(Reading(
                timestamp: t, co2: co2.rounded(), temperature: (temp * 10).rounded() / 10,
                humidity: hum.rounded(), pm25: max(1, pm.rounded()),
                placeID: place.id, placeName: place.name,
                settling: t.timeIntervalSince(movedAt) < 600, sensorName: name
            ))
            t = t.addingTimeInterval(120)
        }
        try? context.save()
    }
}
