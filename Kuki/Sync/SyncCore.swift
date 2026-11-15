import CloudKit
import Foundation
import os
import SwiftData

/// Where the core hands record names to send. The CKSyncEngine adapter in
/// production; a list in tests.
@MainActor
protocol SyncOutbox: AnyObject {
    /// Returns whether the changes were queued (false: the engine isn't
    /// running).
    @discardableResult func enqueueSaves(_ names: [SyncRecordName]) -> Bool
    /// Deletes, replacing any pending save of the same records.
    @discardableResult func enqueueDeletes(_ names: [SyncRecordName]) -> Bool
    /// Send what's queued in a few seconds, even while the app stays in
    /// front (debounced).
    func sendSoon()
}

/// Why a queued change has nothing to send — logged when it's dropped.
struct SkipReason: Error, Equatable {
    var text: String
    init(_ text: String) { self.text = text }
}

/// Saves (and deletes) that failed for a reason the engine doesn't retry
/// itself: tried again up to `maxAttempts` in all, then given up on — and
/// reported as a problem until that record next goes through.
struct SaveRetryBook: Equatable {
    let maxAttempts: Int
    private(set) var attempts: [String: Int] = [:]
    private(set) var gaveUp: Set<String> = []

    init(maxAttempts: Int = SyncSchema.maxSaveAttempts) { self.maxAttempts = maxAttempts }

    /// Count a failure of `name`. Returns which attempt failed and whether
    /// to queue it again.
    mutating func failed(_ name: String) -> (attempt: Int, retry: Bool) {
        let attempt = (attempts[name] ?? 0) + 1
        guard attempt < maxAttempts else {
            attempts[name] = nil // a later, fresh change gets its own tries
            gaveUp.insert(name)
            return (attempt, false)
        }
        attempts[name] = attempt
        return (attempt, true)
    }

    mutating func succeeded(_ names: [String]) {
        for name in names {
            attempts[name] = nil
            gaveUp.remove(name)
        }
    }

    /// For the status line, while anything was given up on.
    var problem: String? {
        switch gaveUp.count {
        case 0: nil
        case 1: String(localized: "A change couldn't be saved to iCloud", comment: "Settings, iCloud Sync status line: one change failed to upload.")
        // n ≥ 2, but still a plural key: Russian, Polish, Arabic… inflect by count.
        case let n: String(localized: "\(n) changes couldn't be saved to iCloud", comment: "Settings, iCloud Sync status line: several changes failed to upload. %lld = number of changes (2 or more).")
        }
    }
}

/// Runs an action once, `delay` after the last of a burst of calls.
@MainActor
final class SendDebouncer {
    let delay: Duration
    private var task: Task<Void, Never>?

    init(delay: Duration) { self.delay = delay }

