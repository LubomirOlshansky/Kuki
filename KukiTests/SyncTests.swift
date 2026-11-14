import CloudKit
import Foundation
import SwiftData
import Testing
@testable import Kuki

// iCloud history sync. Nothing here creates a CKContainer or a CKSyncEngine:
// the logic (`SyncCore`, `HistoryStore`, the resolvers) runs against an
// in-memory store and a fake outbox. CKRecord values are built locally only.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000) // exactly UTC hour 500 000
private let hour0 = EpochHour.of(t0)
private let deviceA = "AAAAAAAA-0000-0000-0000-00000000000A"
private let deviceB = "BBBBBBBB-0000-0000-0000-00000000000B"

private func syncContainer() throws -> ModelContainer {
    try ModelContainer(for: Place.self, Reading.self,
                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
}

private func tempFiles() -> SyncFiles {
    SyncFiles(folder: FileManager.default.temporaryDirectory.appending(path: "kuki-sync-tests-\(UUID().uuidString)"))
}

private func syncDefaults() -> UserDefaults {
    let name = "kuki-sync-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func values(_ time: Date, co2: Double? = 800, place: UUID? = nil, placeName: String = "Hall",
                    settling: Bool = false, sensor: String = "ALPSTUGA") -> ReadingValues {
    ReadingValues(timestamp: time, co2: co2, temperature: 21.4, humidity: 48, pm25: 6,
                  placeID: place, placeName: placeName, settling: settling, sensorName: sensor)
}

private func insertReading(_ context: ModelContext, _ time: Date, sensor: String = "ALPSTUGA",
                           origin: String? = nil, place: UUID? = nil, placeName: String = "Hall") {
    context.insert(Reading(timestamp: time, co2: 700, temperature: 21, humidity: 50, pm25: 5,
                           placeID: place, placeName: placeName, settling: false,
                           sensorName: sensor, originDeviceID: origin))
}

@MainActor
private final class FakeOutbox: SyncOutbox {
    var saves: [SyncRecordName] = []
    func enqueueSaves(_ names: [SyncRecordName]) { saves += names }
    var chunkHours: [Int] { saves.compactMap { if case let .chunk(_, h) = $0 { h } else { nil } } }
}

/// A mutable clock for the core and the recorder.
@MainActor
private final class Clock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
private func makeCore(_ container: ModelContainer, device: String = deviceA, clock: Clock,
                      outbox: FakeOutbox?) -> SyncCore {
    let core = SyncCore(container: container, files: tempFiles(), deviceID: device, now: { clock.now })
    core.outbox = outbox
    return core
}

private func place(_ id: UUID = UUID(), _ name: String, modified: Date, created: Date = t0,
                   origin: String? = deviceB, deleted: Bool = false, mergedInto: UUID? = nil,
                   sortIndex: Int = 0) -> PlaceSnapshot {
    PlaceSnapshot(id: id, name: name, kanji: "", sortIndex: sortIndex, deleted: deleted, modifiedAt: modified,
                  createdAt: created, originDeviceID: origin, mergedInto: mergedInto)
}

// MARK: - Chunks

@Suite("Sync — hour chunks")
struct ChunkTests {
    @Test func payloadRoundTrips() throws {
        let start = EpochHour.start(hour0)
        let placeID = UUID()
        let readings = [
            values(start.addingTimeInterval(13.7), co2: 812, place: placeID, placeName: "Bedroom", settling: true),
            values(start.addingTimeInterval(75), co2: nil, placeName: "Bedroom"),
            values(start.addingTimeInterval(3599.9), co2: 1450.5, place: placeID, placeName: "Bed \"room\" 寝室",
                   sensor: "Other sensor"),
        ]
        let chunk = HourChunk(deviceID: deviceA, epochHour: hour0, sensorName: "ALPSTUGA", readings: readings)
        let decoded = try HourChunk.decode(deviceID: deviceA, epochHour: hour0, sensorName: "ALPSTUGA",
                                           payload: chunk.payload())
        #expect(decoded.readings.count == 3)
        for (a, b) in zip(readings, decoded.readings) {
            // Timestamps keep whole seconds (rounded down, so never a later minute).
            #expect(b.timestamp == Date(timeIntervalSince1970: a.timestamp.timeIntervalSince1970.rounded(.down)))
            #expect(EpochMinute.of(a.timestamp) == EpochMinute.of(b.timestamp))
            var a2 = a
            a2.timestamp = b.timestamp
            #expect(a2 == b)
        }
        #expect(decoded.readings[2].sensorName == "Other sensor", "a mid-hour sensor switch survives")
        #expect(try chunk.payload() == chunk.payload(), "stable bytes")
    }

    @Test func recordNameFormat() {
        let name = SyncRecordName.chunk(deviceID: deviceA, epochHour: 500_123)
        #expect(name.name == "h-\(deviceA)-500123")
        #expect(SyncRecordName(name.name) == name, "the device id's own dashes don't confuse parsing")
        let id = UUID()
        #expect(SyncRecordName.place(id).name == id.uuidString)
        #expect(SyncRecordName(id.uuidString) == .place(id))
        #expect(SyncRecordName("current-place") == .sensorState)
        #expect(SyncRecordName.sensorState.name == "current-place")
        #expect(SyncRecordName("h--12") == nil)
        #expect(SyncRecordName("h-abc-x") == nil)
        #expect(SyncRecordName("latest") == nil)
        #expect(HourChunk(deviceID: deviceB, epochHour: 7, sensorName: "", readings: []).recordName == "h-\(deviceB)-7")
        #expect(EpochHour.of(Date(timeIntervalSince1970: 7200 + 3599)) == 2)
        #expect(EpochHour.start(2) == Date(timeIntervalSince1970: 7200))
        // Places go first, then the sensor's place, then history oldest first.
        let sorted = [name, .sensorState, .chunk(deviceID: deviceA, epochHour: 3), .place(id)]
            .sorted { $0.sendRank < $1.sendRank }
        #expect(sorted == [.place(id), .sensorState, .chunk(deviceID: deviceA, epochHour: 3), name])
    }

    @Test func chunkRecordRoundTrip() throws {
        let start = EpochHour.start(hour0)
        let chunk = ChunkBuilder.chunk(deviceID: deviceB, epochHour: hour0,
                                       readings: [values(start.addingTimeInterval(60)), values(start.addingTimeInterval(120))])!
        let record = SyncRecords.newRecord(.chunk(deviceID: deviceB, epochHour: hour0), systemFields: nil)
        try SyncRecords.fill(record, with: chunk)
        #expect(record.recordType == "HourChunk")
        #expect(record.recordID.zoneID.zoneName == "KukiHistory")
        #expect(record["hourStart"] as? Date == start)
        #expect(SyncRecords.chunk(from: record) == chunk)
    }

    @Test func backfillGroupsByHour() {
        let start = EpochHour.start(hour0)
        let times = [start.addingTimeInterval(2 * 3600 + 5), start, start.addingTimeInterval(59 * 60),
                     start.addingTimeInterval(3600), start.addingTimeInterval(2 * 3600 + 3000)]
        #expect(ChunkBuilder.hours(times) == [hour0, hour0 + 1, hour0 + 2], "each hour once, oldest first")
        #expect(ChunkBuilder.hours([]) == [])
    }

    @Test func demoIsNeverInAChunk() {
        let start = EpochHour.start(hour0)
        #expect(ChunkBuilder.chunk(deviceID: deviceA, epochHour: hour0,
                                   readings: [values(start, sensor: DemoSensor.name)]) == nil)
        let mixed = ChunkBuilder.chunk(deviceID: deviceA, epochHour: hour0, readings: [
            values(start, sensor: DemoSensor.name), values(start.addingTimeInterval(60)),
            values(start.addingTimeInterval(3600)), // next hour: not in this chunk
        ])
        #expect(mixed?.readings.count == 1)
        #expect(mixed?.readings.allSatisfy { $0.sensorName != DemoSensor.name } == true)
        // Nor imported, should one ever arrive.
        let demoChunk = HourChunk(deviceID: deviceB, epochHour: hour0, sensorName: DemoSensor.name,
                                  readings: [values(start, sensor: DemoSensor.name)])
        #expect(ChunkImport.plan(demoChunk, existing: [], localDeviceID: deviceA).inserts.isEmpty)
    }
}

