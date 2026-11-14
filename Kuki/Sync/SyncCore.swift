import CloudKit
import Foundation
import os
import SwiftData

/// Where the core hands record names to send. The CKSyncEngine adapter in
/// production; a list in tests.
@MainActor
protocol SyncOutbox: AnyObject {
    func enqueueSaves(_ names: [SyncRecordName])
}

/// What happened in one batch of fetched records — for the log line.
struct FetchSummary: Equatable {
    var chunks = 0
    var imported = 0
    var duplicates = 0
    var places = 0
    var states = 0
}

/// The logic of history sync, independent of CKSyncEngine: decides what to
/// upload and when, builds records, and files what other devices send.
/// Everything CloudKit-*networked* lives in `HistorySync`; this class only
/// creates CKRecord values, so tests drive it with an in-memory store.
@MainActor
final class SyncCore {
    let deviceID: String
    let container: ModelContainer
    let store: HistoryStore
    private let files: SyncFiles
    private(set) var ledger: SyncLedger
    /// nil while sync is off: nothing is enqueued, but place edits are still
    /// clocked so they win (or lose) correctly once it's back on.
    weak var outbox: SyncOutbox?
    weak var recorder: Recorder?
    private let now: () -> Date
    private let log = Logger(subsystem: "com.olshanskysoft.kuki", category: "sync")

    /// The hour still filling up, and when it was last enqueued.
    private var openHour: Int?
    private var openHourEnqueuedAt: Date?
    private var openHourDirty = false

    init(container: ModelContainer, files: SyncFiles, deviceID: String? = nil, now: @escaping () -> Date = { .now }) {
        self.container = container
        self.files = files
        self.deviceID = deviceID ?? files.deviceID()
        self.store = HistoryStore(modelContainer: container)
        self.ledger = files.loadLedger()
        self.now = now
    }

    private var context: ModelContext { container.mainContext }

    func say(_ line: String) {
        log.notice("\(line, privacy: .public)")
        DebugLog.write("sync", line)
    }

    func saveLedger() { files.save(ledger) }

    private func enqueue(_ names: [SyncRecordName]) {
        guard let outbox, !names.isEmpty else { return }
        outbox.enqueueSaves(names)
    }

    // MARK: Local changes → uploads

    /// A reading was just recorded here. Closes the previous hour at once;
    /// re-saves the hour still filling up at most every 10 minutes (the
    /// record is built when it's sent, so it carries everything up to then).
    func noteRecorded(at time: Date, sensorName: String) {
        guard outbox != nil, sensorName != DemoSensor.name else { return }
        let hour = EpochHour.of(time)
        if let open = openHour, open != hour, openHourDirty {
            enqueue([.chunk(deviceID: deviceID, epochHour: open)])
        }
        if openHour != hour {
            openHour = hour
            openHourEnqueuedAt = nil
        }
        openHourDirty = true
        if ledger.lastActiveHour != hour {
            ledger.lastActiveHour = hour
            saveLedger()
        }
        let due = openHourEnqueuedAt.map { now().timeIntervalSince($0) >= SyncSchema.currentHourResave } ?? true
        if due { enqueueOpenHour() }
    }

    /// Going to the background or quitting: send the open hour now.
    func flush() {
        guard openHourDirty else { return }
        enqueueOpenHour()
    }

    private func enqueueOpenHour() {
        guard let open = openHour else { return }
        enqueue([.chunk(deviceID: deviceID, epochHour: open)])
        openHourEnqueuedAt = now()
        openHourDirty = false
    }

    /// A place was added, renamed or re-ordered here.
    func placeEdited(_ place: Place) {
        var meta = ledger.places[place.id.uuidString] ?? newMeta(for: place)
        meta.name = place.name
        meta.kanji = place.kanji
        meta.sortIndex = place.sortIndex
        meta.deleted = false
        meta.mergedInto = nil
        meta.modifiedAt = max(now(), meta.modifiedAt)
        ledger.places[place.id.uuidString] = meta
        saveLedger()
        say("place edited: \(place.name)")
        enqueue([.place(place.id)])
    }

    /// A place was deleted here: a tombstone, so other devices drop it too.
    func placeDeleted(id: UUID, name: String, kanji: String, sortIndex: Int, createdAt: Date) {
        var meta = ledger.places[id.uuidString]
            ?? SyncLedger.PlaceMeta(modifiedAt: createdAt, createdAt: createdAt, originDeviceID: nil)
        meta.deleted = true
        meta.name = name
        meta.kanji = kanji
        meta.sortIndex = sortIndex
        meta.modifiedAt = max(now(), meta.modifiedAt)
        ledger.places[id.uuidString] = meta
        saveLedger()
        say("place deleted: \(name)")
        enqueue([.place(id)])
    }

