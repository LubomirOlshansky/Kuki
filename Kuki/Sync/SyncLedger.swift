import Foundation

/// What sync remembers between launches, besides the engine's own state:
/// per-place clocks and tombstones, place merges, the CloudKit system fields
/// needed to overwrite records, and upload progress.
///
/// Stored as JSON in Application Support/Kuki/Sync/ (excluded from backups:
/// restoring it onto a new device would make two devices one).
struct SyncLedger: Codable, Equatable {
    var places: [String: PlaceMeta] = [:]
    /// Merged-away place id → the id it became. Readings arriving later with
    /// the old id are filed under the new one.
    var aliases: [String: String] = [:]
    /// recordName → `encodeSystemFields` of the last server copy.
    var systemFields: [String: Data] = [:]
    var zoneSaved = false
    /// Every hour of this device's history has been enqueued once.
    var backfillDone = false
    /// The last hour this device recorded while sync was on — on restart,
    /// hours from here on are enqueued again (covers time spent switched off).
    var lastActiveHour: Int?
    var lastSyncAt: Date?
    /// A newer remote "sensor is in …" whose place hasn't arrived yet.
    var pendingRemoteState: RemoteSensorState?
    /// The current-place record has been sent (or received) at least once.
    var stateServerKnown = false
    /// `placeChangedAt` of the newest current-place the server is known to hold.
    var serverStateChangedAt: Date?
    /// Hours of this device's history whose iCloud copy is queued for
    /// deletion ("Delete all recordings"). The hour still filling up isn't
    /// saved again until its delete has gone through — one request can't
    /// save and delete the same record.
    var pendingChunkDeletes: Set<Int> = []

    struct PlaceMeta: Codable, Equatable {
        var modifiedAt: Date
        var createdAt: Date
        /// nil = this device.
        var originDeviceID: String?
        var deleted = false
        var mergedInto: String?
        /// The server has a copy (sent or fetched)…
        var serverKnown = false
        /// …with this clock. Ours is sent only while it's newer.
        var serverModifiedAt: Date?
        /// Kept for tombstones, whose Place is gone locally.
        var name = ""
        var kanji = ""
        var sortIndex = 0

        init(modifiedAt: Date, createdAt: Date, originDeviceID: String?, name: String = "",
             kanji: String = "", sortIndex: Int = 0) {
            self.modifiedAt = modifiedAt
            self.createdAt = createdAt
            self.originDeviceID = originDeviceID
            self.name = name
            self.kanji = kanji
            self.sortIndex = sortIndex
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? .distantPast
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? modifiedAt
            originDeviceID = try c.decodeIfPresent(String.self, forKey: .originDeviceID)
            deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
            mergedInto = try c.decodeIfPresent(String.self, forKey: .mergedInto)
            serverKnown = try c.decodeIfPresent(Bool.self, forKey: .serverKnown) ?? false
            serverModifiedAt = try c.decodeIfPresent(Date.self, forKey: .serverModifiedAt)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            kanji = try c.decodeIfPresent(String.self, forKey: .kanji) ?? ""
            sortIndex = try c.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0
        }
    }

    init() {}

    // Every key optional on the way in: a ledger written by an older (or
    // newer) build must never fail to load — that would forget merges.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        places = try c.decodeIfPresent([String: PlaceMeta].self, forKey: .places) ?? [:]
        aliases = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
        systemFields = try c.decodeIfPresent([String: Data].self, forKey: .systemFields) ?? [:]
        zoneSaved = try c.decodeIfPresent(Bool.self, forKey: .zoneSaved) ?? false
        backfillDone = try c.decodeIfPresent(Bool.self, forKey: .backfillDone) ?? false
        lastActiveHour = try c.decodeIfPresent(Int.self, forKey: .lastActiveHour)
        lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        pendingRemoteState = try c.decodeIfPresent(RemoteSensorState.self, forKey: .pendingRemoteState)
        stateServerKnown = try c.decodeIfPresent(Bool.self, forKey: .stateServerKnown) ?? false
        serverStateChangedAt = try c.decodeIfPresent(Date.self, forKey: .serverStateChangedAt)
        pendingChunkDeletes = try c.decodeIfPresent(Set<Int>.self, forKey: .pendingChunkDeletes) ?? []
    }

    /// Follow merges to the place an id lives on as.
    func resolve(_ id: UUID) -> UUID { Self.follow(id, aliases: aliases) }

    /// Follow a chain of merges (A → B → C) to its end. Cycle-safe: a loop
    /// stops at the last id before it would repeat.
    static func follow(_ id: UUID, aliases: [String: String]) -> UUID {
        var current = id.uuidString
        var seen: Set<String> = [current]
        while let next = aliases[current], !seen.contains(next) {
            seen.insert(next)
            current = next
        }
        return UUID(uuidString: current) ?? id
    }

    /// Forget everything the server told us (account switch, zone deleted):
    /// the next start uploads this device's data afresh. Local merges
    /// (aliases) and place clocks are kept.
    mutating func resetServerKnowledge() {
        systemFields = [:]
        zoneSaved = false
        backfillDone = false
        stateServerKnown = false
        serverStateChangedAt = nil
        pendingRemoteState = nil
        pendingChunkDeletes = [] // the zone (or the engine's queue) is gone with them
        for key in places.keys {
            places[key]?.serverKnown = false
            places[key]?.serverModifiedAt = nil
        }
    }

    /// Chunk system fields are only worth keeping for hours that may still be
    /// re-saved; older ones are recovered from a conflict if ever needed.
    mutating func pruneChunkFields(currentHour: Int, keepHours: Int = 3) {
        systemFields = systemFields.filter { name, _ in
            guard case let .chunk(_, hour)? = SyncRecordName(name) else { return true }
            return hour >= currentHour - keepHours
        }
    }
}

