import Foundation
import SwiftData
import Testing
@testable import Kuki

// Which place History shows a reading under (merged places, places that
// haven't arrived, readings recorded with no place), and where its lines
// break. Pure functions, an in-memory store, and SyncCore with a temp folder.

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let mac = "AAAAAAAA-0000-0000-0000-00000000000A"
private let phone = "BBBBBBBB-0000-0000-0000-00000000000B"

private func at(_ minutes: Double, _ place: String, id: UUID?, origin: String? = nil, co2: Double = 700,
                sensor: String = "ALPSTUGA") -> Row {
    Row(time: start.addingTimeInterval(minutes * 60), place: place, placeID: id, co2: co2, temperature: 21,
        humidity: 50, pm25: 5, settling: false, sensor: sensor, origin: origin)
}

private func unplaced(_ minutes: Double, origin: String? = phone, sensor: String = "ALPSTUGA") -> Row {
    at(minutes, ReadingPlaces.unplacedName, id: nil, origin: origin, sensor: sensor)
}

@Suite("History — which place a reading is shown under")
struct ReadingPlacesTests {
    let living = UUID()
    var live: [UUID: String] { [living: "Living room"] }

    @Test func mergedAwayIdsFollowTheChainToTheSurvivor() {
        let a = UUID(), b = UUID()
        // The phone's first Living room (a) was merged into a second copy (b),
        // which was merged into ours — in either order of arrival.
        let book = PlaceBook(aliases: [a.uuidString: b.uuidString, b.uuidString: living.uuidString],
                             known: [a, b, living], localDeviceID: mac)
        let rows = ReadingPlaces.resolve([at(0, "Living room", id: a, origin: phone),
                                          at(1, "Living room", id: b, origin: phone)],
                                         liveNames: live, book: book)
        #expect(rows.allSatisfy { $0.placeID == living && $0.place == "Living room" })
        // A loop in the aliases never hangs.
        #expect(SyncLedger.follow(a, aliases: [a.uuidString: b.uuidString, b.uuidString: a.uuidString]) == b)
    }

    @Test func aPlaceThatHasNotArrivedShowsUnderItsTwin() {
        let theirs = UUID()
        let reading = at(0, "living room", id: theirs, origin: phone)
        // Not here yet: the name merge will pick our Living room, so History does already.
        let early = ReadingPlaces.resolve([reading], liveNames: live, book: PlaceBook(known: [living], localDeviceID: mac))
        #expect(early.map(\.placeID) == [living])
        // It arrives and merges: the alias says the same.
        let merged = PlaceBook(aliases: [theirs.uuidString: living.uuidString], known: [living, theirs], localDeviceID: mac)
        #expect(ReadingPlaces.resolve([reading], liveNames: live, book: merged).map(\.placeID) == [living])
        // It arrives as a place of its own (a deliberate second one): its own line.
        let own = PlaceBook(known: [living, theirs], origins: [theirs: phone], localDeviceID: mac)
        let separate = ReadingPlaces.resolve([reading], liveNames: [living: "Living room", theirs: "Living room"], book: own)
        #expect(separate.map(\.placeID) == [theirs])
    }

    @Test func noTwinFromTheReadingsOwnDevice() {
        // The phone made two Bedrooms on purpose; the second hasn't arrived.
        let first = UUID(), second = UUID()
        let book = PlaceBook(known: [first], origins: [first: phone], localDeviceID: mac)
        let rows = ReadingPlaces.resolve([at(0, "Bedroom", id: second, origin: phone)],
                                         liveNames: [first: "Bedroom"], book: book)
        #expect(rows.map(\.placeID) == [second])
    }

    @Test func aDeletedPlaceKeepsItsReadingsApart() {
        let attic = UUID(), newAttic = UUID()
        let book = PlaceBook(known: [attic, newAttic], localDeviceID: mac)
        let rows = ReadingPlaces.resolve([at(0, "Attic", id: attic, origin: phone), at(1, "Attic", id: attic)],
                                         liveNames: [newAttic: "Attic"], book: book)
        #expect(rows.allSatisfy { $0.placeID == attic && $0.place == "Attic" })
    }

