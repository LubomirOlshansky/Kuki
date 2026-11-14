import CloudKit
import Foundation
import os

/// Mirrors the latest reading into the user's *private* iCloud database, so
/// the iPhone widget can follow a Mac that records around the clock.
///
/// One record, one fixed ID ("latest"), overwritten in place — this is a
/// mailbox, not a history. The full history stays local in each app.
///
/// Sync is opt-in by build: the container id comes from the Info.plist key
/// `KukiCloudContainer` (set from the `KUKI_CLOUD_CONTAINER` build setting).
/// Builds signed without iCloud leave it empty, and every call here becomes a
/// no-op — creating a CKContainer without the entitlement would crash.
enum CloudSync {
    private static let log = Logger(subsystem: "com.olshanskysoft.kuki", category: "cloud")
    private static let recordType = "LatestAir"
    private static let recordID = CKRecord.ID(recordName: "latest")

    static var containerID: String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "KukiCloudContainer") as? String
        guard let raw, raw.hasPrefix("iCloud.") else { return nil }
        return raw
    }

    /// The user's switch (Settings › iCloud Sync), stored in the App Group so
    /// the widget extension honours it too. On by default.
    static let userSwitchKey = "cloudSyncOn"
    static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: WidgetSnapshot.appGroup) }

    static var userWantsSync: Bool {
        get { sharedDefaults?.object(forKey: userSwitchKey) as? Bool ?? true }
        set { sharedDefaults?.set(newValue, forKey: userSwitchKey) }
    }

    /// Built with iCloud *and* switched on by the user.
    static var isEnabled: Bool { containerID != nil && userWantsSync }
    /// Whether this build can sync at all (to show the switch).
    static var isAvailable: Bool { containerID != nil }

    private static var database: CKDatabase? {
        // nil when switched off: publish, fetch and subscribe all stand down.
        guard userWantsSync else { return nil }
        return containerID.map { CKContainer(identifier: $0).privateCloudDatabase }
    }

    /// Upload the snapshot, replacing whatever was there. Errors are logged
    /// and swallowed: sync must never disturb recording.
    static func publish(_ snapshot: WidgetSnapshot) async {
        guard let database, !snapshot.isDemo else { return }
        let record = CKRecord(recordType: recordType, recordID: recordID)
        record["co2"] = snapshot.co2
        record["temperature"] = snapshot.temperature
        record["humidity"] = snapshot.humidity
        record["pm25"] = snapshot.pm25
        record["placeName"] = snapshot.placeName
        record["placeKanji"] = snapshot.placeKanji
        record["measuredAt"] = snapshot.measuredAt
        record["recentCO2"] = snapshot.recentCO2
        record["limit"] = snapshot.limit
        do {
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
        } catch {
            log.error("publish failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ask iCloud to wake this device (a silent push) whenever another device
    /// publishes a reading. iOS decides how often to deliver those — roughly
    /// every 15–30 min for an idle phone — which is what keeps the Live
    /// Activity, the widget and CO₂ alerts following the Mac.
    static func ensureSubscription() async {
        guard let database else { return }
        let subscription = CKQuerySubscription(
            recordType: recordType, predicate: NSPredicate(value: true),
            subscriptionID: "latest-air", options: [.firesOnRecordCreation, .firesOnRecordUpdate])
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do {
            _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
        } catch {
            log.error("subscribe failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The latest reading any device published, or nil (offline, signed out,
    /// nothing published yet, or sync disabled). Gives up after `timeout` so a
    /// widget refresh never hangs on the network.
    static func fetchLatest(timeout: Duration = .seconds(6)) async -> WidgetSnapshot? {
        guard let database else { return nil }
        return await withTaskGroup(of: WidgetSnapshot?.self) { group in
            group.addTask {
                do {
                    let record = try await database.record(for: recordID)
                    return snapshot(from: record)
                } catch {
                    log.info("fetch: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    static func snapshot(from record: CKRecord) -> WidgetSnapshot? {
        guard let measuredAt = record["measuredAt"] as? Date else { return nil }
        return WidgetSnapshot(
            co2: record["co2"] as? Double,
            temperature: record["temperature"] as? Double,
            humidity: record["humidity"] as? Double,
            pm25: record["pm25"] as? Double,
            placeName: record["placeName"] as? String ?? "",
            placeKanji: record["placeKanji"] as? String ?? "",
            measuredAt: measuredAt,
            recentCO2: record["recentCO2"] as? [Double] ?? [],
            limit: record["limit"] as? Double ?? 1000,
            isDemo: false
        )
    }

    /// Of two snapshots, the one measured later (nil-safe).
    static func newer(_ a: WidgetSnapshot?, _ b: WidgetSnapshot?) -> WidgetSnapshot? {
        switch (a, b) {
        case let (a?, b?): a.measuredAt >= b.measuredAt ? a : b
        case let (a?, nil): a
        case let (nil, b?): b
        default: nil
        }
    }
}