// MARK: - Import & dedupe

@Suite("Sync — import and dedupe")
struct ImportTests {
    @Test func sameMinuteFromOneDeviceIsKept() {
        let start = EpochHour.start(hour0)
        // A move records at once, so one device can log two readings in a minute.
        let chunk = HourChunk(deviceID: deviceB, epochHour: hour0, sensorName: "ALPSTUGA",
                              readings: [values(start.addingTimeInterval(1)), values(start.addingTimeInterval(50))])
        let plan = ChunkImport.plan(chunk, existing: [], localDeviceID: deviceA)
        #expect(plan.inserts.count == 2)
        #expect(plan.duplicates == 0)
    }

    @Test func otherSensorsSameMinuteAreNotDuplicates() {
        let start = EpochHour.start(hour0)
        let chunk = HourChunk(deviceID: deviceB, epochHour: hour0, sensorName: "Bedroom sensor",
                              readings: [values(start.addingTimeInterval(20), sensor: "Bedroom sensor")])
        let plan = ChunkImport.plan(chunk, existing: [.init(timestamp: start.addingTimeInterval(10),
                                                            sensorName: "ALPSTUGA", originDeviceID: nil)],
                                    localDeviceID: deviceA)
        #expect(plan.inserts.count == 1)
    }

    @MainActor @Test func dedupeAcrossDevicesAndReimport() async throws {
        let container = try syncContainer()
        let context = container.mainContext
        let start = EpochHour.start(hour0)
        insertReading(context, start.addingTimeInterval(13)) // recorded here, before sync existed
        try context.save()
        let store = HistoryStore(modelContainer: container)

        var chunk = HourChunk(deviceID: deviceB, epochHour: hour0, sensorName: "ALPSTUGA", readings: [
            values(start.addingTimeInterval(41)), // same minute as ours → ours is kept
            values(start.addingTimeInterval(90)),
        ])
        var result = await store.importChunk(chunk, localDeviceID: deviceA, aliases: [:])
        #expect(result == .init(inserted: 1, duplicates: 1))

        // The hour grew on device B and arrives again.
        chunk.readings.append(values(start.addingTimeInterval(130)))
        result = await store.importChunk(chunk, localDeviceID: deviceA, aliases: [:])
        #expect(result == .init(inserted: 1, duplicates: 2), "a re-import never duplicates")

        let all = try context.fetch(FetchDescriptor<Reading>(sortBy: [SortDescriptor(\.timestamp)]))
        #expect(all.count == 3)
        #expect(all.map(\.originDeviceID) == [nil, deviceB, deviceB])
        let minutes = all.map { "\($0.sensorName)|\(EpochMinute.of($0.timestamp))" }
        #expect(Set(minutes).count == minutes.count, "each (sensor, minute) once")

        // Our own chunk coming back (same device id) is ignored outright.
        let own = HourChunk(deviceID: deviceA, epochHour: hour0, sensorName: "ALPSTUGA",
                            readings: [values(start.addingTimeInterval(500))])
        #expect(await store.importChunk(own, localDeviceID: deviceA, aliases: [:]) == .init())
    }