    /// The sensor was carried somewhere else, here.
    func placeMoved(to id: UUID, at time: Date) {
        say("sensor moved here → \(placeName(id) ?? id.uuidString)")
        enqueue([.sensorState])
    }

    private func newMeta(for place: Place) -> SyncLedger.PlaceMeta {
        SyncLedger.PlaceMeta(modifiedAt: place.createdAt, createdAt: place.createdAt, originDeviceID: nil,
                             name: place.name, kanji: place.kanji, sortIndex: place.sortIndex)
    }

    /// Everything that should be on the server and may not be: places and
    /// tombstones, the sensor's place, and this device's history (all of it
    /// the first time, else the hours since sync last ran here).
    func enqueueCatchUp() async {
        guard outbox != nil else { return }
        var names: [SyncRecordName] = []
        for place in livePlaces() where ledger.places[place.id.uuidString] == nil {
            ledger.places[place.id.uuidString] = newMeta(for: place)
        }
        for (key, meta) in ledger.places where needsSend(meta) {
            if let id = UUID(uuidString: key) { names.append(.place(id)) }
        }
        if needsStateSend { names.append(.sensorState) }
        let current = EpochHour.of(now())
        let since: Int? = ledger.backfillDone ? (ledger.lastActiveHour ?? current) : nil
        let hours = await store.ownHours(deviceID: deviceID, sinceHour: since)
        names += hours.map { .chunk(deviceID: deviceID, epochHour: $0) }
        if !ledger.backfillDone {
            say("backfill: \(hours.count) hours of history queued")
        } else if !hours.isEmpty {
            say("catch-up: \(hours.count) hours queued")
        }
        ledger.backfillDone = true
        ledger.lastActiveHour = max(ledger.lastActiveHour ?? current, current)
        saveLedger()
        enqueue(names)
    }

    private func needsSend(_ meta: SyncLedger.PlaceMeta) -> Bool {
        if meta.mergedInto != nil && meta.originDeviceID != nil { return false } // someone else's tombstone
        guard meta.serverKnown, let server = meta.serverModifiedAt else { return true }
        return meta.modifiedAt > server
    }

    private var localState: RemoteSensorState? {
        guard let recorder, let id = recorder.currentPlaceID, recorder.placeChangedAt > .distantPast else { return nil }
        return RemoteSensorState(placeID: id, changedAt: recorder.placeChangedAt)
    }

    private var needsStateSend: Bool {
        guard let local = localState else { return false }
        guard ledger.stateServerKnown, let server = ledger.serverStateChangedAt else { return true }
        return local.changedAt > server
    }

    // MARK: Building records

    /// The record to send for `name`, or nil to drop the change (nothing to
    /// send, or the server already has something newer).
    func record(for name: SyncRecordName) async -> CKRecord? {
        let base = SyncRecords.newRecord(name, systemFields: ledger.systemFields[name.name])
        switch name {
        case let .chunk(device, hour):
            guard device == deviceID, let chunk = await store.chunk(epochHour: hour, deviceID: deviceID) else { return nil }
            do { try SyncRecords.fill(base, with: chunk) } catch { return nil }
            return base
        case let .place(id):
            guard let snapshot = placeSnapshotToSend(id) else { return nil }
            SyncRecords.fill(base, with: snapshot, localDeviceID: deviceID)
            return base
        case .sensorState:
            guard let state = localState, needsStateSend else { return nil }
            SyncRecords.fill(base, with: state)
            return base
        }
    }

    private func placeSnapshotToSend(_ id: UUID) -> PlaceSnapshot? {
        guard let meta = ledger.places[id.uuidString], needsSend(meta) else { return nil }
        // Only the device a place came from writes its merge tombstone.
        if meta.mergedInto != nil, meta.originDeviceID != nil { return nil }
        if !meta.deleted, let place = fetchPlace(id) {
            return PlaceSnapshot(id: id, name: place.name, kanji: place.kanji, sortIndex: place.sortIndex,
                                 deleted: false, modifiedAt: meta.modifiedAt, createdAt: place.createdAt,
                                 originDeviceID: meta.originDeviceID, mergedInto: nil)
        }
        guard meta.deleted else { return nil }
        return PlaceSnapshot(id: id, name: meta.name, kanji: meta.kanji, sortIndex: meta.sortIndex, deleted: true,
                             modifiedAt: meta.modifiedAt, createdAt: meta.createdAt,
                             originDeviceID: meta.originDeviceID, mergedInto: meta.mergedInto.flatMap(UUID.init))
    }

