#if targetEnvironment(macCatalyst)
import Foundation
import Observation
import SwiftData
import UIKit

/// Must match `KukiStatusBar` in KukiMenuBar/MenuBarController.swift exactly.
@objc(KukiStatusBar) public protocol KukiStatusBar: NSObjectProtocol {
    init()
    /// Must match the plug-in. symbols/values/labels: parallel arrays, one per shown metric;
    /// labels are the spoken form ("CO₂ 812 parts per million") for VoiceOver.
    /// alert: 0 nothing to do · 2 stale air (◐) · 3 poor air (●).
    func update(symbols: [String], values: [String], labels: [String], alert: Int, header: String,
                details: [String], placeNames: [String], placeIDs: [String], currentPlaceID: String)
    func setVisible(_ visible: Bool)
    func setActionHandler(_ handler: @escaping (String) -> Void)
}

/// Loads the AppKit menu bar bundle and keeps it in step with the recorder.
@MainActor
final class MenuBarBridge {
    static let shared = MenuBarBridge()

    private var bar: KukiStatusBar?
    private weak var recorder: Recorder?
    private var container: ModelContainer?

    func start(recorder: Recorder, container: ModelContainer) {
        guard bar == nil else { return }
        self.recorder = recorder
        self.container = container

        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("KukiMenuBar.bundle"),
              let bundle = Bundle(url: url), bundle.load(),
              let cls = bundle.principalClass as? KukiStatusBar.Type else {
            print("Kūki: menu bar bundle not loaded")
            return
        }
        let bar = cls.init()
        bar.setActionHandler { action in
            Task { @MainActor in MenuBarBridge.shared.handle(action) }
        }
        self.bar = bar
        observe()
    }

    /// Re-render whenever anything the menu shows changes.
    private func observe() {
        withObservationTracking {
            push()
        } onChange: {
            Task { @MainActor in MenuBarBridge.shared.observe() }
        }
    }

    private func push() {
        guard let bar, let recorder else { return }
        let snapshot = recorder.current
        let stale = recorder.isSensorStale
        // Out of reach: dashes, no alert mark — an old number would lie.
        let live = stale ? nil : snapshot
        let co2 = live?.co2
        let alert: Int = co2.map { ppm in
            switch CO2Level(ppm: ppm) {
            case .clear, .fine: 0
            case .stale: 2
            case .poor: 3
            }
        } ?? 0
        let shown = recorder.menuBarMetrics.isEmpty ? [Metric.co2] : recorder.menuBarMetrics

        var details: [String] = []
        if stale {
            if let heard = snapshot?.lastHeard {
                details.append("Sensor out of reach · last \(heard.formatted(date: .omitted, time: .shortened))")
            } else {
                details.append("Sensor out of reach")
            }
            details.append("Recording is paused until it's back.")
        } else if let co2 {
            let l = CO2Level(ppm: co2)
            details.append("\(Metric.co2.format(co2)) ppm CO₂ — \(l.title.lowercased())")
            details.append(l.advice)
        } else {
            details.append("Waiting for the sensor…")
        }
        if let s = live {
            var parts: [String] = []
            if let t = s.temperature { parts.append("\(Metric.temperature.format(t)) °C") }
            if let h = s.humidity { parts.append("\(Metric.humidity.format(h)) % humidity") }
            if let p = s.pm25 { parts.append("PM2.5 \(Metric.pm25.format(p))") }
            if !parts.isEmpty { details.append(parts.joined(separator: " · ")) }
        }

        let places = (try? container?.mainContext.fetch(FetchDescriptor<Place>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
        let current = places.first { $0.id == recorder.currentPlaceID }
        bar.setVisible(recorder.showInMenuBar)
        bar.update(
            symbols: shown.map(\.symbol),
            values: shown.map { m in live.map { m.compact(m.value(of: $0)) } ?? "—" },
            labels: shown.map { m in stale ? "\(m.title) unavailable, sensor out of reach" : m.spoken(live.flatMap { m.value(of: $0) }) },
            alert: alert,
            header: current.map { "Sensor in \($0.name)" } ?? "Kūki",
            details: details,
            placeNames: places.map(\.name),
            placeIDs: places.map(\.id.uuidString),
            currentPlaceID: recorder.currentPlaceID?.uuidString ?? ""
        )
    }

    /// Call after places are added/renamed so the submenu catches up.
    func refresh() { push() }

    private func handle(_ action: String) {
        guard let recorder else { return }
        if action.hasPrefix("place:"),
           let id = UUID(uuidString: String(action.dropFirst(6))),
           let place = try? container?.mainContext.fetch(FetchDescriptor<Place>(predicate: #Predicate { $0.id == id })).first {
            recorder.move(to: place)
            return
        }
        switch action {
        case "open":
            showWindow()
        case "station":
            showWindow()
            recorder.stationMode = true
        default:
            break
        }
    }

    private func showWindow() {
        WindowRouter.shared.show(WindowID.main)
    }
}
#endif