    @MainActor @Test func importDoesNotEnqueueUploads() async throws {
        let container = try syncContainer()
        let clock = Clock(t0)
        let outbox = FakeOutbox()
        let core = makeCore(container, clock: clock, outbox: outbox)
        let start = EpochHour.start(hour0)
        let chunk = HourChunk(deviceID: deviceB, epochHour: hour0, sensorName: "ALPSTUGA",
                              readings: (0..<5).map { values(start.addingTimeInterval(Double($0) * 60 + 5)) })
        let record = SyncRecords.newRecord(.chunk(deviceID: deviceB, epochHour: hour0), systemFields: nil)
        try SyncRecords.fill(record, with: chunk)

        let summary = await core.applyFetched([record])
        #expect(summary.chunks == 1)
        #expect(summary.imported == 5)
        #expect(outbox.saves.isEmpty, "imports are never uploaded again")
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Reading>()) == 5)

        // And they're not this device's history either: a later backfill skips them.
        await core.enqueueCatchUp()
        #expect(outbox.chunkHours.isEmpty)
        #expect(await core.store.chunk(epochHour: hour0, deviceID: deviceA) == nil)
    }
}

// MARK: - Uploads

@Suite("Sync — uploads")
struct UploadTests {
    @MainActor @Test func demoIsNeverUploaded() async throws {
        let container = try syncContainer()
        let clock = Clock(t0)
        let outbox = FakeOutbox()
        let core = makeCore(container, clock: clock, outbox: outbox)
        core.noteRecorded(at: t0, sensorName: DemoSensor.name)
        #expect(outbox.saves.isEmpty)

        let context = container.mainContext
        insertReading(context, t0, sensor: DemoSensor.name)
        insertReading(context, t0.addingTimeInterval(3600), sensor: DemoSensor.name)
        try context.save()
        await core.enqueueCatchUp()
        #expect(outbox.chunkHours.isEmpty, "a backfill skips demo hours")
        #expect(await core.record(for: .chunk(deviceID: deviceA, epochHour: hour0)) == nil)
    }

