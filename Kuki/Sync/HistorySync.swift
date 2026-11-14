import CloudKit
import Foundation
import Observation
import os
import SwiftData
import UIKit

/// iCloud sync of history, places and the sensor's place between the user's
/// devices — one `CKSyncEngine` on the private database, zone `KukiHistory`.
///
/// Gated like the rest of iCloud in Kūki: nothing CloudKit is created unless
/// the build has a container (`CloudSync.isEnabled` — creating a CKContainer
/// or CKSyncEngine without the entitlement crashes) and the user's switch is
/// on. Never under XCTest. The logic lives in `SyncCore`; this class only
/// runs the engine and passes its events through.
@MainActor
@Observable
final class HistorySync {
    static let shared = HistorySync()

    enum Status: Equatable {
        case off
        case waiting
        case synced(Date)
        case problem(String)
    }

    private(set) var status: Status = .off

    @ObservationIgnored private(set) var core: SyncCore?
    @ObservationIgnored private var engine: CKSyncEngine?
    @ObservationIgnored private var proxy: EngineDelegate?
    @ObservationIgnored private let files = SyncFiles.standard
    @ObservationIgnored private var periodic: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var caughtUpThisRun = false
    @ObservationIgnored private var lastActiveFetch: Date = .distantPast
    @ObservationIgnored private var sendProblem: String?
    @ObservationIgnored private var retries = SaveRetryBook()
    @ObservationIgnored private let sendSoonDebouncer = SendDebouncer(delay: SyncSchema.sendSoonDelay)

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private var shouldRun: Bool { CloudSync.isEnabled && !Self.isRunningTests }

    /// At launch, before any window: a silent push may have woken the app.
    func configure(container: ModelContainer) {
        guard core == nil, !Self.isRunningTests else { return }
        core = SyncCore(container: container, files: files)
        observeLifecycle()
        refresh()
    }

    /// The recorder is up: stamp readings, hear about moves and places.
    func attach(_ recorder: Recorder) {
        guard let core else { return }
        recorder.originDeviceID = core.deviceID
        recorder.syncHooks = self
        core.recorder = recorder
        // A merge filed at launch, before any window, couldn't move the
        // recorder. (Fully effective only when attached before
        // `recorder.start`, whose `configure` otherwise falls back to the
        // first place when the current one is gone.)
        core.followMerges()
        core.applyPendingState()
    }

    /// Start or stop to match the build and the user's switch.
    func refresh() {
        if shouldRun { start() } else { stop() }
    }

    /// The engine is up — what "Delete all recordings" tells the user.
    var isRunning: Bool { engine != nil }

    /// Fetch now (push, app in front, or the periodic timer).
    @discardableResult
    func fetchNow() async -> Bool {
        guard let engine else { return false }
        let started = Date.now
        do {
            try await engine.fetchChanges()
            core?.debug("engine fetch returned after \(Int(Date.now.timeIntervalSince(started) * 1000)) ms")
            return true
        } catch {
            core?.say("fetch failed: \(error.localizedDescription)")
            return false
        }
    }

    /// The periodic check. `fetchChanges()` only goes to the server when
    /// the engine already knows of changes (a push it received): on device
    /// it came back in ~5 ms with no request otherwise, so a Mac that missed
    /// a push stayed behind. So also read `current-place` itself — one small
    /// request — and file it like a fetched SensorState.
    private func periodicCheck() async {
        await fetchNow()
        await checkSensorState()
    }

    private func checkSensorState() async {
        // Before the first fetch and catch-up, the engine's own fetch covers it.
        guard let engine, caughtUpThisRun else { return }
        let id = SyncRecordName.sensorState.recordID
        let result: Result<CKRecord, any Error>
        do {
            let results = try await engine.database.records(for: [id])
            guard let one = results[id] else { return }
            result = one
        } catch {
            result = .failure(error)
        }
        guard engine === self.engine, let core else { return } // stopped meanwhile
        switch result {
        case let .success(record):
            let before = core.ledger.serverStateChangedAt
            let s = await core.applyFetched([record])
            let after = core.ledger.serverStateChangedAt
            if let after, after > (before ?? .distantPast) {
                core.say("periodic check: iCloud had a newer sensor's place than the last fetch (\(s.states) applied)")
            } else {
                core.debug("periodic check: sensor's place in iCloud already known")
            }
        case let .failure(error) where (error as? CKError)?.code == .unknownItem:
            core.noteStateMissingOnServer()
        case let .failure(error):
            core.say("periodic check of the sensor's place failed: \(error.localizedDescription)")
        }
    }