    @Test func placelessReadingsBetweenAnotherDevicesTakeTheSensorsPlace() {
        // The Mac records most minutes in the living room; the phone, open
        // meanwhile, filled the minutes the Mac missed — with no place.
        var rows: [Row] = []
        for m in 0..<30 { rows.append(m % 3 == 0 ? unplaced(Double(m)) : at(Double(m), "Living room", id: living, origin: mac)) }
        let resolved = ReadingPlaces.resolve(rows, liveNames: live, book: PlaceBook(known: [living], localDeviceID: mac))
        #expect(resolved.allSatisfy { $0.placeID == living && $0.place == "Living room" })
        #expect(resolved.map(\.time) == rows.map(\.time), "order and readings untouched")
        #expect(PlaceStats.compute(resolved, limit: 1000).map(\.place) == ["Living room"])
    }

    @Test func placelessBetweenTwoReadingsOfOnePlaceGoesThere() {
        let bedroom = UUID()
        let names = [living: "Living room", bedroom: "Bedroom"]
        let book = PlaceBook(known: [living, bedroom], localDeviceID: mac)
        // Living room at 4 p.m. and at 9 p.m., the phone's placeless readings between.
        let bracketed = ReadingPlaces.resolve([at(0, "Living room", id: living), unplaced(195), unplaced(250),
                                               at(300, "Living room", id: living)], liveNames: names, book: book)
        #expect(bracketed.allSatisfy { $0.placeID == living })
        // Moved in between: only readings close to a side are placed.
        let moved = ReadingPlaces.resolve([at(0, "Living room", id: living), unplaced(5), unplaced(150), unplaced(295),
                                           at(300, "Bedroom", id: bedroom)], liveNames: names, book: book)
        #expect(moved.map(\.placeID) == [living, living, nil, bedroom, bedroom])
    }

    @Test func genuinelyPlacelessStaysUnplaced() {
        let book = PlaceBook(known: [living], localDeviceID: mac)
        // Nobody knew where the sensor was.
        let alone = ReadingPlaces.resolve((0..<5).map { unplaced(Double($0), origin: nil) }, liveNames: live, book: book)
        #expect(alone.allSatisfy { $0.placeID == nil && $0.place == ReadingPlaces.unplacedName })
        // Too far from the one placed reading, which is on one side only.
        let far = ReadingPlaces.resolve([at(0, "Living room", id: living), unplaced(16), unplaced(60)],
                                        liveNames: live, book: book)
        #expect(far.map(\.placeID) == [living, nil, nil])
        // Another sensor's place says nothing about this one.
        let other = ReadingPlaces.resolve([at(0, "Living room", id: living, sensor: "Other"), unplaced(1)],
                                          liveNames: live, book: book)
        #expect(other.map(\.placeID) == [living, nil])
        // A reading with no id but a real name keeps it.
        let named = ReadingPlaces.resolve([at(0, "Living room", id: living), at(1, "Hall", id: nil)],
                                          liveNames: live, book: book)
        #expect(named.last?.place == "Hall" && named.last?.placeID == nil)
    }

    @Test func thePhonesDayShowsAsOnePlace() throws {
        // The report from the Mac: Living room plus a spurious "Unplaced".
        let container = try ModelContainer(for: Place.self, Reading.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true,
                                                                              cloudKitDatabase: .none))
        let context = ModelContext(container)
        let here = Place(name: "Living room")
        context.insert(here)
        let phonesCopy = UUID() // the phone's seeded Living room, merged into ours
        let now = Date.now
        for m in 0..<20 {
            let t = now.addingTimeInterval(-Double(60 - m) * 60)
            let (id, name, origin): (UUID?, String, String?) = switch m % 4 {
            case 0: (nil, ReadingPlaces.unplacedName, phone) // recorded with no place
            case 1: (phonesCopy, "Living room", phone)      // under the merged-away id
            default: (here.id, "Living room", mac)          // the Mac's own
            }
            context.insert(Reading(timestamp: t, co2: 600, temperature: nil, humidity: nil, pm25: nil, placeID: id,
                                   placeName: name, settling: false, sensorName: "ALPSTUGA", originDeviceID: origin))
        }
        try context.save()
        let book = PlaceBook(aliases: [phonesCopy.uuidString: here.id.uuidString], known: [here.id, phonesCopy],
                             localDeviceID: mac)
        let since = now.addingTimeInterval(-2 * 3600)
        let rows = try Exporter.fetchRows(container: container, since: since, filter: .excludingDemo, book: book)
        #expect(rows.count == 20, "nothing lost")
        let stats = PlaceStats.compute(rows, limit: 1000)
        #expect(stats.map(\.place) == ["Living room"])
        #expect(stats.first?.samples == 20)
        let counts = try Exporter.counts(container: container, since: since, filter: .excludingDemo, book: book)
        #expect(counts.samples == 20 && counts.places == 1)
        // The store itself is untouched: the answer is worked out on reading.
        let stored = try context.fetch(FetchDescriptor<Reading>())
        #expect(stored.filter { $0.placeID == nil }.count == 5)
    }
}