    @MainActor @Test func currentHourIsThrottledAndClosedOnRollover() throws {
        let container = try syncContainer()
        let start = EpochHour.start(hour0)
        let clock = Clock(start.addingTimeInterval(60))
        let outbox = FakeOutbox()
        let core = makeCore(container, clock: clock, outbox: outbox)

        core.noteRecorded(at: clock.now, sensorName: "ALPSTUGA")
        #expect(outbox.chunkHours == [hour0], "first reading goes up at once")
        clock.now = start.addingTimeInterval(5 * 60)
        core.noteRecorded(at: clock.now, sensorName: "ALPSTUGA")
        #expect(outbox.chunkHours == [hour0], "then at most every 10 minutes")
        clock.now = start.addingTimeInterval(12 * 60)
        core.noteRecorded(at: clock.now, sensorName: "ALPSTUGA")
        #expect(outbox.chunkHours == [hour0, hour0])
        clock.now = start.addingTimeInterval(14 * 60)
        core.noteRecorded(at: clock.now, sensorName: "ALPSTUGA")
        clock.now = start.addingTimeInterval(61 * 60)
        core.noteRecorded(at: clock.now, sensorName: "ALPSTUGA")
        #expect(outbox.chunkHours == [hour0, hour0, hour0, hour0 + 1], "the finished hour is closed, the new one starts")
        core.flush()
        #expect(outbox.chunkHours.count == 4, "nothing new to flush")
    }

    @MainActor @Test func backfillEnqueuesOwnHoursOldestFirst() async throws {
        let container = try syncContainer()
        let context = container.mainContext
        let start = EpochHour.start(hour0)
        insertReading(context, start.addingTimeInterval(2 * 3600 + 10)) // pre-sync: ours
        insertReading(context, start.addingTimeInterval(10), origin: deviceA)
        insertReading(context, start.addingTimeInterval(70), origin: deviceA)
        insertReading(context, start.addingTimeInterval(3 * 3600), origin: deviceB) // imported: not ours
        try context.save()
        let clock = Clock(start.addingTimeInterval(4 * 3600))
        let outbox = FakeOutbox()
        let core = makeCore(container, clock: clock, outbox: outbox)
        await core.enqueueCatchUp()
        #expect(outbox.chunkHours == [hour0, hour0 + 2])
        #expect(core.ledger.backfillDone)

        // The chunk for an hour holds our two readings only.
        let record = await core.record(for: .chunk(deviceID: deviceA, epochHour: hour0))
        let chunk = record.flatMap(SyncRecords.chunk(from:))
        #expect(chunk?.readings.count == 2)
        #expect(chunk?.deviceID == deviceA)

        // A second start only catches up from the last active hour.
        outbox.saves = []
        await core.enqueueCatchUp()
        #expect(outbox.chunkHours.isEmpty)
    }
}

// MARK: - Places