    /// Whether a CloudKit push is about the history zone (the engine's
    /// database subscription) rather than the latest-reading mailbox.
    nonisolated static func isHistoryNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let note = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return false }
        if let zone = note as? CKRecordZoneNotification { return zone.recordZoneID?.zoneName == SyncSchema.zoneName }
        return note is CKDatabaseNotification
    }

    // MARK: Engine lifecycle

    private func start() {
        guard engine == nil, let core, let containerID = CloudSync.containerID else { return }
        var state: CKSyncEngine.State.Serialization?
        if let data = files.loadEngineState() {
            state = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        }
        let proxy = EngineDelegate(owner: self)
        var config = CKSyncEngine.Configuration(
            database: CKContainer(identifier: containerID).privateCloudDatabase,
            stateSerialization: state, delegate: proxy)
        config.automaticallySync = true
        let engine = CKSyncEngine(config)
        self.proxy = proxy
        self.engine = engine
        core.outbox = self
        caughtUpThisRun = false
        sendProblem = nil
        retries = SaveRetryBook()
        if !core.ledger.zoneSaved {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SyncSchema.zoneID))])
        }
        // Deletes the ledger still waits for (normally already in the
        // engine's saved state; adding them again is harmless).
        let deleting = core.ledger.pendingChunkDeletes.sorted()
        if !deleting.isEmpty {
            engine.state.add(pendingRecordZoneChanges: deleting.map {
                .deleteRecord(SyncRecordName.chunk(deviceID: core.deviceID, epochHour: $0).recordID)
            })
        }
        status = core.ledger.lastSyncAt.map(Status.synced) ?? .waiting
        core.say("engine started (\(state == nil ? "fresh state" : "resumed"), device \(core.deviceID.prefix(8)))")
        // The engine also registers its own database subscription; pushes
        // reach it through the app's registration (Mac included).
        UIApplication.shared.registerForRemoteNotifications()
        startPeriodicFetch()
    }

    private func stop() {
        periodic?.cancel()
        periodic = nil
        sendSoonDebouncer.cancel()
        core?.outbox = nil
        status = .off
        guard let engine else { return }
        self.engine = nil
        proxy = nil
        Task { await engine.cancelOperations() }
        core?.say("engine stopped")
    }

    /// The account changed under us: forget the server and start afresh.
    private func restartFresh() {
        stop()
        files.saveEngineState(nil)
        core?.resetServerKnowledge()
        refresh()
    }

    private func startPeriodicFetch() {
        periodic?.cancel()
        periodic = Task { [weak self] in
            // One right away (the engine fetches on start too, but this makes
            // "on launch" explicit), then a real check every 15 minutes.
            await self?.fetchNow()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(SyncSchema.periodicFetch))
                guard !Task.isCancelled else { return }
                await self?.periodicCheck()
            }
        }
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        // Synchronously (queue: .main), not in a spawned Task: the background
        // task must exist before UIKit counts them. On a Mac quit, UIKit
        // backgrounds the app first and waits for its background tasks (up
        // to ~35 s), so this is where the last hour really goes up; by
        // willTerminate it's too late to wait for anything, so that only
        // queues the hour in the engine's state for the next launch.
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HistorySync.shared.flushInBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.willTerminateNotification,
                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HistorySync.shared.core?.flush() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { _ in
            Task { @MainActor in HistorySync.shared.becameActive() }
        })
        observers.append(center.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { _ in
            // After a sign-out the engine is stopped; a new sign-in restarts it.
            Task { @MainActor in HistorySync.shared.refresh() }
        })
    }

    private func becameActive() {
        guard engine != nil, Date.now.timeIntervalSince(lastActiveFetch) > 60 else { return }
        lastActiveFetch = .now
        Task { await fetchNow() }
    }

    /// Going to the background or quitting: send the hour still filling up.
    private func flushInBackground() {
        guard let engine, let core else { return }
        core.flush()
        let app = UIApplication.shared
        let box = TaskBox()
        box.id = app.beginBackgroundTask(withName: "Kūki sync") {
            app.endBackgroundTask(box.id)
            box.id = .invalid
        }
        Task {
            try? await engine.sendChanges()
            if box.id != .invalid { app.endBackgroundTask(box.id) }
        }
    }

    // MARK: Engine events

    fileprivate func handle(_ event: CKSyncEngine.Event, from syncEngine: CKSyncEngine) async {
        guard syncEngine === engine, let core else { return }
        switch event {
        case let .stateUpdate(update):
            files.saveEngineState(try? JSONEncoder().encode(update.stateSerialization))

        case let .accountChange(change):
            switch change.changeType {
            case .signIn:
                core.say("iCloud account signed in")
            case .signOut:
                core.say("iCloud signed out — sync stopped")
                stop()
                files.saveEngineState(nil)
                core.resetServerKnowledge()
                status = .waiting
            case .switchAccounts:
                core.say("iCloud account switched — starting over with the new account")
                Task { restartFresh() }
            @unknown default:
                break
            }

        case let .fetchedDatabaseChanges(changes):
            for deletion in changes.deletions where deletion.zoneID.zoneName == SyncSchema.zoneName {
                if deletion.reason == .purged {
                    // The user deleted Kūki's iCloud data (Settings › iCloud ›
                    // Manage Storage): respect that — switch sync off rather
                    // than quietly uploading everything again.
                    core.say("history zone purged by the user — iCloud Sync switched off")
                    core.resetServerKnowledge()
                    CloudSync.userWantsSync = false
                    stop()
                    return
                }
                core.say("history zone deleted in iCloud (\(deletion.reason)) — recreating, uploading again")
                core.resetServerKnowledge()
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SyncSchema.zoneID))])
                caughtUpThisRun = true
                await core.enqueueCatchUp()
            }

        case let .fetchedRecordZoneChanges(changes):
            let records = changes.modifications.map(\.record)
                .filter { $0.recordID.zoneID.zoneName == SyncSchema.zoneName }
            let deleted = changes.deletions.map(\.recordID)
                .filter { $0.zoneID.zoneName == SyncSchema.zoneName }
                .map(\.recordName)
            if !records.isEmpty {
                let s = await core.applyFetched(records)
                core.say("fetched \(s.chunks) chunks (+\(s.imported) readings imported, \(s.duplicates) duplicates skipped), \(s.places) places, \(s.states) sensor states")
            }
            if !deleted.isEmpty {
                let removed = await core.applyFetchedDeletions(deleted)
                core.say("fetched \(deleted.count) deletions (\(removed) readings removed)")
            }

        case let .sentDatabaseChanges(sent):
            if sent.savedZones.contains(where: { $0.zoneID.zoneName == SyncSchema.zoneName }) {
                core.noteZoneSaved()
                core.say("history zone ready")
            }
            for failure in sent.failedZoneSaves {
                core.say("zone save failed: \(failure.error.localizedDescription)")
            }

        case let .sentRecordZoneChanges(sent):
            await handleSent(sent, syncEngine: syncEngine)

        case .didFetchChanges:
            core.noteSynced()
            status = .synced(.now)
            // Places, the sensor's place and history waited for this first
            // fetch, so another device's seeded places merge before ours go up.
            if !caughtUpThisRun {
                caughtUpThisRun = true
                await core.enqueueCatchUp()
            }

        case .didSendChanges:
            if let sendProblem {
                status = .problem(sendProblem)
            } else {
                core.noteSynced()
                status = .synced(.now)
            }

        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges, .willSendChanges:
            break

        @unknown default:
            break
        }
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, syncEngine: CKSyncEngine) async {
        guard let core else { return }
        core.didSend(sent.savedRecords)
        retries.succeeded(sent.savedRecords.map(\.recordID.recordName) + sent.deletedRecordIDs.map(\.recordName))
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        var zoneMissing = false
        var storageFull = false
        for failure in sent.failedRecordSaves {
            let id = failure.record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                if let server = failure.error.serverRecord, await core.resolveConflict(server: server) {
                    retry.append(.saveRecord(id))
                }
            case .zoneNotFound:
                zoneMissing = true
                retry.append(.saveRecord(id))
            case .unknownItem:
                core.forgetServerCopy(id.recordName)
                retry.append(.saveRecord(id))
            case .quotaExceeded:
                storageFull = true
                retry.append(.saveRecord(id))
            case .batchRequestFailed:
                retry.append(.saveRecord(id))
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                 .notAuthenticated, .operationCancelled, .requestRateLimited, .accountTemporarilyUnavailable:
                core.debug("save of \(id.recordName) waits for the engine to retry: \(failure.error.localizedDescription)")
            default:
                if retryAfterUnknownError(id.recordName, failure.error, core: core) { retry.append(.saveRecord(id)) }
            }
        }
        var deleted = sent.deletedRecordIDs.map(\.recordName)
        for (id, error) in sent.failedRecordDeletes {
            switch error.code {
            case .unknownItem, .zoneNotFound:
                deleted.append(id.recordName) // nothing there to delete
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                 .notAuthenticated, .operationCancelled, .requestRateLimited, .accountTemporarilyUnavailable:
                core.debug("delete of \(id.recordName) waits for the engine to retry: \(error.localizedDescription)")
            default:
                if retryAfterUnknownError(id.recordName, error, core: core, deleting: true) {
                    retry.append(.deleteRecord(id))
                } else {
                    deleted.append(id.recordName) // given up: don't hold its hour back for ever
                }
            }
        }
        core.didDelete(deleted)
        sendProblem = storageFull ? "iCloud storage is full" : retries.problem
        if zoneMissing {
            core.resetZone()
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SyncSchema.zoneID))])
        }
        if !retry.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: retry) }

        let types = sent.savedRecords.map(\.recordType)
        let chunks = types.filter { $0 == SyncSchema.RecordType.hourChunk }.count
        let places = types.filter { $0 == SyncSchema.RecordType.place }.count
        let states = types.filter { $0 == SyncSchema.RecordType.sensorState }.count
        let failures = sent.failedRecordSaves.count + sent.failedRecordDeletes.count
        if !sent.savedRecords.isEmpty || !sent.deletedRecordIDs.isEmpty || failures > 0 {
            let removed = sent.deletedRecordIDs.isEmpty ? "" : ", \(sent.deletedRecordIDs.count) deletions"
            let failed = failures == 0 ? "" : " (\(failures) failed, \(retry.count) retried)"
            core.say("sent \(chunks) chunks, \(places) places, \(states) sensor states\(removed)\(failed)")
        }
    }

    /// A failure the engine doesn't handle: try again, a bounded number of
    /// times. Returns whether to queue it again.
    private func retryAfterUnknownError(_ name: String, _ error: CKError, core: SyncCore, deleting: Bool = false) -> Bool {
        let what = deleting ? "delete" : "save"
        let (attempt, again) = retries.failed(name)
        if again {
            core.say("\(what) failed for \(name) (attempt \(attempt) of \(retries.maxAttempts)), trying again: \(error.localizedDescription) [\(error.code.rawValue)]")
        } else {
            core.say("\(what) failed for \(name) \(attempt) times — giving up: \(error.localizedDescription) [\(error.code.rawValue)]")
        }
        return again
    }

    fileprivate func nextBatch(_ context: CKSyncEngine.SendChangesContext,
                               syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard syncEngine === engine, let core else { return nil }
        let pending = syncEngine.state.pendingRecordZoneChanges
            .filter { context.options.scope.contains($0) }
            .sorted { rank($0) < rank($1) }
        guard !pending.isEmpty else { return nil }
        let skipped = SkipBox()
        let batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
            let built: Result<CKRecord, SkipReason>
            if let name = SyncRecordName(id.recordName), id.zoneID.zoneName == SyncSchema.zoneName {
                built = await core.buildRecord(for: name)
            } else {
                built = .failure(SkipReason("not a Kūki history record"))
            }
            switch built {
            case let .success(record):
                return record
            case let .failure(reason):
                skipped.add(id, reason: reason.text)
                return nil
            }
        }
        // Nothing to send for these (or the server has newer): drop them, so
        // they don't come round again — and say why.
        let dropped = skipped.items
        if !dropped.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: dropped.map { .saveRecord($0.id) })
            for item in dropped.prefix(10) { core.say("dropped \(item.id.recordName): \(item.reason)") }
            if dropped.count > 10 { core.say("dropped \(dropped.count - 10) more changes with nothing to send") }
        }
        guard let batch, !(batch.recordsToSave.isEmpty && batch.recordIDsToDelete.isEmpty) else { return nil }
        return batch
    }

    private func rank(_ change: CKSyncEngine.PendingRecordZoneChange) -> (Int, Int) {
        switch change {
        case let .saveRecord(id), let .deleteRecord(id):
            SyncRecordName(id.recordName)?.sendRank ?? (3, 0)
        @unknown default:
            (3, 0)
        }
    }
}

