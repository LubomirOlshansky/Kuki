import Foundation

/// A reading's values without SwiftData — what goes into (and comes out of)
/// an hour chunk.
struct ReadingValues: Equatable, Sendable {
    var timestamp: Date
    var co2: Double?
    var temperature: Double?
    var humidity: Double?
    var pm25: Double?
    var placeID: UUID?
    var placeName: String
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

    init(_ r: Reading) {
        self.init(timestamp: r.timestamp, co2: r.co2, temperature: r.temperature, humidity: r.humidity,
                  pm25: r.pm25, placeID: r.placeID, placeName: r.placeName, settling: r.settling,
                  sensorName: r.sensorName)
    }
}

/// One hour of one device's readings — the unit of history sync. ~60
/// readings at the 1-minute interval make a few kilobytes of compact JSON,
/// so a year is ~8 760 small records instead of ~525 000.
struct HourChunk: Equatable, Sendable {
    var deviceID: String
    var epochHour: Int
    /// The sensor most readings in this hour came from (each entry can name
    /// another, if the sensor was switched mid-hour).
    var sensorName: String
    var readings: [ReadingValues]

    var hourStart: Date { EpochHour.start(epochHour) }
    var recordName: String { SyncRecordName.chunk(deviceID: deviceID, epochHour: epochHour).name }

    /// The `payload` field. Format version 1:
    /// `{"v":1,"r":[{"t":<seconds into the hour>,"c":co2,"te":temp,"h":humidity,
    ///   "p":pm25,"pl":"<placeID>","n":"<placeName>","s":true (settling only),
    ///   "sn":"<sensor, only when not the chunk's>"}]}` — absent keys are nil.
    func payload() throws -> Data {
        let start = hourStart.timeIntervalSince1970
        let entries = readings.map { r in
            Entry(t: max(0, min(3599, Int((r.timestamp.timeIntervalSince1970 - start).rounded(.down)))),
                  c: r.co2, te: r.temperature, h: r.humidity, p: r.pm25,
                  pl: r.placeID?.uuidString, n: r.placeName, s: r.settling ? true : nil,
                  sn: r.sensorName == sensorName ? nil : r.sensorName)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys] // stable bytes for identical content
        return try encoder.encode(Payload(v: 1, r: entries))
    }

    static func decode(deviceID: String, epochHour: Int, sensorName: String, payload: Data) throws -> HourChunk {
        let decoded = try JSONDecoder().decode(Payload.self, from: payload)
        let start = EpochHour.start(epochHour)
        let readings = decoded.r.map { e in
            ReadingValues(timestamp: start.addingTimeInterval(Double(e.t)),
                          co2: e.c, temperature: e.te, humidity: e.h, pm25: e.p,
                          placeID: e.pl.flatMap(UUID.init(uuidString:)), placeName: e.n,
                          settling: e.s ?? false, sensorName: e.sn ?? sensorName)
        }
        return HourChunk(deviceID: deviceID, epochHour: epochHour, sensorName: sensorName, readings: readings)
    }

    private struct Payload: Codable {
        var v: Int
        var r: [Entry]
    }

    private struct Entry: Codable {
        var t: Int
        var c: Double?
        var te: Double?
        var h: Double?
        var p: Double?
        var pl: String?
        var n: String
        var s: Bool?
        var sn: String?
    }
}

enum ChunkBuilder {
    /// The hours that hold these readings, oldest first, each once — what a
    /// backfill enqueues.
    static func hours(_ timestamps: [Date]) -> [Int] {
        Array(Set(timestamps.map(EpochHour.of))).sorted()
    }

    /// This device's chunk for `epochHour`, or nil when the hour has nothing
    /// to share. Demo readings are never uploaded.
    static func chunk(deviceID: String, epochHour: Int, readings: [ReadingValues]) -> HourChunk? {
        let inHour = readings
            .filter { $0.sensorName != DemoSensor.name && EpochHour.of($0.timestamp) == epochHour }
            .sorted { $0.timestamp < $1.timestamp }
        guard !inHour.isEmpty else { return nil }
        let counts = Dictionary(grouping: inHour, by: \.sensorName).mapValues(\.count)
        let sensor = counts.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }!.key
        return HourChunk(deviceID: deviceID, epochHour: epochHour, sensorName: sensor, readings: inHour)
    }
}

/// Decides which readings of an incoming chunk to insert. Pure, so the rules
/// are tested without SwiftData or CloudKit.
///
/// Each (sensor, UTC minute) appears once across devices: when two devices
/// both recorded the same minute of the same sensor, the reading already
/// here is kept. A re-import of a chunk (its hour grew) skips what an
/// earlier import inserted — matched by origin device and timestamp.
enum ChunkImport {
    struct Existing: Equatable {
        var timestamp: Date
        var sensorName: String
        /// nil = this device's own (recorded before sync existed).
        var originDeviceID: String?
        var placeID: UUID?
    }

    struct Plan: Equatable {
        var inserts: [ReadingValues] = []
        /// Already here: an earlier import of this chunk, or another device's
        /// reading of the same minute.
        var duplicates = 0
        /// Earlier imports whose place changed at the origin (a place merge):
        /// index into `existing` → the new place.
        var placeUpdates: [Int: UUID] = [:]
    }

    static func plan(_ chunk: HourChunk, existing: [Existing], localDeviceID: String,
                     resolvePlace: (UUID) -> UUID = { $0 }) -> Plan {
        var plan = Plan()
        struct Key: Hashable { let sensor: String; let minute: Int }
        var byMinute: [Key: [(index: Int?, origin: String, time: TimeInterval)]] = [:]
        for (i, e) in existing.enumerated() {
            byMinute[Key(sensor: e.sensorName, minute: EpochMinute.of(e.timestamp)), default: []]
                .append((i, e.originDeviceID ?? localDeviceID, e.timestamp.timeIntervalSince1970))
        }
        let origin = chunk.deviceID
        for var r in chunk.readings where r.sensorName != DemoSensor.name {
            r.placeID = r.placeID.map(resolvePlace)
            let key = Key(sensor: r.sensorName, minute: EpochMinute.of(r.timestamp))
            let here = byMinute[key] ?? []
            let t = r.timestamp.timeIntervalSince1970
            if let same = here.first(where: { $0.origin == origin && abs($0.time - t) < 1 }) {
                plan.duplicates += 1
                if let index = same.index, let place = r.placeID, existing[index].placeID != place {
                    plan.placeUpdates[index] = place
                }
            } else if here.contains(where: { $0.origin != origin }) {
                plan.duplicates += 1
            } else {
                plan.inserts.append(r)
                byMinute[key, default: []].append((nil, origin, t))
            }
        }
        return plan
    }
}