@Suite("Sync — places")
struct PlaceSyncTests {
    @Test func resolverLastWriterWins() {
        let id = UUID()
        let local = place(id, "Bedroom", modified: t0, origin: nil)
        #expect(PlaceResolver.resolve(remote: place(id, "Sleeping", modified: t0.addingTimeInterval(1)),
                                      local: local, livePlaces: [local], localDeviceID: deviceA) == .applyRemote)
        #expect(PlaceResolver.resolve(remote: place(id, "Sleeping", modified: t0.addingTimeInterval(-1)),
                                      local: local, livePlaces: [local], localDeviceID: deviceA) == .keepLocal)
        #expect(PlaceResolver.resolve(remote: place(id, "Sleeping", modified: t0),
                                      local: local, livePlaces: [local], localDeviceID: deviceA) == .keepLocal,
                "a tie keeps what's here")
        #expect(PlaceResolver.resolve(remote: place(UUID(), "Gone", modified: t0, deleted: true),
                                      local: nil, livePlaces: [local], localDeviceID: deviceA) == .rememberTombstone)
    }

    @Test func resolverMergesTwinsSymmetrically() {
        let older = place(UUID(), "Living room", modified: t0, created: t0, origin: deviceA)
        let younger = place(UUID(), "living room ", modified: t0, created: t0.addingTimeInterval(500), origin: deviceB)
        // Device A sees B's younger twin; device B sees A's older one. Same answer: A's id.
        #expect(PlaceResolver.resolve(remote: younger, local: nil, livePlaces: [older], localDeviceID: deviceA)
                == .mergeIntoLocal(older.id))
        #expect(PlaceResolver.resolve(remote: older, local: nil, livePlaces: [younger], localDeviceID: deviceB)
                == .adoptRemote(replacing: younger.id))
        // Two same-named places made on one device are deliberate.
        let sibling = place(UUID(), "Living room", modified: t0, created: t0.addingTimeInterval(9), origin: deviceB)
        #expect(PlaceResolver.resolve(remote: sibling, local: nil, livePlaces: [younger], localDeviceID: deviceA) == .insert)
    }

    @MainActor @Test func lastWriterWinsAndTombstones() async throws {
        let container = try syncContainer()
        let context = container.mainContext
        let clock = Clock(t0)
        let outbox = FakeOutbox()
        let core = makeCore(container, clock: clock, outbox: outbox)
        let study = Place(name: "Study", kanji: "書斎", sortIndex: 2)
        context.insert(study)
        try context.save()
        core.placeEdited(study) // clocked at t0
        #expect(outbox.saves == [.place(study.id)])

        // An older rename from elsewhere loses.
        await core.applyRemotePlace(place(study.id, "Office", modified: t0.addingTimeInterval(-60), origin: deviceA))
        #expect(core.fetchPlace(study.id)?.name == "Study")
        #expect(outbox.saves.last == .place(study.id), "ours is newer: still due")

        // A newer one wins.
        await core.applyRemotePlace(place(study.id, "Office", modified: t0.addingTimeInterval(60), origin: deviceA, sortIndex: 5))
        #expect(core.fetchPlace(study.id)?.name == "Office")
        #expect(core.fetchPlace(study.id)?.sortIndex == 5)

        // A newer tombstone deletes it here too.
        await core.applyRemotePlace(place(study.id, "Office", modified: t0.addingTimeInterval(120), origin: deviceA, deleted: true))
        #expect(core.fetchPlace(study.id) == nil)
        #expect(core.ledger.places[study.id.uuidString]?.deleted == true)

        // A stale "still there" doesn't bring it back.
        await core.applyRemotePlace(place(study.id, "Office", modified: t0.addingTimeInterval(90), origin: deviceA))
        #expect(core.fetchPlace(study.id) == nil)

        // A local delete is a tombstone record, not a CloudKit delete.
        let hall = Place(name: "Hall")
        context.insert(hall)
        try context.save()
        clock.now = t0.addingTimeInterval(300)
        core.placeEdited(hall)
        core.placeDeleted(id: hall.id, name: hall.name, kanji: "", sortIndex: 0, createdAt: hall.createdAt)
        context.delete(hall)
        try context.save()
        let tomb = await core.record(for: .place(hall.id))
        #expect(tomb.flatMap(SyncRecords.place(from:))?.deleted == true)
        #expect(tomb?["originDeviceID"] as? String == deviceA)
    }

    @MainActor @Test func seededPlacesMergeByName() async throws {
        let container = try syncContainer()
        let context = container.mainContext
        let clock = Clock(t0)
        let recorder = Recorder(defaults: syncDefaults(), clock: { clock.now })
        recorder.configure(container: container) // seeds the four defaults; Living room is current
        let outbox = FakeOutbox()
        let core = makeCore(container, clock: clock, outbox: outbox)
        core.recorder = recorder
        let seeded = core.livePlaces()
        #expect(seeded.map(\.name) == Place.defaults.map(\.0))
        let livingHere = seeded[0]
        let bedroomHere = seeded[1]
        #expect(recorder.currentPlaceID == livingHere.id)
        // Some history recorded here in the living room, before sync.
        insertReading(context, t0.addingTimeInterval(-7200), place: livingHere.id, placeName: "Living room")
        try context.save()

        // Device B installed Kūki first: its Living room is older → we adopt its id.
        let livingThere = place(UUID(), "Living room", modified: t0.addingTimeInterval(-86_400),
                                created: livingHere.createdAt.addingTimeInterval(-86_400), origin: deviceB)
        await core.applyRemotePlace(livingThere)
        let living = core.livePlaces().filter { $0.name == "Living room" }
        #expect(living.map(\.id) == [livingThere.id], "one Living room, with the older id")
        #expect(recorder.currentPlaceID == livingThere.id, "the sensor stays put, under the merged id")
        let readings = try context.fetch(FetchDescriptor<Reading>())
        #expect(readings.allSatisfy { $0.placeID == livingThere.id }, "history follows the merge")
        #expect(outbox.saves.contains(.place(livingHere.id)), "our copy's tombstone goes up")
        #expect(outbox.chunkHours == [EpochHour.of(t0.addingTimeInterval(-7200))], "re-filed history goes up again")
        let tomb = await core.record(for: .place(livingHere.id)).flatMap(SyncRecords.place(from:))
        #expect(tomb?.deleted == true && tomb?.mergedInto == livingThere.id)

        // Device B's Bedroom is younger than ours → it joins ours; nothing inserted.
        let bedroomThere = place(UUID(), "Bedroom", modified: t0, created: bedroomHere.createdAt.addingTimeInterval(3600),
                                 origin: deviceB)
        await core.applyRemotePlace(bedroomThere)
        #expect(core.livePlaces().filter { $0.name == "Bedroom" }.map(\.id) == [bedroomHere.id])
        #expect(!outbox.saves.contains(.place(bedroomThere.id)), "its own device writes that tombstone")
        // …and B's readings filed under its Bedroom land under ours.
        let start = EpochHour.start(hour0)
        let chunk = HourChunk(deviceID: deviceB, epochHour: hour0, sensorName: "ALPSTUGA",
                              readings: [values(start.addingTimeInterval(30), place: bedroomThere.id, placeName: "Bedroom")])
        _ = await core.applyRemoteChunk(chunk)
        let imported = try context.fetch(FetchDescriptor<Reading>()).first { $0.originDeviceID == deviceB }
        #expect(imported?.placeID == bedroomHere.id)

        // A rename on B later doesn't merge anything (only first sight does).
        await core.applyRemotePlace(place(livingThere.id, "Bedroom", modified: t0.addingTimeInterval(10),
                                          created: livingThere.createdAt, origin: deviceB))
        #expect(core.livePlaces().filter { $0.name == "Bedroom" }.count == 2)
        #expect(core.livePlaces().count == 4)
    }

    @Test func placeRecordRoundTrip() {
        let p = place(UUID(), "台所 Kitchen", modified: t0, created: t0.addingTimeInterval(-10), origin: nil,
                      deleted: true, mergedInto: UUID(), sortIndex: 3)
        let record = SyncRecords.newRecord(.place(p.id), systemFields: nil)
        SyncRecords.fill(record, with: p, localDeviceID: deviceA)
        var expected = p
        expected.originDeviceID = deviceA // stored explicitly on the record
        #expect(SyncRecords.place(from: record) == expected)
    }
}