// MARK: - Hooks and outbox

extension HistorySync: SyncOutbox, RecorderSyncHooks {
    @discardableResult
    func enqueueSaves(_ names: [SyncRecordName]) -> Bool {
        guard let engine else {
            core?.say("sync engine isn't running — \(names.count) changes not queued")
            return false
        }
        engine.state.add(pendingRecordZoneChanges: names.map { .saveRecord($0.recordID) })
        return true
    }

    @discardableResult
    func enqueueDeletes(_ names: [SyncRecordName]) -> Bool {
        guard let engine else {
            core?.say("sync engine isn't running — \(names.count) deletions not queued")
            return false
        }
        let ids = names.map(\.recordID)
        // One request can't save and delete the same record.
        engine.state.remove(pendingRecordZoneChanges: ids.map { .saveRecord($0) })
        engine.state.add(pendingRecordZoneChanges: ids.map { .deleteRecord($0) })
        return true
    }

    /// The engine's own schedule may wait, and the only other explicit send
    /// is on going to the background: a move made with the app in front
    /// would sit here. Send a few seconds after the last such change.
    func sendSoon() {
        guard engine != nil else { return }
        sendSoonDebouncer.schedule { [weak self] in
            guard let self, let engine = self.engine else { return }
            do {
                try await engine.sendChanges()
            } catch {
                self.core?.say("send failed: \(error.localizedDescription)")
            }
        }
    }