struct RemoteSensorState: Codable, Equatable, Sendable {
    var placeID: UUID
    var changedAt: Date
}

/// A place as both sides of a merge see it.
struct PlaceSnapshot: Equatable, Sendable {
    var id: UUID
    var name: String
    var kanji: String
    var sortIndex: Int
    var deleted: Bool
    var modifiedAt: Date
    var createdAt: Date
    /// nil = this device.
    var originDeviceID: String?
    var mergedInto: UUID?
}

/// Last-writer-wins for places, plus the merge of same-named places that
/// two devices created independently (the four seeded defaults, typically).
///
/// The merge rule is symmetric so every device reaches the same answer on
/// its own, in any order: the first time a device sees a remote place whose
/// name matches a live local place *from a different device*, the two
/// become one, keeping the id of the **older** place (earlier `createdAt`;
/// ties → smaller UUID string). The loser's readings are re-filed under the
/// winner's id, and its origin device writes a tombstone `mergedInto` the
/// winner. Places from the same device never merge (two "Bedroom"s made on
/// one device are deliberate), and renames never merge (only first sight).
enum PlaceResolver {
    enum Decision: Equatable {
        /// New place: add it.
        case insert
        /// New tombstone for a place we never had: remember it.
        case rememberTombstone
        /// Remote is newer: take its name/kanji/order, or delete.
        case applyRemote
        /// Local is newer (or the same): keep ours, make sure it's sent.
        case keepLocal
        /// Already merged away here: nothing to do.
        case ignore
        /// Same place as local `loser` (remote is older): local becomes remote.
        case adoptRemote(replacing: UUID)
        /// Same place as local `winner` (local is older): remote becomes local.
        case mergeIntoLocal(UUID)
    }

    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// - Parameters:
    ///   - local: our copy of the same id (live or tombstone), if any.
    ///   - livePlaces: every live local place (to find a same-named twin).
    static func resolve(remote: PlaceSnapshot, local: PlaceSnapshot?, livePlaces: [PlaceSnapshot],
                        localDeviceID: String) -> Decision {
        if let local {
            if local.mergedInto != nil { return .ignore }
            return remote.modifiedAt > local.modifiedAt ? .applyRemote : .keepLocal
        }
        if remote.deleted { return .rememberTombstone }
        let remoteOrigin = remote.originDeviceID ?? ""
        let key = normalized(remote.name)
        let twin = livePlaces
            .filter { !$0.deleted && $0.id != remote.id && normalized($0.name) == key
                && ($0.originDeviceID ?? localDeviceID) != remoteOrigin }
            .min { older($0, than: $1) }
        guard let twin else { return .insert }
        return older(remote, than: twin) ? .adoptRemote(replacing: twin.id) : .mergeIntoLocal(twin.id)
    }

    /// The merge winner order: earlier creation, then smaller id.
    static func older(_ a: PlaceSnapshot, than b: PlaceSnapshot) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }
}

/// Last-writer-wins for "where the sensor is".
enum SensorStateResolver {
    static func shouldApply(remote: Date, local: Date) -> Bool { remote > local }
}

/// The sync folder and its files.
struct SyncFiles: Sendable {
    let folder: URL

    static var standard: SyncFiles {
        SyncFiles(folder: URL.applicationSupportDirectory.appending(path: "Kuki/Sync", directoryHint: .isDirectory))
    }

    var ledgerURL: URL { folder.appending(path: "ledger.json") }
    var engineStateURL: URL { folder.appending(path: "engine-state.json") }
    var deviceIDURL: URL { folder.appending(path: "device-id") }

    func prepare() {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Generated once per install, never synced or backed up.
    func deviceID() -> String {
        prepare()
        if let raw = try? String(contentsOf: deviceIDURL, encoding: .utf8),
           let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return id.uuidString
        }
        let id = UUID().uuidString
        try? Data(id.utf8).write(to: deviceIDURL, options: .atomic)
        return id
    }

    /// The device id if sync ever made one — read-only, never creates it.
    func existingDeviceID() -> String? {
        guard let raw = try? String(contentsOf: deviceIDURL, encoding: .utf8) else { return nil }
        return UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))?.uuidString
    }

    func loadLedger() -> SyncLedger {
        guard let data = try? Data(contentsOf: ledgerURL),
              let ledger = try? JSONDecoder().decode(SyncLedger.self, from: data) else { return SyncLedger() }
        return ledger
    }

    func save(_ ledger: SyncLedger) {
        prepare()
        if let data = try? JSONEncoder().encode(ledger) { try? data.write(to: ledgerURL, options: .atomic) }
    }

    func loadEngineState() -> Data? { try? Data(contentsOf: engineStateURL) }

    func saveEngineState(_ data: Data?) {
        prepare()
        if let data { try? data.write(to: engineStateURL, options: .atomic) } else {
            try? FileManager.default.removeItem(at: engineStateURL)
        }
    }
}