// MARK: - Sensor state

@Suite("Sync — sensor's place")
struct SensorStateSyncTests {
    @MainActor @Test func olderRemoteIsIgnoredNewerMovesTheSensor() throws {
        let container = try syncContainer()
        let clock = Clock(t0)
        let recorder = Recorder(defaults: syncDefaults(), clock: { clock.now })
        recorder.configure(container: container)
        recorder.settleMinutes = 10
        let outbox = FakeOutbox()
        let core = makeCore(container, clock: clock, outbox: outbox)
        core.recorder = recorder
        let places = core.livePlaces()
        recorder.move(to: places[1]) // at t0, here
        #expect(recorder.placeChangedAt == t0)

        core.applyRemoteState(RemoteSensorState(placeID: places[2].id, changedAt: t0.addingTimeInterval(-60)))
        #expect(recorder.currentPlaceID == places[1].id, "an older move elsewhere is ignored")
        #expect(outbox.saves == [.sensorState], "and ours, being newer, is sent")

        outbox.saves = []
        clock.now = t0.addingTimeInterval(120)
        core.applyRemoteState(RemoteSensorState(placeID: places[3].id, changedAt: t0.addingTimeInterval(60)))
        #expect(recorder.currentPlaceID == places[3].id)
        #expect(recorder.placeChangedAt == t0.addingTimeInterval(60))
        #expect(recorder.isSettling)
        #expect(recorder.settleRemaining == 540, "settling counts from the move on the other device")
        #expect(outbox.saves.isEmpty, "a remote move isn't sent back")
        #expect(SensorStateResolver.shouldApply(remote: t0, local: t0) == false)
    }