    // MARK: Server answers

    /// Records the server now holds (sent by us, or fetched): keep their
    /// system fields so the next save is an update, and their clocks.
    func noteServerCopy(_ record: CKRecord) {
        guard let name = SyncRecordName(record.recordID.recordName) else { return }
        ledger.systemFields[name.name] = SyncRecords.systemFields(of: record)
        switch name {
        case .place:
            if let snapshot = SyncRecords.place(from: record), var meta = ledger.places[snapshot.id.uuidString] {
                meta.serverKnown = true
                meta.serverModifiedAt = max(meta.serverModifiedAt ?? .distantPast, snapshot.modifiedAt)
                ledger.places[snapshot.id.uuidString] = meta
            }
        case .sensorState:
            if let state = SyncRecords.state(from: record) {
                ledger.stateServerKnown = true
                ledger.serverStateChangedAt = max(ledger.serverStateChangedAt ?? .distantPast, state.changedAt)
            }
        case .chunk:
            break
        }
    }

    func didSend(_ saved: [CKRecord]) {
        for record in saved { noteServerCopy(record) }
        ledger.pruneChunkFields(currentHour: EpochHour.of(now()))
        saveLedger()
    }

    /// Someone else saved this record first. Chunks are ours alone: retry on
    /// top of the server copy. Places and the sensor's place: newest wins.
    /// Returns whether to retry our save.
    func resolveConflict(server: CKRecord) async -> Bool {
        guard let name = SyncRecordName(server.recordID.recordName) else { return false }
        switch name {
        case .chunk:
            ledger.systemFields[name.name] = SyncRecords.systemFields(of: server)
            saveLedger()
            return true
        case .place, .sensorState:
            _ = await applyFetched([server])
            // `applyFetched` keeps the newer side: if ours is still newer it's
            // still due (needsSend), and it now carries the server's tag.
            switch name {
            case let .place(id): return ledger.places[id.uuidString].map(needsSend) ?? false
            default: return needsStateSend
            }
        }
    }

    /// The zone is gone (deleted elsewhere, or the account changed): forget
    /// what the server knew, so everything of ours is uploaded again.
    func resetServerKnowledge() {
        ledger.resetServerKnowledge()
        saveLedger()
    }

    /// The zone wasn't there when we saved into it.
    func resetZone() {
        ledger.zoneSaved = false
        saveLedger()
    }

    /// The server no longer has this record: save it fresh next time.
    func forgetServerCopy(_ recordName: String) {
        ledger.systemFields[recordName] = nil
        saveLedger()
    }

    func noteZoneSaved() {
        ledger.zoneSaved = true
        saveLedger()
    }

    func noteSynced() {
        ledger.lastSyncAt = now()
        saveLedger()
    }

    // MARK: Remote changes → local

    /// File a batch of fetched records: places first (readings and the
    /// sensor's place refer to them), then the sensor's place, then history.
    func applyFetched(_ records: [CKRecord]) async -> FetchSummary {
        var summary = FetchSummary()
        var places: [PlaceSnapshot] = []
        var states: [RemoteSensorState] = []
        var chunks: [HourChunk] = []
        for record in records {
            switch record.recordType {
            case SyncSchema.RecordType.place:
                if let p = SyncRecords.place(from: record) { places.append(p) }
            case SyncSchema.RecordType.sensorState:
                if let s = SyncRecords.state(from: record) { states.append(s) }
            case SyncSchema.RecordType.hourChunk:
                if let c = SyncRecords.chunk(from: record) { chunks.append(c) }
            default:
                continue
            }
            noteServerCopyIfTracked(record)
        }
        for p in places.sorted(by: { $0.modifiedAt < $1.modifiedAt }) { await applyRemotePlace(p) }
        summary.places = places.count
        if let newest = states.max(by: { $0.changedAt < $1.changedAt }) { applyRemoteState(newest) }
        summary.states = states.count
        for chunk in chunks.sorted(by: { $0.epochHour < $1.epochHour }) {
            let result = await applyRemoteChunk(chunk)
            summary.chunks += 1
            summary.imported += result.inserted
            summary.duplicates += result.duplicates
        }
        // Places changed under the recorder's feet, and a held-back sensor
        // move may now have its place.
        recorder?.placesDidChange()
        applyPendingState()
        saveLedger()
        return summary
    }

