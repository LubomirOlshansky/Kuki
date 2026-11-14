import Foundation
import SwiftData

/// History sync's hands in the SwiftData store, off the main actor: reads a
/// device's hours for upload, inserts imported readings, re-files readings
/// after a place merge. Views pick the changes up through the shared
/// container.
@ModelActor
actor HistoryStore {
    /// The hours that hold this device's own (non-demo) readings, oldest
    /// first — everything, or only from `sinceHour` on.
    func ownHours(deviceID: String, sinceHour: Int? = nil) -> [Int] {
        let demo = DemoSensor.name
        let since = sinceHour.map(EpochHour.start) ?? .distantPast
        var descriptor = FetchDescriptor<Reading>(predicate: #Predicate {
            $0.timestamp >= since && $0.sensorName != demo
                && ($0.originDeviceID == nil || $0.originDeviceID == deviceID)
        })
        descriptor.propertiesToFetch = [\.timestamp]
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        return ChunkBuilder.hours(rows.map(\.timestamp))
    }

    /// This device's chunk for one hour, or nil when there is nothing to send.
    func chunk(epochHour: Int, deviceID: String) -> HourChunk? {
        let readings = fetchHour(epochHour)
            .filter { $0.originDeviceID == nil || $0.originDeviceID == deviceID }
            .map(ReadingValues.init)
        return ChunkBuilder.chunk(deviceID: deviceID, epochHour: epochHour, readings: readings)
    }

    struct ImportResult: Equatable, Sendable {
        var inserted = 0
        var duplicates = 0
    }

    /// File another device's chunk into the store, skipping what is already
    /// here (see `ChunkImport`). Never touches this device's upload queue.
    func importChunk(_ chunk: HourChunk, localDeviceID: String, aliases: [String: String]) -> ImportResult {
        guard chunk.deviceID != localDeviceID else { return ImportResult() }
        let existing = fetchHour(chunk.epochHour)
        var ledger = SyncLedger()
        ledger.aliases = aliases
        let plan = ChunkImport.plan(
            chunk,
            existing: existing.map { .init(timestamp: $0.timestamp, sensorName: $0.sensorName,
                                           originDeviceID: $0.originDeviceID, placeID: $0.placeID) },
            localDeviceID: localDeviceID,
            resolvePlace: ledger.resolve)
        for r in plan.inserts {
            modelContext.insert(Reading(
                timestamp: r.timestamp, co2: r.co2, temperature: r.temperature, humidity: r.humidity,
                pm25: r.pm25, placeID: r.placeID, placeName: r.placeName, settling: r.settling,
                sensorName: r.sensorName, originDeviceID: chunk.deviceID))
        }
        for (index, place) in plan.placeUpdates { existing[index].placeID = place }
        if !plan.inserts.isEmpty || !plan.placeUpdates.isEmpty { try? modelContext.save() }
        return ImportResult(inserted: plan.inserts.count, duplicates: plan.duplicates)
    }

    /// A place merge: every reading filed under `from` moves to `to`.
    /// Returns the hours of this device's own readings that changed (they
    /// must be uploaded again so other devices follow).
    func refile(from: UUID, to: UUID, name: String, localDeviceID: String) -> [Int] {
        let optionalFrom: UUID? = from
        let descriptor = FetchDescriptor<Reading>(predicate: #Predicate { $0.placeID == optionalFrom })
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        guard !rows.isEmpty else { return [] }
        var ownTimes: [Date] = []
        let demo = DemoSensor.name
        for r in rows {
            r.placeID = to
            if !name.isEmpty { r.placeName = name }
            if (r.originDeviceID == nil || r.originDeviceID == localDeviceID) && r.sensorName != demo {
                ownTimes.append(r.timestamp)
            }
        }
        try? modelContext.save()
        return ChunkBuilder.hours(ownTimes)
    }

    private func fetchHour(_ hour: Int) -> [Reading] {
        let start = EpochHour.start(hour)
        let end = EpochHour.start(hour + 1)
        let descriptor = FetchDescriptor<Reading>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end },
            sortBy: [SortDescriptor(\.timestamp)])
        return (try? modelContext.fetch(descriptor)) ?? []
    }
}
