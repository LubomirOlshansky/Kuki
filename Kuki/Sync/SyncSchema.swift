import CloudKit
import Foundation

/// The CloudKit layout of history sync. One custom zone in the private
/// database holds three record types:
///
/// - `HourChunk` `h-<deviceID>-<epochHour>` — one hour of one device's
///   readings. Only the device that recorded them ever writes it.
/// - `Place` `<place UUID>` — a place, last writer (by `modifiedAt`) wins;
///   deletes are tombstones (`deleted = 1`) so offline devices learn them.
/// - `SensorState` `current-place` — where the sensor is, last writer (by
///   `placeChangedAt`) wins.
///
/// The latest-reading mailbox for widgets (`LatestAir`, default zone) is
/// separate and untouched — see Shared/CloudSync.swift.
enum SyncSchema {
    static let zoneName = "KukiHistory"
    static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

    enum RecordType {
        static let hourChunk = "HourChunk"
        static let place = "Place"
        static let sensorState = "SensorState"
    }

    enum ChunkField {
        static let deviceID = "deviceID"
        static let hourStart = "hourStart"
        static let sensorName = "sensorName"
        static let payload = "payload"
    }

    enum PlaceField {
        static let name = "name"
        static let kanji = "kanji"
        static let sortIndex = "sortIndex"
        static let deleted = "deleted"
        static let modifiedAt = "modifiedAt"
        static let createdAt = "createdAt"
        static let originDeviceID = "originDeviceID"
        static let mergedInto = "mergedInto"
    }

    enum StateField {
        static let currentPlaceID = "currentPlaceID"
        static let placeChangedAt = "placeChangedAt"
    }

    /// Throttle for re-saving the hour that is still filling up.
    static let currentHourResave: TimeInterval = 10 * 60
    /// Periodic fetch while the app runs (the Mac records around the clock
    /// and may not get every push).
    static let periodicFetch: TimeInterval = 15 * 60
}

/// What a record name in the KukiHistory zone stands for.
enum SyncRecordName: Equatable, Hashable {
    case chunk(deviceID: String, epochHour: Int)
    case place(UUID)
    case sensorState

    static let chunkPrefix = "h-"

    init?(_ name: String) {
        if name == SyncSchema.sensorStateName {
            self = .sensorState
        } else if name.hasPrefix(Self.chunkPrefix) {
            // h-<deviceID>-<epochHour>; the device id itself contains dashes.
            let body = name.dropFirst(Self.chunkPrefix.count)
            guard let dash = body.lastIndex(of: "-"),
                  let hour = Int(body[body.index(after: dash)...]) else { return nil }
            let device = String(body[..<dash])
            guard !device.isEmpty else { return nil }
            self = .chunk(deviceID: device, epochHour: hour)
        } else if let id = UUID(uuidString: name) {
            self = .place(id)
        } else {
            return nil
        }
    }

    var name: String {
        switch self {
        case let .chunk(device, hour): "\(Self.chunkPrefix)\(device)-\(hour)"
        case let .place(id): id.uuidString
        case .sensorState: SyncSchema.sensorStateName
        }
    }

    var recordType: String {
        switch self {
        case .chunk: SyncSchema.RecordType.hourChunk
        case .place: SyncSchema.RecordType.place
        case .sensorState: SyncSchema.RecordType.sensorState
        }
    }

    var recordID: CKRecord.ID { CKRecord.ID(recordName: name, zoneID: SyncSchema.zoneID) }

    /// Send order: places first (readings refer to them), then the sensor's
    /// place, then history oldest first.
    var sendRank: (Int, Int) {
        switch self {
        case .place: (0, 0)
        case .sensorState: (1, 0)
        case let .chunk(_, hour): (2, hour)
        }
    }
}

extension SyncSchema {
    static let sensorStateName = "current-place"
}

/// UTC hours since 1970 — the unit history is chunked in.
enum EpochHour {
    static func of(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / 3600).rounded(.down)) }
    static func start(_ hour: Int) -> Date { Date(timeIntervalSince1970: Double(hour) * 3600) }
}

/// UTC minutes since 1970 — the dedupe key across devices.
enum EpochMinute {
    static func of(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / 60).rounded(.down)) }
}