    /// System fields only for records we may write ourselves.
    private func noteServerCopyIfTracked(_ record: CKRecord) {
        switch SyncRecordName(record.recordID.recordName) {
        case .place?, .sensorState?: noteServerCopy(record)
        default: break
        }
    }

    /// Another device's hour: insert what isn't here yet. Never enqueues.
    func applyRemoteChunk(_ chunk: HourChunk) async -> HistoryStore.ImportResult {
        guard chunk.deviceID != deviceID else { return .init() }
        return await store.importChunk(chunk, localDeviceID: deviceID, aliases: ledger.aliases)
    }

    func applyRemotePlace(_ remote: PlaceSnapshot) async {
        let key = remote.id.uuidString
        let local = localSnapshot(remote.id)
        let live = livePlaces().map(snapshot(of:))
        let decision = PlaceResolver.resolve(remote: remote, local: local, livePlaces: live, localDeviceID: deviceID)
        switch decision {
        case .insert:
            insertPlace(remote)
            remember(remote)
            say("place added from iCloud: \(remote.name)")
        case .rememberTombstone:
            remember(remote)
            if let winner = remote.mergedInto { await alias(remote.id, to: winner, name: "") }
        case .applyRemote:
            if remote.deleted {
                if let winner = remote.mergedInto {
                    await alias(remote.id, to: winner, name: fetchPlace(winner)?.name ?? "")
                } else {
                    recorder?.forgetPlace(id: remote.id)
                }
                if let place = fetchPlace(remote.id) { context.delete(place) }
                say("place deleted from iCloud: \(remote.name)")
            } else if let place = fetchPlace(remote.id) {
                place.name = remote.name
                place.kanji = remote.kanji
                place.sortIndex = remote.sortIndex
                say("place updated from iCloud: \(remote.name)")
            } else {
                insertPlace(remote)
                say("place restored from iCloud: \(remote.name)")
            }
            try? context.save()
            remember(remote)
        case .keepLocal:
            if var meta = ledger.places[key] {
                meta.serverKnown = true
                meta.serverModifiedAt = max(meta.serverModifiedAt ?? .distantPast, remote.modifiedAt)
                ledger.places[key] = meta
                if needsSend(meta) { enqueue([.place(remote.id)]) }
            } else if let place = fetchPlace(remote.id) {
                // A place from before sync (no clock yet), not older than
                // the server's copy: start its clock, already in step.
                var meta = newMeta(for: place)
                meta.serverKnown = true
                meta.serverModifiedAt = remote.modifiedAt
                ledger.places[key] = meta
                if needsSend(meta) { enqueue([.place(remote.id)]) }
            }
        case .ignore:
            if var meta = ledger.places[key] {
                meta.serverKnown = true
                meta.serverModifiedAt = max(meta.serverModifiedAt ?? .distantPast, remote.modifiedAt)
                ledger.places[key] = meta
            }
        case let .adoptRemote(loserID):
            // The remote place is the older twin: ours becomes it.
            let loser = fetchPlace(loserID)
            let loserMeta = ledger.places[loserID.uuidString] ?? loser.map(newMeta(for:))
            insertPlace(remote)
            remember(remote)
            await alias(loserID, to: remote.id, name: remote.name)
            if let loser { context.delete(loser) }
            try? context.save()
            var tomb = loserMeta ?? SyncLedger.PlaceMeta(modifiedAt: now(), createdAt: now(), originDeviceID: nil)
            tomb.deleted = true
            tomb.mergedInto = remote.id.uuidString
            tomb.modifiedAt = max(now(), tomb.modifiedAt)
            ledger.places[loserID.uuidString] = tomb
            say("place merged: \(remote.name) — this device's copy joins the older one")
            if tomb.originDeviceID == nil { enqueue([.place(loserID)]) }
        case let .mergeIntoLocal(winnerID):
            // Ours is the older twin: the remote one is filed under it. Its
            // own device writes the tombstone.
            var meta = SyncLedger.PlaceMeta(modifiedAt: remote.modifiedAt, createdAt: remote.createdAt,
                                            originDeviceID: remote.originDeviceID ?? "?")
            meta.deleted = true
            meta.mergedInto = winnerID.uuidString
            meta.serverKnown = true
            meta.serverModifiedAt = remote.modifiedAt
            meta.name = remote.name
            ledger.places[key] = meta
            await alias(remote.id, to: winnerID, name: fetchPlace(winnerID)?.name ?? remote.name)
            say("place merged: \(remote.name) from another device joins this one")
        }
        saveLedger()
    }

