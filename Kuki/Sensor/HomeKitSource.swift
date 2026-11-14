import Foundation
import HomeKit
import Observation
import os

/// One air sensor found in Apple Home.
struct SensorInfo: Identifiable, Equatable {
    let id: UUID
    let name: String
    let room: String
    let manufacturer: String
    let isReachable: Bool
}

/// Reads air sensors (e.g. IKEA ALPSTUGA added to Apple Home) through HomeKit.
/// HomeKit only gives *current* values, and only while the app is running —
/// the history in Kūki is what the app itself records.
@MainActor
@Observable
final class HomeKitSource: NSObject {
    enum Status: Equatable {
        case starting
        case notAuthorized
        case noHomes
        case noSensors
        case ready
    }

    private(set) var status: Status = .starting
    private(set) var sensors: [SensorInfo] = []
    private(set) var snapshots: [UUID: SensorSnapshot] = [:]

    /// Called after any value or reachability change, so the recorder can
    /// re-judge staleness straight away instead of on its next tick.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var manager: HMHomeManager?
    @ObservationIgnored private var accessories: [UUID: HMAccessory] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.olshanskysoft.kuki", category: "HomeKit")

    private static let co2Type = HMCharacteristicTypeCarbonDioxideLevel
    private static let tempType = HMCharacteristicTypeCurrentTemperature
    private static let humidityType = HMCharacteristicTypeCurrentRelativeHumidity
    private static let pm25Type = HMCharacteristicTypePM2_5Density
    private static let airQualityType = HMCharacteristicTypeAirQuality

    private static let wanted: Set<String> = [co2Type, tempType, humidityType, pm25Type, airQualityType]

    func start() {
        guard manager == nil else { return }
        let manager = HMHomeManager()
        manager.delegate = self
        self.manager = manager
    }

    /// Ask every sensor for fresh values. Values also arrive on their own via
    /// notifications; this is the safety net for sensors that report lazily.
    /// Only a successful read counts as hearing from the sensor; a failed one
    /// leaves the old value (and its old date) alone.
    func refresh() async {
        for accessory in accessories.values where accessory.isReachable {
            for characteristic in relevantCharacteristics(of: accessory) {
                do {
                    try await characteristic.readValue()
                    apply(characteristic, of: accessory, heard: true)
                } catch {
                    log.error("Reading \(characteristic.localizedDescription, privacy: .public) from \(accessory.name, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Discovery

    private func rescan() {
        guard let manager else { return }
        if manager.authorizationStatus.contains(.determined),
           !manager.authorizationStatus.contains(.authorized) {
            status = .notAuthorized
            return
        }
        guard !manager.homes.isEmpty else {
            status = manager.authorizationStatus.contains(.determined) ? .noHomes : .starting
            return
        }

        var found: [UUID: HMAccessory] = [:]
        for home in manager.homes {
            home.delegate = self
            for accessory in home.accessories where isAirSensor(accessory) {
                found[accessory.uniqueIdentifier] = accessory
            }
        }
        accessories = found
        sensors = found.values
            .map { a in
                SensorInfo(id: a.uniqueIdentifier,
                           name: a.name,
                           room: a.room?.name ?? "",
                           manufacturer: a.manufacturer ?? "",
                           isReachable: a.isReachable)
            }
            .sorted { lhs, rhs in
                // IKEA first, then alphabetical — the ALPSTUGA is the point.
                let l = lhs.manufacturer.localizedCaseInsensitiveContains("ikea")
                let r = rhs.manufacturer.localizedCaseInsensitiveContains("ikea")
                return l != r ? l : lhs.name < rhs.name
            }
        status = sensors.isEmpty ? .noSensors : .ready

        // Forget sensors that left the home; keep the reachability of the rest current.
        snapshots = snapshots.filter { found[$0.key] != nil }
        for accessory in found.values {
            accessory.delegate = self
            setReachable(accessory)
            for characteristic in relevantCharacteristics(of: accessory) {
                // Cached value for an instant first paint — but not "heard":
                // it may be hours old, so it's never logged or alerted on.
                apply(characteristic, of: accessory, heard: false)
                if characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification),
                   !characteristic.isNotificationEnabled {
                    characteristic.enableNotification(true) { _ in }
                }
            }
        }
        onChange?()
        Task { await refresh() }
    }

    /// An air sensor has CO₂, PM2.5 or an air-quality rating. A plain
    /// thermometer (or a thermostat) is not what Kūki is for.
    private func isAirSensor(_ accessory: HMAccessory) -> Bool {
        let types = Set(accessory.services.flatMap { $0.characteristics.map(\.characteristicType) })
        return types.contains(Self.co2Type) || types.contains(Self.pm25Type) || types.contains(Self.airQualityType)
    }

    private func relevantCharacteristics(of accessory: HMAccessory) -> [HMCharacteristic] {
        accessory.services.flatMap(\.characteristics).filter { Self.wanted.contains($0.characteristicType) }
    }

    private func metric(for type: String) -> Metric? {
        switch type {
        case Self.co2Type: .co2
        case Self.tempType: .temperature
        case Self.humidityType: .humidity
        case Self.pm25Type: .pm25
        default: nil
        }
    }

    private func setReachable(_ accessory: HMAccessory) {
        let id = accessory.uniqueIdentifier
        var snapshot = snapshots[id] ?? SensorSnapshot()
        guard snapshots[id] == nil || snapshot.isReachable != accessory.isReachable else { return }
        snapshot.isReachable = accessory.isReachable
        snapshots[id] = snapshot
    }

    /// `heard`: the value just came from the sensor (a notification or a
    /// successful read), so it gets a fresh date.
    private func apply(_ characteristic: HMCharacteristic, of accessory: HMAccessory, heard: Bool) {
        guard let metric = metric(for: characteristic.characteristicType),
              let number = characteristic.value as? NSNumber else { return }
        let id = accessory.uniqueIdentifier
        var snapshot = snapshots[id] ?? SensorSnapshot()
        snapshot[metric] = number.doubleValue
        if heard {
            snapshot.heardAt[metric] = .now
            snapshot.isReachable = true
        }
        snapshots[id] = snapshot
        onChange?()
    }
}

extension HomeKitSource: HMHomeManagerDelegate {
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in self.rescan() }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        Task { @MainActor in self.rescan() }
    }
}

extension HomeKitSource: HMHomeDelegate {
    nonisolated func home(_ home: HMHome, didAdd accessory: HMAccessory) {
        Task { @MainActor in self.rescan() }
    }

    nonisolated func home(_ home: HMHome, didRemove accessory: HMAccessory) {
        Task { @MainActor in self.rescan() }
    }

    nonisolated func home(_ home: HMHome, didUpdate room: HMRoom, for accessory: HMAccessory) {
        Task { @MainActor in self.rescan() }
    }
}

extension HomeKitSource: HMAccessoryDelegate {
    nonisolated func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        Task { @MainActor in self.apply(characteristic, of: accessory, heard: true) }
    }

    nonisolated func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        Task { @MainActor in self.rescan() }
    }
}