    @MainActor @Test func moveToAPlaceThatHasntArrivedWaits() async throws {
        let container = try syncContainer()
        let clock = Clock(t0)
        let recorder = Recorder(defaults: syncDefaults(), clock: { clock.now })
        recorder.configure(container: container)
        let core = makeCore(container, clock: clock, outbox: FakeOutbox())
        core.recorder = recorder
        let attic = UUID()
        core.applyRemoteState(RemoteSensorState(placeID: attic, changedAt: t0))
        #expect(recorder.currentPlaceID != attic)
        #expect(core.ledger.pendingRemoteState?.placeID == attic)
        await core.applyRemotePlace(place(attic, "Attic", modified: t0))
        core.applyPendingState()
        #expect(recorder.currentPlaceID == attic)
        #expect(core.ledger.pendingRemoteState == nil)
    }
}

// MARK: - Ledger

@Suite("Sync — ledger")
struct LedgerTests {
    @Test func roundTripsAndToleratesMissingKeys() throws {
        let files = tempFiles()
        var ledger = SyncLedger()
        ledger.aliases = ["a": "b"]
        ledger.backfillDone = true
        ledger.places["x"] = SyncLedger.PlaceMeta(modifiedAt: t0, createdAt: t0, originDeviceID: deviceB, name: "Hall")
        files.save(ledger)
        #expect(files.loadLedger() == ledger)
        // A ledger from another build, missing keys, still loads.
        let partial = try JSONDecoder().decode(SyncLedger.self, from: Data(#"{"aliases":{"a":"b"},"places":{"x":{"name":"Hall"}}}"#.utf8))
        #expect(partial.aliases == ["a": "b"])
        #expect(partial.places["x"]?.name == "Hall")
        #expect(!partial.backfillDone)
        // The device id is made once and kept.
        #expect(files.deviceID() == files.deviceID())
    }

    @Test func aliasesFollowChainsAndStopOnLoops() {
        let a = UUID(), b = UUID(), c = UUID()
        var ledger = SyncLedger()
        ledger.aliases = [a.uuidString: b.uuidString, b.uuidString: c.uuidString]
        #expect(ledger.resolve(a) == c)
        #expect(ledger.resolve(c) == c)
        ledger.aliases[c.uuidString] = a.uuidString // a loop must not hang
        _ = ledger.resolve(a)
    }
}