    /// Store the remote copy's clock and fields as ours.
    private func remember(_ remote: PlaceSnapshot) {
        var meta = SyncLedger.PlaceMeta(modifiedAt: remote.modifiedAt, createdAt: remote.createdAt,
                                        originDeviceID: remote.originDeviceID == deviceID ? nil : (remote.originDeviceID ?? "?"))
        meta.deleted = remote.deleted
        meta.mergedInto = remote.mergedInto?.uuidString
        meta.serverKnown = true
        meta.serverModifiedAt = remote.modifiedAt
        meta.name = remote.name
        meta.kanji = remote.kanji
        meta.sortIndex = remote.sortIndex
        ledger.places[remote.id.uuidString] = meta
    }

    /// `from` is now `to`: re-file readings, follow the sensor, remember it
    /// for readings that arrive later.
    private func alias(_ from: UUID, to: UUID, name: String) async {
        guard from != to else { return }
        ledger.aliases[from.uuidString] = to.uuidString
        recorder?.replacePlace(from, with: to)
        let hours = await store.refile(from: from, to: to, name: name, localDeviceID: deviceID)
        if !hours.isEmpty {
            say("re-filed \(hours.count) hours of history under the merged place")
            enqueue(hours.map { .chunk(deviceID: deviceID, epochHour: $0) })
        }
    }

    private func insertPlace(_ remote: PlaceSnapshot) {
        let place = Place(name: remote.name, kanji: remote.kanji, sortIndex: remote.sortIndex)
        place.id = remote.id
        place.createdAt = remote.createdAt
        context.insert(place)
        try? context.save()
    }

    /// The sensor moved on another device. Newest move wins; a move to a
    /// place that hasn't arrived yet waits for it.
    func applyRemoteState(_ remote: RemoteSensorState) {
        ledger.stateServerKnown = true
        ledger.serverStateChangedAt = max(ledger.serverStateChangedAt ?? .distantPast, remote.changedAt)
        let localChangedAt = recorder?.placeChangedAt ?? ledger.pendingRemoteState?.changedAt ?? .distantPast
        guard SensorStateResolver.shouldApply(remote: remote.changedAt, local: localChangedAt) else {
            if needsStateSend { enqueue([.sensorState]) }
            return
        }
        ledger.pendingRemoteState = remote
        applyPendingState()
    }

    func applyPendingState() {
        guard let pending = ledger.pendingRemoteState, let recorder else { return }
        let id = ledger.resolve(pending.placeID)
        guard let place = fetchPlace(id) else { return }
        ledger.pendingRemoteState = nil
        if recorder.applyRemoteMove(to: id, changedAt: pending.changedAt) {
            say("sensor moved on another device → \(place.name)")
        }
        saveLedger()
    }

    // MARK: Store helpers

    func livePlaces() -> [Place] {
        (try? context.fetch(FetchDescriptor<Place>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
    }

    func fetchPlace(_ id: UUID) -> Place? {
        try? context.fetch(FetchDescriptor<Place>(predicate: #Predicate { $0.id == id })).first
    }

    private func placeName(_ id: UUID) -> String? { fetchPlace(id)?.name }

    private func snapshot(of place: Place) -> PlaceSnapshot {
        let meta = ledger.places[place.id.uuidString]
        return PlaceSnapshot(id: place.id, name: place.name, kanji: place.kanji, sortIndex: place.sortIndex,
                             deleted: false, modifiedAt: meta?.modifiedAt ?? place.createdAt,
                             createdAt: place.createdAt, originDeviceID: meta?.originDeviceID, mergedInto: nil)
    }

    /// Our copy of `id`: the live place (with its clock), or a tombstone.
    private func localSnapshot(_ id: UUID) -> PlaceSnapshot? {
        let meta = ledger.places[id.uuidString]
        if let place = fetchPlace(id) {
            var s = snapshot(of: place)
            s.mergedInto = meta?.mergedInto.flatMap(UUID.init)
            return s
        }
        guard let meta else { return nil }
        return PlaceSnapshot(id: id, name: meta.name, kanji: meta.kanji, sortIndex: meta.sortIndex,
                             deleted: meta.deleted, modifiedAt: meta.modifiedAt, createdAt: meta.createdAt,
                             originDeviceID: meta.originDeviceID, mergedInto: meta.mergedInto.flatMap(UUID.init))
    }
}