@Suite("History chart — lines and gaps per place")
struct ChartGapTests {
    let living = UUID(), bedroom = UUID()

    @Test func interleavedPlacesDontChopEachOther() {
        var rows: [Row] = []
        for m in 0..<10 { rows.append(at(Double(m), m.isMultiple(of: 2) ? "Living room" : "Bedroom",
                                         id: m.isMultiple(of: 2) ? living : bedroom)) }
        let points = HistoryBody.segments(rows, gap: 3 * 60)
        #expect(Set(points.map(\.series)).count == 2, "one line per place")
        #expect(points.allSatisfy { !$0.isSingle })
        #expect(points.map(\.time) == rows.map(\.time), "still in time order")
    }

    @Test func aPauseBreaksTheLineAndOnlyThatPlaceIsBridged() {
        // 4 p.m. … quiet for five hours … 9 p.m., all in the living room.
        let rows = [at(0, "Living room", id: living), at(5, "Living room", id: living),
                    at(10, "Living room", id: living), at(300, "Living room", id: living)]
        let gap = HistoryBody.segmentGap(bucketMinutes: ChartRange.day.bucketMinutes, intervalMinutes: 1)
        let points = HistoryBody.segments(rows, gap: gap)
        #expect(points.map(\.segment) == [0, 0, 0, 1], "never one curve across the hours with no data")
        #expect(points.map(\.isSingle) == [false, false, false, true])
        let gaps = HistoryBody.gaps(points, threshold: gap)
        #expect(gaps.count == 1 && gaps[0].isBridged, "the dashed no-data bridge stands in for the line")

        // Between two places: a gap, but nothing drawn across.
        let moved = HistoryBody.segments([at(0, "Living room", id: living), at(5, "Living room", id: living),
                                          at(300, "Bedroom", id: bedroom)], gap: gap)
        let between = HistoryBody.gaps(moved, threshold: gap)
        #expect(between.count == 1 && !between[0].isBridged)
    }

    @Test func aPlaceElsewhereInTheMeantimeIsNotNoData() {
        let gap: TimeInterval = 15 * 60
        // Living room, then an hour in the bedroom, then back.
        var rows = [at(0, "Living room", id: living)]
        rows += stride(from: 5.0, through: 60, by: 5).map { at($0, "Bedroom", id: bedroom) }
        rows.append(at(65, "Living room", id: living))
        let points = HistoryBody.segments(rows, gap: gap)
        #expect(points.filter { $0.placeKey == rows[0].placeKey }.map(\.segment) == [0, 1], "its line breaks…")
        #expect(HistoryBody.gaps(points, threshold: gap).isEmpty, "…but nothing is labelled no data")
    }

    @Test("The gap suits the range", arguments: [(ChartRange.hours3, 1, 3.0), (.day, 1, 15), (.day, 10, 30),
                                                 (.week, 1, 90), (.month, 1, 360)])
    func gapSuitsTheRange(range: ChartRange, interval: Int, minutes: Double) {
        #expect(HistoryBody.segmentGap(bucketMinutes: range.bucketMinutes, intervalMinutes: interval) == minutes * 60)
    }

    @Test func loneReadingsAreDotsAndTheSeriesNamesAreText() {
        let rows = [at(0, "Living room", id: living), at(100, "Living room", id: living), at(200, "Bedroom", id: bedroom)]
        let points = HistoryBody.segments(rows, gap: 15 * 60)
        #expect(points.allSatisfy { $0.isSingle })
        #expect(Set(points.map(\.series)).count == 3)
        #expect(points.allSatisfy { $0.series.hasPrefix($0.placeKey + "#") })
    }
}

@Suite("Sync — merges and the sensor's place")
struct MergeFollowTests {
    private static func defaults() -> UserDefaults {
        let name = "kuki-merge-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private static func files() -> SyncFiles {
        SyncFiles(folder: FileManager.default.temporaryDirectory.appending(path: "kuki-merge-tests-\(UUID().uuidString)"))
    }