    func schedule(_ action: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
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
    /// The seeded places' names in every language, for the cross-language
    /// twin merge (`PlaceResolver`). Tests pass their own table.
    var seedNames: SeedNames = .bundled
    private let now: () -> Date
    private let log = Logger(subsystem: "com.olshanskysoft.kuki", category: "sync")

    /// The hour still filling up, and when it was last enqueued.
    private var openHour: Int?
    private var openHourEnqueuedAt: Date?
    private var openHourDirty = false
    /// Own hours that filled up again while their iCloud copy was being
    /// deleted: saved once the delete is through.
    private var heldBackHours: Set<Int> = []

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

    /// Detail that's only worth seeing while chasing a problem.
    func debug(_ line: String) {
        log.debug("\(line, privacy: .public)")
        DebugLog.write("sync", line)
    }

    func saveLedger() { files.save(ledger) }

    /// Queue saves. An hour whose iCloud copy is being deleted is held back
    /// until the delete is through (`didDelete`). Returns whether anything
    /// was queued.
    @discardableResult
    private func enqueue(_ names: [SyncRecordName]) -> Bool {
        guard let outbox else { return false }
        var ready: [SyncRecordName] = []
        for name in names {
            if case let .chunk(device, hour) = name, device == deviceID, ledger.pendingChunkDeletes.contains(hour) {
                heldBackHours.insert(hour)
            } else {
                ready.append(name)
            }
        }
        guard !ready.isEmpty else { return false }
        return outbox.enqueueSaves(ready)
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

    /// The sensor was carried somewhere else, here: queue the sensor's place
    /// and send it in a few seconds, so other devices follow without waiting
    /// for this app to go to the background. Returns whether it was queued.
    @discardableResult
    func placeMoved(to id: UUID, at time: Date) -> Bool {
        let name = placeName(id) ?? id.uuidString
        guard let outbox else {
            say("sensor moved here → \(name) (sync is off: not sent)")
            return false
        }
        if let reason = stateSkipReason {
            say("sensor moved here → \(name), not sent: \(reason)")
            return false
        }
        guard enqueue([.sensorState]) else {
            say("sensor moved here → \(name), NOT queued: the sync engine isn't running")
            return false
        }
        say("sensor moved here → \(name), queued for iCloud")
        outbox.sendSoon()
        return true
    }

    /// "Delete all recordings" here, just before the readings go: this
    /// device's hours are deleted from iCloud too, and other devices drop
    /// them when they fetch the deletions. Returns how many were queued.
    @discardableResult
    func ownHistoryWillBeDeleted() -> Int {
        let hours = HistoryStore.ownHours(in: context, deviceID: deviceID)
        openHourDirty = false
        openHourEnqueuedAt = nil
        guard let outbox else {
            say("all recordings deleted here; sync is off, so \(hours.count) hours already in iCloud stay there")
            return 0
        }
        guard !hours.isEmpty else { return 0 }
        let names = hours.map { SyncRecordName.chunk(deviceID: deviceID, epochHour: $0) }
        guard outbox.enqueueDeletes(names) else {
            say("all recordings deleted here, but \(hours.count) hours NOT queued for deletion from iCloud: the sync engine isn't running")
            return 0
        }
        for name in names { ledger.systemFields[name.name] = nil }
        ledger.pendingChunkDeletes.formUnion(hours)
        saveLedger()
        say("all recordings deleted here: \(hours.count) hours queued for deletion from iCloud")
        outbox.sendSoon()
        return hours.count
    }

    /// The server confirmed these deletions (or never had the record, or
    /// they were given up on). A deleted hour that has filled up again since
    /// can now go up.
    func didDelete(_ recordNames: [String]) {
        var cleared: Set<Int> = []
        for raw in recordNames {
            guard case let .chunk(device, hour)? = SyncRecordName(raw), device == deviceID,
                  ledger.pendingChunkDeletes.remove(hour) != nil else { continue }
            cleared.insert(hour)
        }
        guard !cleared.isEmpty else { return }
        saveLedger()
        let due = heldBackHours.intersection(cleared)
        heldBackHours.subtract(cleared)
        enqueue(due.sorted().map { .chunk(deviceID: deviceID, epochHour: $0) })
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

    /// Why the sensor's place has nothing to send, or nil when it's due.
    private var stateSkipReason: String? {
        guard let recorder else { return "the recorder isn't attached" }
        guard recorder.currentPlaceID != nil else { return "the sensor has no place" }
        guard recorder.placeChangedAt > .distantPast else { return "the sensor hasn't been moved on this device" }
        guard !needsStateSend else { return nil }
        let server = ledger.serverStateChangedAt.map(Self.stamp) ?? "?"
        return "iCloud already holds a move at least as new (\(server) ≥ \(Self.stamp(recorder.placeChangedAt)))"
    }

    private static func stamp(_ date: Date) -> String { date.formatted(.iso8601) }

    // MARK: Building records

    /// The record to send for `name`, or nil to drop the change (nothing to
    /// send, or the server already has something newer).
    func record(for name: SyncRecordName) async -> CKRecord? {
        try? await buildRecord(for: name).get()
    }

    /// The record to send for `name`, or why there is none (logged when the
    /// change is dropped).
    func buildRecord(for name: SyncRecordName) async -> Result<CKRecord, SkipReason> {
        let base = SyncRecords.newRecord(name, systemFields: ledger.systemFields[name.name])
        switch name {
        case let .chunk(device, hour):
            guard device == deviceID else { return .failure(SkipReason("another device's hour")) }
            guard let chunk = await store.chunk(epochHour: hour, deviceID: deviceID) else {
                return .failure(SkipReason("no readings of this device in that hour"))
            }
            do { try SyncRecords.fill(base, with: chunk) } catch {
                return .failure(SkipReason("couldn't encode the hour: \(error.localizedDescription)"))
            }
            return .success(base)
        case let .place(id):
            return placeSnapshotToSend(id).map { snapshot in
                SyncRecords.fill(base, with: snapshot, localDeviceID: deviceID)
                return base
            }
        case .sensorState:
            if let reason = stateSkipReason { return .failure(SkipReason(reason)) }
            guard let state = localState else { return .failure(SkipReason("the sensor has no place")) }
            SyncRecords.fill(base, with: state)
            return .success(base)
        }
    }

    private func placeSnapshotToSend(_ id: UUID) -> Result<PlaceSnapshot, SkipReason> {
        guard let meta = ledger.places[id.uuidString] else { return .failure(SkipReason("no clock for this place")) }
        guard needsSend(meta) else { return .failure(SkipReason("iCloud already has this version")) }
        // Only the device a place came from writes its merge tombstone.
        if meta.mergedInto != nil, meta.originDeviceID != nil {
            return .failure(SkipReason("another device writes this merge tombstone"))
        }
        if !meta.deleted, let place = fetchPlace(id) {
            return .success(PlaceSnapshot(id: id, name: place.name, kanji: place.kanji, sortIndex: place.sortIndex,
                                          deleted: false, modifiedAt: meta.modifiedAt, createdAt: place.createdAt,
                                          originDeviceID: meta.originDeviceID, mergedInto: nil))
        }
        guard meta.deleted else { return .failure(SkipReason("the place is gone here without a tombstone")) }
        return .success(PlaceSnapshot(id: id, name: meta.name, kanji: meta.kanji, sortIndex: meta.sortIndex, deleted: true,
                                      modifiedAt: meta.modifiedAt, createdAt: meta.createdAt,
                                      originDeviceID: meta.originDeviceID, mergedInto: meta.mergedInto.flatMap(UUID.init)))
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

    /// A direct read found no sensor's place in iCloud. If this device has
    /// one, it never got there (or was lost): send it.
    func noteStateMissingOnServer() {
        let wasKnown = ledger.stateServerKnown
        ledger.stateServerKnown = false
        ledger.serverStateChangedAt = nil
        ledger.systemFields[SyncSchema.sensorStateName] = nil
        saveLedger()
        guard localState != nil else {
            debug("no sensor's place in iCloud yet, and none to send from here")
            return
        }
        guard enqueue([.sensorState]) else { return }
        say("no sensor's place in iCloud\(wasKnown ? " although it was sent before" : "") — sending this device's")
        outbox?.sendSoon()
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

    /// Records deleted in iCloud. An hour of another device's history (its
    /// "Delete all recordings") takes that device's readings here with it.
    /// Returns how many readings were removed.
    func applyFetchedDeletions(_ recordNames: [String]) async -> Int {
        var removed = 0
        for raw in recordNames {
            guard let name = SyncRecordName(raw) else { continue }
            ledger.systemFields[raw] = nil
            switch name {
            case let .chunk(device, hour) where device != deviceID:
                removed += await store.deleteChunk(deviceID: device, epochHour: hour, localDeviceID: deviceID)
            case .sensorState:
                // Ours goes up again, if there is one.
                ledger.stateServerKnown = false
                ledger.serverStateChangedAt = nil
                if needsStateSend { enqueue([.sensorState]) }
            case .chunk, .place:
                break // our own hours are only deleted by us; places use tombstones
            }
        }
        saveLedger()
        return removed
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
        let decision = PlaceResolver.resolve(remote: remote, local: local, livePlaces: live, localDeviceID: deviceID,
                                              seeds: seedNames)
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
                try? context.save()
                // Straight away, not after the rest of the batch: the
                // recorder must never sit without a place across the chunk
                // imports' awaits — it would record "Unplaced" meanwhile.
                recorder?.placesDidChange()
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
    ///
    /// `to` may itself have been merged away already (three devices, or a
    /// reinstall that seeded its places again): everything goes to the end
    /// of the chain, never to an id that no longer exists here — readings
    /// filed there would show as a separate "Living room (2)", and a sensor
    /// moved there would record "Unplaced".
    private func alias(_ from: UUID, to: UUID, name: String) async {
        let target = ledger.resolve(to)
        guard from != target else { return }
        ledger.aliases[from.uuidString] = target.uuidString
        recorder?.replacePlace(from, with: target)
        let name = target == to ? name : (fetchPlace(target)?.name ?? name)
        let hours = await store.refile(from: from, to: target, name: name, localDeviceID: deviceID)
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
            // The same moment is our own move (or one already followed).
            if remote.changedAt < localChangedAt {
                say("sensor move from another device ignored: older than the last move here (\(Self.stamp(remote.changedAt)) < \(Self.stamp(localChangedAt)))")
            }
            if needsStateSend { enqueue([.sensorState]) }
            return
        }
        ledger.pendingRemoteState = remote
        if !applyPendingState(), recorder != nil {
            say("sensor moved on another device to a place that isn't here yet (\(remote.placeID.uuidString.prefix(8))) — waiting for it")
        }
    }

    /// The recorder has just been attached. Merges filed before that (a
    /// fetch at launch, before any window) couldn't move it: if its place was
    /// merged away meanwhile, follow the merge to the survivor — not a move,
    /// the sensor stays where it is. Returns whether it followed one.
    @discardableResult
    func followMerges() -> Bool {
        guard let recorder, let id = recorder.currentPlaceID else { return false }
        let survivor = ledger.resolve(id)
        guard survivor != id, fetchPlace(survivor) != nil else { return false }
        recorder.replacePlace(id, with: survivor)
        say("the sensor's place was merged before the recorder started — following it to \(placeName(survivor) ?? survivor.uuidString)")
        return true
    }

    /// Returns whether a held-back remote move was applied.
    @discardableResult
    func applyPendingState() -> Bool {
        guard let pending = ledger.pendingRemoteState, let recorder else { return false }
        let id = ledger.resolve(pending.placeID)
        guard let place = fetchPlace(id) else { return false }
        ledger.pendingRemoteState = nil
        if recorder.applyRemoteMove(to: id, changedAt: pending.changedAt) {
            say("sensor moved on another device → \(place.name)")
        }
        saveLedger()
        return true
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