    func recorderDidRecord(at time: Date, sensorName: String) {
        core?.noteRecorded(at: time, sensorName: sensorName)
    }

    func recorderDidMove(to placeID: UUID, at time: Date) {
        core?.placeMoved(to: placeID, at: time)
    }

    func recorderDidEditPlace(_ place: Place) {
        core?.placeEdited(place)
    }

    func recorderDidDeletePlace(_ place: Place) {
        core?.placeDeleted(id: place.id, name: place.name, kanji: place.kanji,
                           sortIndex: place.sortIndex, createdAt: place.createdAt)
    }

    func recorderWillDeleteAllReadings() {
        core?.ownHistoryWillBeDeleted()
    }
}

/// The engine holds its delegate strongly and calls it from its own queue;
/// this forwards to the main actor and lets a stopped engine's late events
/// fall on the floor (`HistorySync` checks which engine is talking).
private final class EngineDelegate: CKSyncEngineDelegate, @unchecked Sendable {
    weak var owner: HistorySync?

    init(owner: HistorySync) { self.owner = owner }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await owner?.handle(event, from: syncEngine)
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await owner?.nextBatch(context, syncEngine: syncEngine)
    }
}

/// Record ids the batch builder skipped, and why (it calls the provider
/// serially).
private final class SkipBox: @unchecked Sendable {
    struct Item { let id: CKRecord.ID; let reason: String }
    private let lock = NSLock()
    private var stored: [Item] = []
    func add(_ id: CKRecord.ID, reason: String) { lock.lock(); stored.append(Item(id: id, reason: reason)); lock.unlock() }
    var items: [Item] { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class TaskBox: @unchecked Sendable {
    var id: UIBackgroundTaskIdentifier = .invalid
}
