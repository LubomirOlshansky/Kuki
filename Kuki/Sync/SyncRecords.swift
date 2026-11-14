import CloudKit
import Foundation

/// CKRecord ↔ sync values. Building and reading records is local work — no
/// container, no network — so it is unit-tested too.
enum SyncRecords {
    /// A record to save: the last server copy's system fields (so CloudKit
    /// accepts it as an update), or a fresh record.
    static func newRecord(_ name: SyncRecordName, systemFields: Data?) -> CKRecord {
        if let systemFields, let coder = try? NSKeyedUnarchiver(forReadingFrom: systemFields) {
            coder.requiresSecureCoding = true
            let record = CKRecord(coder: coder)
            coder.finishDecoding()
            if let record, record.recordID.recordName == name.name { return record }
        }
        return CKRecord(recordType: name.recordType, recordID: name.recordID)
    }

    static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    // MARK: HourChunk

    static func fill(_ record: CKRecord, with chunk: HourChunk) throws {
        record[SyncSchema.ChunkField.deviceID] = chunk.deviceID
        record[SyncSchema.ChunkField.hourStart] = chunk.hourStart
        record[SyncSchema.ChunkField.sensorName] = chunk.sensorName
        record[SyncSchema.ChunkField.payload] = try chunk.payload()
    }

    static func chunk(from record: CKRecord) -> HourChunk? {
        guard record.recordType == SyncSchema.RecordType.hourChunk,
              case let .chunk(nameDevice, hour)? = SyncRecordName(record.recordID.recordName),
              let payload = record[SyncSchema.ChunkField.payload] as? Data else { return nil }
        let device = record[SyncSchema.ChunkField.deviceID] as? String ?? nameDevice
        let sensor = record[SyncSchema.ChunkField.sensorName] as? String ?? ""
        return try? HourChunk.decode(deviceID: device, epochHour: hour, sensorName: sensor, payload: payload)
    }

    // MARK: Place

    static func fill(_ record: CKRecord, with p: PlaceSnapshot, localDeviceID: String) {
        record[SyncSchema.PlaceField.name] = p.name
        record[SyncSchema.PlaceField.kanji] = p.kanji
        record[SyncSchema.PlaceField.sortIndex] = p.sortIndex
        record[SyncSchema.PlaceField.deleted] = p.deleted ? 1 : 0
        record[SyncSchema.PlaceField.modifiedAt] = p.modifiedAt
        record[SyncSchema.PlaceField.createdAt] = p.createdAt
        record[SyncSchema.PlaceField.originDeviceID] = p.originDeviceID ?? localDeviceID
        record[SyncSchema.PlaceField.mergedInto] = p.mergedInto?.uuidString
    }

    /// `originDeviceID` comes back as stored (never nil-mapped to "this
    /// device"): the caller compares it with its own id.
    static func place(from record: CKRecord) -> PlaceSnapshot? {
        guard record.recordType == SyncSchema.RecordType.place,
              case let .place(id)? = SyncRecordName(record.recordID.recordName) else { return nil }
        let modified = record[SyncSchema.PlaceField.modifiedAt] as? Date ?? .distantPast
        return PlaceSnapshot(
            id: id,
            name: record[SyncSchema.PlaceField.name] as? String ?? "",
            kanji: record[SyncSchema.PlaceField.kanji] as? String ?? "",
            sortIndex: (record[SyncSchema.PlaceField.sortIndex] as? Int) ?? 0,
            deleted: ((record[SyncSchema.PlaceField.deleted] as? Int) ?? 0) != 0,
            modifiedAt: modified,
            createdAt: record[SyncSchema.PlaceField.createdAt] as? Date ?? modified,
            originDeviceID: record[SyncSchema.PlaceField.originDeviceID] as? String,
            mergedInto: (record[SyncSchema.PlaceField.mergedInto] as? String).flatMap(UUID.init(uuidString:)))
    }

    // MARK: SensorState

    static func fill(_ record: CKRecord, with s: RemoteSensorState) {
        record[SyncSchema.StateField.currentPlaceID] = s.placeID.uuidString
        record[SyncSchema.StateField.placeChangedAt] = s.changedAt
    }

    static func state(from record: CKRecord) -> RemoteSensorState? {
        guard record.recordType == SyncSchema.RecordType.sensorState,
              let raw = record[SyncSchema.StateField.currentPlaceID] as? String,
              let id = UUID(uuidString: raw),
              let at = record[SyncSchema.StateField.placeChangedAt] as? Date else { return nil }
        return RemoteSensorState(placeID: id, changedAt: at)
    }
}
