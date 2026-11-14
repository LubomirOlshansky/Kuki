import Foundation

/// What sync knows about places, for deciding at read time which place a
/// reading is shown under: a snapshot of the `SyncLedger`. Empty when sync
/// never ran on this device (then only live places count).
struct PlaceBook: Sendable, Equatable {
    /// Merged-away id → the id it became (`SyncLedger.aliases`).
    var aliases: [String: String] = [:]
    /// Every place id sync has heard of — live, merged or deleted. An id
    /// outside this set (and not live) belongs to a place another device
    /// made that hasn't arrived here yet.
    var known: Set<UUID> = []
    /// Places that came from another device → that device.
    var origins: [UUID: String] = [:]
    /// This device's sync id: readings stamped with it are its own.
    var localDeviceID: String?

    static let empty = PlaceBook()

    init(aliases: [String: String] = [:], known: Set<UUID> = [], origins: [UUID: String] = [:],
         localDeviceID: String? = nil) {
        self.aliases = aliases
        self.known = known
        self.origins = origins
        self.localDeviceID = localDeviceID
    }

    init(ledger: SyncLedger, localDeviceID: String?) {
        aliases = ledger.aliases
        for (key, meta) in ledger.places {
            guard let id = UUID(uuidString: key) else { continue }
            known.insert(id)
            if let origin = meta.originDeviceID { origins[id] = origin }
        }
        for key in ledger.aliases.keys { if let id = UUID(uuidString: key) { known.insert(id) } }
        self.localDeviceID = localDeviceID
    }

    /// The book as sync last saved it. Reads only — never creates the sync
    /// folder or a device id. Empty under XCTest, so tests stay hermetic
    /// (they pass their own).
    static func stored(files: SyncFiles = .standard) -> PlaceBook {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let localID = files.existingDeviceID() else { return .empty }
        return PlaceBook(ledger: files.loadLedger(), localDeviceID: localID)
    }

    /// Where a place id lives on after merges (itself when never merged).
    func survivor(of id: UUID) -> UUID { SyncLedger.follow(id, aliases: aliases) }

    /// The device a reading came from — this one when it wasn't stamped.
    func device(of row: Row) -> String { row.origin ?? localDeviceID ?? "" }

    /// The device a live place came from — this one unless sync says otherwise.
    func device(ofPlace id: UUID) -> String { origins[id] ?? localDeviceID ?? "" }

    func isOwn(_ row: Row) -> Bool { row.origin == nil || row.origin == localDeviceID }
}

/// Which place each reading is shown under — in History, the widget's
/// trace and exports. Nothing in the store changes: the answer is worked out
/// every time the readings are read, so it heals by itself when a place
/// record arrives later, and nothing is lost if a rule is ever wrong.
///
/// 1. **By id.** A reading's place id is followed through merges
///    (`mergedInto` → alias chains) to the surviving live place.
/// 2. **A place that hasn't arrived yet.** Another device's reading whose id
///    is unknown here (no live place, no merge, no tombstone) and whose
///    stored name matches exactly one live place from a *different* device
///    is shown under that place — the same twin the name merge will pick
///    when the place record arrives.
/// 3. **No place at all.** A reading recorded with no place ("Unplaced") is
///    placed by the *same sensor's* placed readings around it — one sensor
///    is in one room at a time: under the nearer neighbour within
///    `nearby`, or under the place on both sides when they agree and are at
///    most `bracket` apart. With no such neighbour it stays "Unplaced".
///
/// A real deletion keeps its readings apart, under the name they had.
enum ReadingPlaces {
    /// How close a placed neighbour must be to place a placeless reading
    /// on its own — the same 15 minutes `PlaceStats` counts as "observed".
    static let nearby: TimeInterval = 15 * 60
    /// The longest stretch between two readings of the *same* place over
    /// which placeless readings are taken to be there too.
    static let bracket: TimeInterval = 12 * 3600
    /// What the recorder stores as the name of a reading taken with no
    /// place (`Recorder.record`). Only these are placed by rule 3 — a
    /// reading with no id but a real name keeps it.
    static let unplacedName = "Unplaced"