    private static func tombstone(_ id: UUID, _ name: String, into winner: UUID?, modified: Date) -> PlaceSnapshot {
        PlaceSnapshot(id: id, name: name, kanji: "", sortIndex: 0, deleted: true, modifiedAt: modified,
                      createdAt: start, originDeviceID: phone, mergedInto: winner)
    }

    @MainActor @Test func aMergeIntoAnAlreadyMergedPlaceGoesToTheEndOfTheChain() async throws {
        let container = try ModelContainer(for: Place.self, Reading.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true,
                                                                              cloudKitDatabase: .none))
        let context = container.mainContext
        let recorder = Recorder(defaults: Self.defaults(), clock: { start })
        recorder.configure(container: container)
        let core = SyncCore(container: container, files: Self.files(), deviceID: mac, now: { start })
        core.recorder = recorder
        let living = try #require(core.livePlaces().first { $0.name == "Living room" })

        // q was merged into our Living room; then p arrives, merged into q.
        let p = UUID(), q = UUID()
        await core.applyRemotePlace(Self.tombstone(q, "Living room", into: living.id, modified: start))
        context.insert(Reading(timestamp: start, co2: 700, temperature: nil, humidity: nil, pm25: nil, placeID: p,
                               placeName: "Living room", settling: false, sensorName: "ALPSTUGA", originDeviceID: phone))
        try context.save()
        recorder.applyRemoteMove(to: p, changedAt: start.addingTimeInterval(1))
        await core.applyRemotePlace(Self.tombstone(p, "Living room", into: q, modified: start))

        #expect(core.ledger.aliases[p.uuidString] == living.id.uuidString, "never an id that's gone")
        let reading = try #require(try context.fetch(FetchDescriptor<Reading>()).first)
        #expect(reading.placeID == living.id)
        #expect(recorder.currentPlaceID == living.id)
        #expect(recorder.currentPlace() != nil, "the sensor is somewhere that exists")
    }

    @MainActor @Test func aDeletionFromElsewhereNeverLeavesTheSensorNowhere() async throws {
        let container = try ModelContainer(for: Place.self, Reading.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true,
                                                                              cloudKitDatabase: .none))
        let recorder = Recorder(defaults: Self.defaults(), clock: { start })
        recorder.configure(container: container)
        let core = SyncCore(container: container, files: Self.files(), deviceID: mac, now: { start })
        core.recorder = recorder
        let current = try #require(recorder.currentPlace())
        // The phone deleted that place for real (no merge), later than it was made.
        await core.applyRemotePlace(PlaceSnapshot(
            id: current.id, name: current.name, kanji: "", sortIndex: 0, deleted: true,
            modifiedAt: current.createdAt.addingTimeInterval(60), createdAt: current.createdAt,
            originDeviceID: phone, mergedInto: nil))
        #expect(core.fetchPlace(current.id) == nil)
        // At once — not only at the end of the fetched batch, after its imports.
        #expect(recorder.currentPlace() != nil)
        #expect(recorder.currentPlaceID != current.id)
    }

    @MainActor @Test func aMergeBeforeTheRecorderAttachedIsFollowed() async throws {
        let container = try ModelContainer(for: Place.self, Reading.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true,
                                                                              cloudKitDatabase: .none))
        let recorder = Recorder(defaults: Self.defaults(), clock: { start })
        recorder.configure(container: container)
        let living = try #require(recorder.currentPlace())
        // A launch fetch, before any window: no recorder yet.
        let core = SyncCore(container: container, files: Self.files(), deviceID: mac, now: { start })
        let older = PlaceSnapshot(id: UUID(), name: "Living room", kanji: "", sortIndex: 0, deleted: false,
                                  modifiedAt: living.createdAt.addingTimeInterval(-86_400),
                                  createdAt: living.createdAt.addingTimeInterval(-86_400),
                                  originDeviceID: phone, mergedInto: nil)
        await core.applyRemotePlace(older) // ours joins the phone's older Living room
        #expect(core.fetchPlace(living.id) == nil)
        #expect(recorder.currentPlaceID == living.id, "nobody told the recorder")

        core.recorder = recorder
        #expect(core.followMerges())
        #expect(recorder.currentPlaceID == older.id, "the sensor stays put, under the merged id")
        #expect(!core.followMerges(), "once")
    }
}
