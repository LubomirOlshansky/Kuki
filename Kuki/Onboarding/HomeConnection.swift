import Foundation

/// 家 What the Apple Home screen shows — pure, so every timing is tested.
enum HomeConnectionState: Equatable {
    case notRequested
    case waiting
    case slow
    case denied
    case noHome
    case noSensor
    case found(SensorInfo, ppm: Double?, fresh: Bool)
    /// Found, no fresh reading yet, still inside the grace.
    case foundWaiting(SensorInfo)
    case unreachable(SensorInfo)
    case several([SensorInfo])

    var sensor: SensorInfo? {
        switch self {
        case .found(let s, _, _), .foundWaiting(let s), .unreachable(let s): s
        default: nil
        }
    }

    /// A short stable name, for announcements and animation keys.
    var kind: String {
        switch self {
        case .notRequested: "notRequested"
        case .waiting: "waiting"
        case .slow: "slow"
        case .denied: "denied"
        case .noHome: "noHome"
        case .noSensor: "noSensor"
        case .found(_, _, let fresh): fresh ? "found" : "foundCached"
        case .foundWaiting: "foundWaiting"
        case .unreachable: "unreachable"
        case .several: "several"
        }
    }
}

enum HomeConnection {
    /// Apple Home usually answers 5–15 s after launch.
    static let slowAfter: TimeInterval = 15
    static let readingGrace: TimeInterval = ReachJudge.grace
    /// Don't flash "none" while homes are still loading.
    static let emptyHold: TimeInterval = 3

    static func state(requested: Bool, requestedAt: Date?, status: HomeKitSource.Status,
                      statusSince: Date, sensors: [SensorInfo], snapshots: [UUID: SensorSnapshot],
                      chosen: UUID?, foundAt: Date?, now: Date,
                      slowFrom: Date? = nil) -> HomeConnectionState {
        guard requested else { return .notRequested }
        switch status {
        case .notAuthorized:
            return .denied
        case .starting:
            // "Check again" restarts this clock (`slowFrom`).
            let since = slowFrom ?? requestedAt ?? statusSince
            return now.timeIntervalSince(since) >= slowAfter ? .slow : .waiting
        case .noHomes, .noSensors:
            guard now.timeIntervalSince(statusSince) >= emptyHold else { return .waiting }
            return status == .noHomes ? .noHome : .noSensor
        case .ready:
            if sensors.count > 1 && (chosen == nil || !sensors.contains { $0.id == chosen }) {
                return .several(sensors)
            }
            guard let s = sensors.first(where: { $0.id == chosen }) ?? sensors.first else { return .noSensor }
            let snap = snapshots[s.id]
            let found = foundAt ?? now
            let after = requestedAt ?? .distantPast
            let graceOver = now.timeIntervalSince(found) >= readingGrace
            if snap?.isReachable == false, graceOver { return .unreachable(s) }
            if let snap {
                if let co2 = snap.freshValue(.co2, now: now), let heard = snap.heardAt[.co2], heard >= after {
                    return .found(s, ppm: co2, fresh: true)
                }
                // No CO₂ at all (PM2.5 or air-quality only): any fresh value counts.
                if snap.co2 == nil, snap.isReachable,
                   snap.heardAt.values.contains(where: { $0 >= after && Freshness.isFresh($0, now: now) }) {
                    return .found(s, ppm: nil, fresh: true)
                }
            }
            if !graceOver { return .foundWaiting(s) }
            return .found(s, ppm: snap?.co2, fresh: false)
        }
    }
}