    static func isPlaceless(_ row: Row) -> Bool { row.placeID == nil && row.place == unplacedName }

    /// `rows` in time order (as `Exporter.fetchRows` reads them); the result
    /// keeps that order.
    static func resolve(_ rows: [Row], liveNames: [UUID: String], book: PlaceBook) -> [Row] {
        let byName = Dictionary(grouping: liveNames.keys, by: { PlaceResolver.normalized(liveNames[$0] ?? "") })
        var out = rows.map { file($0, liveNames: liveNames, byName: byName, book: book) }
        attributePlaceless(&out)
        return out
    }

    /// Rules 1 and 2: one reading, by its id.
    static func file(_ row: Row, liveNames: [UUID: String], byName: [String: [UUID]], book: PlaceBook) -> Row {
        guard let id = row.placeID else { return row }
        let survivor = book.survivor(of: id)
        if let name = liveNames[survivor] { return row.filed(under: survivor, name: name) }
        if survivor == id, !book.known.contains(id), !book.isOwn(row) {
            let origin = book.device(of: row)
            let twins = (byName[PlaceResolver.normalized(row.place)] ?? [])
                .filter { book.device(ofPlace: $0) != origin }
            if twins.count == 1, let twin = twins.first, let name = liveNames[twin] {
                return row.filed(under: twin, name: name)
            }
        }
        // Gone for good (or not here yet, with no twin): the stored name.
        return survivor == id ? row : row.filed(under: survivor, name: row.place)
    }

    /// Rule 3, in place. Per sensor, so two sensors never place each other.
    static func attributePlaceless(_ rows: inout [Row]) {
        guard rows.contains(where: isPlaceless) else { return }
        let bySensor = Dictionary(grouping: rows.indices, by: { rows[$0].sensor })
        for (_, indices) in bySensor {
            let order = indices.sorted { rows[$0].time < rows[$1].time }
            // The nearest placed reading before and after each position.
            var previous = [Int?](repeating: nil, count: order.count)
            var next = [Int?](repeating: nil, count: order.count)
            var last: Int?
            for (k, i) in order.enumerated() {
                previous[k] = last
                if rows[i].placeID != nil { last = i }
            }
            last = nil
            for (k, i) in order.enumerated().reversed() {
                next[k] = last
                if rows[i].placeID != nil { last = i }
            }
            var placed: [(Int, Row)] = []
            for (k, i) in order.enumerated() where isPlaceless(rows[i]) {
                if let source = neighbour(for: rows[i], before: previous[k].map { rows[$0] },
                                          after: next[k].map { rows[$0] }) {
                    placed.append((i, rows[i].filed(under: source.placeID, name: source.place)))
                }
            }
            // Written after the sweep: a placed-by-inference reading never
            // places another one.
            for (i, row) in placed { rows[i] = row }
        }
    }

    /// The placed reading a placeless one takes its place from, if any.
    static func neighbour(for row: Row, before: Row?, after: Row?) -> Row? {
        let gapBefore = before.map { row.time.timeIntervalSince($0.time) }
        let gapAfter = after.map { $0.time.timeIntervalSince(row.time) }
        if let before, let after, before.placeID == after.placeID,
           after.time.timeIntervalSince(before.time) <= bracket {
            return before
        }
        let nearBefore = gapBefore.map { $0 <= nearby } ?? false
        let nearAfter = gapAfter.map { $0 <= nearby } ?? false
        switch (nearBefore, nearAfter) {
        case (true, true): return (gapBefore ?? 0) <= (gapAfter ?? 0) ? before : after
        case (true, false): return before
        case (false, true): return after
        case (false, false): return nil
        }
    }
}
