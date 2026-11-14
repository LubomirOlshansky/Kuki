#if targetEnvironment(macCatalyst)
import Foundation
import os
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
    /// Station Mode on the Mac: take the main window into (or out of) the
    /// system's full screen.
    func setFullScreen(_ on: Bool)
    /// false = menu-bar-only app (no Dock icon, macOS "accessory" policy).
    func setDockIconVisible(_ visible: Bool)
    /// Start Kūki when you log in (ServiceManagement). Returns the new state.
    func setOpenAtLogin(_ on: Bool) -> Bool
    func isOpenAtLogin() -> Bool
    /// Make the window titled `title` invisible and inert (the recorder window).
    func hideWindow(titled title: String)
    /// Call `handler` whenever "is any titled window, other than those titled
    /// `excludingTitles`, visible on screen" changes (and once right away).
    func observeWindowVisibility(excludingTitles: [String], handler: @escaping (Bool) -> Void)
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
        applyDockPolicy()
        // A menu-bar app stays "active" with its window hidden or covered;
        // stop the main window's animations while nobody can see them.
        bar.observeWindowVisibility(excludingTitles: [WindowID.recorderTitle, WindowID.settingsTitle]) { visible in
            Task { @MainActor in WindowVisibility.shared.mainWindowVisible = visible }
        }
        #if DEBUG
        // `-closeWindowAfter N` closes every window after N seconds, leaving
        // only the menu bar item (background-recording checks).
        let closeAfter = UserDefaults.standard.integer(forKey: "closeWindowAfter")
        if closeAfter > 0 {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(closeAfter))
                Logger(subsystem: "com.olshanskysoft.kuki", category: "experiment").notice("closing all windows now")
                for session in UIApplication.shared.openSessions
                where (session.scene as? UIWindowScene)?.title != WindowID.recorderTitle {
                    UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
                }
            }
        }
        #endif
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
        let paused = stale && recorder.isPausedInBackground
        // Out of reach: dashes, no alert mark — an old number would lie.
        // Paused in the background: the last numbers, dimmed (alert -1).
        let live = stale ? nil : snapshot
        let shownSnapshot = paused ? snapshot : live
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
        if paused {
            let time = snapshot?.lastHeard?.formatted(date: .omitted, time: .shortened) ?? "—"
            details.append("Paused · last reading \(time)")
            details.append("Apple Home only updates Kūki while it's the front app.")
            details.append("Open Kūki, or use Station Mode to keep recording.")
        } else if stale {
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
        applyDockPolicy()
        bar.update(
            symbols: shown.map(\.symbol),
            values: shown.map { m in shownSnapshot.map { m.compact(m.value(of: $0)) } ?? "—" },
            labels: shown.map { m in
                // Paused: the controller says "Paused" once, for the whole item.
                paused ? m.spoken(snapshot.flatMap { m.value(of: $0) })
                    : stale ? "\(m.title) unavailable, sensor out of reach" : m.spoken(live.flatMap { m.value(of: $0) })
            },
            alert: paused ? -1 : alert,
            header: current.map { "Sensor in \($0.name)" } ?? "Kūki",
            details: details,
            placeNames: places.map(\.name),
            placeIDs: places.map(\.id.uuidString),
            currentPlaceID: recorder.currentPlaceID?.uuidString ?? ""
        )
    }

    /// Station Mode enters and leaves the system's full screen with it.
    private var appliedDock: Bool?

    /// Menu-bar-only (no Dock icon) unless the user asked for the Dock.
    private func applyDockPolicy() {
        guard let bar, let recorder, appliedDock != recorder.showInDock else { return }
        appliedDock = recorder.showInDock
        bar.setDockIconVisible(recorder.showInDock)
        ensureRecorderWindow()
        Logger(subsystem: "com.olshanskysoft.kuki", category: "reach")
            .notice("Dock icon \(recorder.showInDock ? "shown" : "hidden (menu bar app)", privacy: .public)")
    }

    /// Menu-bar mode needs a window to stay "active" for Apple Home: open the
    /// invisible recorder window if it isn't there (and close it when the
    /// user asks for a Dock icon).
    func ensureRecorderWindow() {
        guard let recorder else { return }
        let session = UIApplication.shared.openSessions.first {
            ($0.scene as? UIWindowScene)?.title == WindowID.recorderTitle
        }
        if recorder.showInDock {
            if let session { UIApplication.shared.requestSceneSessionDestruction(session, options: nil) }
        } else if session == nil, let open = WindowRouter.shared.openWindow {
            open(id: WindowID.recorder)
        }
    }

    func hideRecorderWindow() {
        bar?.hideWindow(titled: WindowID.recorderTitle)
    }

    var openAtLogin: Bool { bar?.isOpenAtLogin() ?? false }

    @discardableResult
    func setOpenAtLogin(_ on: Bool) -> Bool { bar?.setOpenAtLogin(on) ?? false }

    func setFullScreen(_ on: Bool) {
        bar?.setFullScreen(on)
    }

    /// Call after places are added/renamed so the submenu catches up.
    func refresh() { push() }

    private func handle(_ action: String) {
        guard let recorder else { return }
        // The menu opened: a sample for analytics, not a request.
        if action == "menuOpened" {
            UsageAnalytics.shared.menuBarMenuOpened()
            return
        }
        // Until the introduction is done, every action just brings it forward.
        guard UserDefaults.standard.bool(forKey: OnboardingKeys.hasCompleted) else {
            showWindow()
            return
        }
        if action.hasPrefix("place:"),
           let id = UUID(uuidString: String(action.dropFirst(6))),
           let place = try? container?.mainContext.fetch(FetchDescriptor<Place>(predicate: #Predicate { $0.id == id })).first {
            recorder.move(to: place, via: "menu_bar")
            return
        }
        switch action {
        case "open":
            showWindow()
        case "station":
            showWindow()
            recorder.stationMode = true
        case "settings":
            Analytics.track("settings_opened", ["via": "menu"])
            WindowRouter.shared.show(WindowID.settings, using: WindowRouter.shared.openWindow)
        default:
            break
        }
    }

    private func showWindow() {
        WindowRouter.shared.show(WindowID.main)
    }
}
#endif
