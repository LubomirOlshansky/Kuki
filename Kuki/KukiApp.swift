import SwiftData
import SwiftUI

@main
struct KukiApp: App {
    let container: ModelContainer
    @State private var recorder = Recorder()
    @State private var nav = AppNav()
    @UIApplicationDelegateAdaptor(KukiAppDelegate.self) private var appDelegate

    init() {
        // First thing: sessions and app-lifecycle events start here (only in
        // the real app, never under tests, never with sharing turned off).
        AmplitudeBackend.shared.start()
        do {
            // Our own folder and file name — never SwiftData's shared
            // `default.store`, which unsandboxed Mac builds put straight into
            // ~/Library/Application Support where other apps may use it too.
            let folder = URL.applicationSupportDirectory.appending(path: "Kuki", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // cloudKitDatabase: .none — the history stays on this device. With
            // the iCloud entitlement present, SwiftData would otherwise try to
            // mirror the whole store to CloudKit (and refuse our schema) — a
            // record per reading. The latest reading syncs via CloudSync, and
            // history in hour chunks via HistorySync (CKSyncEngine).
            let config = ModelConfiguration("Kuki", url: folder.appending(path: "Kuki.store"),
                                            cloudKitDatabase: .none)
            let store = try ModelContainer(for: Place.self, Reading.self, configurations: config)
            container = store
            // Before any window: a silent push may have launched the app.
            HistorySync.shared.configure(container: store)
        } catch {
            fatalError("Could not open the Kūki store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup(id: WindowID.main) {
            RootView()
                .environment(recorder)
                .environment(nav)
                .task {
                    // Attach first, so sync can follow a place merge before
                    // configure falls back to the first place.
                    HistorySync.shared.attach(recorder)
                    recorder.start(container: container)
                    UsageAnalytics.shared.start(recorder: recorder, container: container)
                    #if targetEnvironment(macCatalyst)
                    MenuBarBridge.shared.start(recorder: recorder, container: container)
                    #endif
                }
        }
        .modelContainer(container)
        .commands { KukiCommands(recorder: recorder, nav: nav, container: container) }

        #if targetEnvironment(macCatalyst)
        // On the Mac, Settings is its own small window (HIG › Settings),
        // opened with ⌘, — not a section of the main window.
        WindowGroup("Kūki Settings", id: WindowID.settings) {
            SettingsWindow()
                .environment(recorder)
                .environment(nav)
        }
        .modelContainer(container)

        // Apple Home talks to a menu-bar-only Mac app only while it has a
        // window. This one is invisible (zero alpha, no clicks, not in the
        // Window menu or ⌘-Tab), so Kūki keeps recording after you close the
        // main window.
        WindowGroup(WindowID.recorderTitle, id: WindowID.recorder) {
            Color.clear
                .frame(width: 1, height: 1)
                .background(SceneReader { scene in
                    WindowRouter.shared.register(scene, as: WindowID.recorder)
                    scene.title = WindowID.recorderTitle
                    scene.sizeRestrictions?.minimumSize = CGSize(width: 1, height: 1)
                    scene.sizeRestrictions?.maximumSize = CGSize(width: 1, height: 1)
                    scene.titlebar?.titleVisibility = .hidden
                    MenuBarBridge.shared.hideRecorderWindow()
                })
        }
        #endif
    }
}

enum AppTab: Hashable { case now, history, export, settings }

/// Which section is showing, and what History is looking at — shared so
/// menu commands can switch it and File › Export can follow the chart.
@MainActor
@Observable
final class AppNav {
    var tab: AppTab = {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "startTab") {
        case "history": return .history
        case "export": return .export
        case "settings": return .settings
        default: return .now
        }
        #else
        return .now
        #endif
    }()
    var historyRange: ChartRange = .day
    var historyMetric: Metric = .co2
    /// A File › Export request waiting for its save panel (Mac).
    var exportRequest: ExportFile.Kind?
    /// Settings › Replay introduction.
    var replayingOnboarding = false
    /// Mirrors `hasCompletedOnboarding`, so menu commands can follow it.
    var introductionDone = UserDefaults.standard.bool(forKey: OnboardingKeys.hasCompleted)
}

struct RootView: View {
    @Environment(Recorder.self) private var recorder
    @Environment(AppNav.self) private var nav
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(OnboardingKeys.hasCompleted) private var hasCompletedOnboarding = false

    /// The introduction replaces the tabs (a root swap, not a cover): Now stays
    /// unmounted until it ends, so its first ensō paint is the handoff.
    private var showOnboarding: Bool { !hasCompletedOnboarding || nav.replayingOnboarding }

    var body: some View {
        @Bindable var recorder = recorder
        Group {
            if showOnboarding {
                OnboardingFlow(mode: hasCompletedOnboarding ? .replay : .firstRun)
                    .transition(.opacity)
            } else {
                tabs.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.25 : 0.5), value: showOnboarding)
        .tint(Ink.ink)
        .environment(\.motionPaused, !WindowVisibility.shared.mainWindowVisible)
        // Hand the environment over explicitly: on Mac Catalyst a full-screen
        // cover is hosted outside this view tree and doesn't inherit it.
        // (Mac Settings: the app menu's Settings… (⌘,) and the menu bar item.)
        .fullScreenCover(isPresented: $recorder.stationMode) {
            StationView()
                .environment(recorder)
                .environment(nav)
                .environment(\.modelContext, modelContext)
        }
        .fileExporter(isPresented: Binding(get: { nav.exportRequest != nil },
                                           set: { if !$0 { nav.exportRequest = nil } }),
                      item: exportFile,
                      contentTypes: exportFile.map { [$0.contentType] } ?? [],
                      defaultFilename: exportFile.map { Exporter.fileName($0.fileExtension) }) { result in
            if case .success = result, let kind = nav.exportRequest {
                UsageAnalytics.shared.exportPerformed(format: kind, action: "save", range: nav.historyRange.rawValue)
            }
            nav.exportRequest = nil
        } onCancellation: {
            nav.exportRequest = nil
        }
        .background(SceneReader { scene in
            WindowRouter.shared.register(scene, as: WindowID.main)
            #if targetEnvironment(macCatalyst)
            // The washi runs up to the traffic lights: no title text (the
            // window *is* Kūki), a unified bar for the tabs, and a minimum
            // size the two-column layout still fits in.
            scene.titlebar?.titleVisibility = .hidden
            scene.titlebar?.toolbarStyle = .unified
            scene.sizeRestrictions?.minimumSize = CGSize(width: 560, height: 620)
            #endif
        })
        .onAppear {
            WindowRouter.shared.openWindow = openWindow
            #if DEBUG && targetEnvironment(macCatalyst)
            DebugSnapshot.runIfRequested()
            #endif
            #if targetEnvironment(macCatalyst)
            MenuBarBridge.shared.ensureRecorderWindow()
            // First launch (also at login): the introduction is in this window.
            if !hasCompletedOnboarding { WindowRouter.shared.show(WindowID.main, using: openWindow) }
            #endif
            syncOnboarding()
        }
        .onChange(of: hasCompletedOnboarding) {
            syncOnboarding()
            UsageAnalytics.shared.refreshProperties()
        }
        .onChange(of: scenePhase) { _, phase in
            DebugLog.write("scene", "phase → \(phase)")
            if phase == .active {
                recorder.appBecameActive()
                UsageAnalytics.shared.appBecameActive()
            }
            // Hand queued events to Amplitude before iOS freezes the app.
            if phase == .background { AmplitudeBackend.shared.flush() }
        }
        .onChange(of: nav.tab) { _, tab in UsageAnalytics.shared.tabViewed(tab) }
        .onChange(of: nav.historyRange) { UsageAnalytics.shared.historyViewed(range: nav.historyRange, metric: nav.historyMetric) }
        .onChange(of: nav.historyMetric) { UsageAnalytics.shared.historyViewed(range: nav.historyRange, metric: nav.historyMetric) }
    }

    /// Nothing is recorded or rung while the introduction is still choosing a
    /// sensor and a place (replay doesn't hold).
    private func syncOnboarding() {
        recorder.holdRecording = !hasCompletedOnboarding
        nav.introductionDone = hasCompletedOnboarding
    }

    private var tabs: some View {
        @Bindable var nav = nav
        // Symbols that all have filled forms, so the tab bar shows one family.
        // On the Mac, Export lives in the File menu and Settings in its own
        // window: the window keeps just Now and History.
        return TabView(selection: $nav.tab) {
            Tab("Now", systemImage: "circle.dotted.circle", value: AppTab.now) { NowView() }
            Tab("History", systemImage: "chart.line.text.clipboard", value: AppTab.history) { HistoryView() }
            #if !targetEnvironment(macCatalyst)
            Tab("Export", systemImage: "square.and.arrow.up", value: AppTab.export) { ExportView() }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) { SettingsView() }
            #endif
        }
        // Three or four destinations don't need a sidebar (or its toggle).
        .tabViewStyle(.tabBarOnly)
        // The tab showing when the tabs appear (launch, end of the introduction).
        .onAppear { UsageAnalytics.shared.tabViewed(nav.tab) }
    }

    /// What File › Export… writes: the period History is showing.
    private var exportFile: ExportFile? {
        guard let kind = nav.exportRequest else { return nil }
        return ExportFile(kind: kind, since: nav.historyRange.start, limit: recorder.co2Limit,
                          sensor: recorder.sensorName, filter: recorder.sensorFilter, container: modelContext.container)
    }
}

#if targetEnvironment(macCatalyst)
/// The Mac Settings window: titled, fixed size.
private struct SettingsWindow: View {
    static let size = CGSize(width: 520, height: 680)

    var body: some View {
        SettingsView()
            .background(SceneReader { scene in
                WindowRouter.shared.register(scene, as: WindowID.settings)
                scene.title = WindowID.settingsTitle
                scene.sizeRestrictions?.minimumSize = Self.size
                scene.sizeRestrictions?.maximumSize = Self.size
                scene.sizeRestrictions?.allowsFullScreen = false
            })
    }
}
#endif

/// Every action is reachable from the Mac menu bar, with standard shortcuts
/// where they exist (HIG › The menu bar). ⌘1… follow the tab order.
struct KukiCommands: Commands {
    let recorder: Recorder
    let nav: AppNav
    let container: ModelContainer
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openSettings() }
                .keyboardShortcut(",")
        }
        // One main window by design: a second one would share its tab and
        // Station Mode with the first.
        CommandGroup(replacing: .newItem) {}
        #if targetEnvironment(macCatalyst)
        // HIG › The menu bar: exporting belongs in the File menu. Both follow
        // the period History is showing.
        CommandGroup(replacing: .importExport) {
            Group {
                Button("Export CSV…") { requestExport(.csv) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Export for AI…") { requestExport(.markdown) }
                    .keyboardShortcut("e", modifiers: [.command, .shift, .option])
            }
            .disabled(!nav.introductionDone)
        }
        #endif
        CommandMenu("Air") {
            Group {
                Button("Now") { show(.now) }.keyboardShortcut("1")
                Button("History") { show(.history) }.keyboardShortcut("2")
                #if !targetEnvironment(macCatalyst)
                Button("Export") { show(.export) }.keyboardShortcut("3")
                #endif
                Divider()
                PlaceCommands(recorder: recorder).modelContainer(container)
                Divider()
            }
            .disabled(!nav.introductionDone)
            // A toggle, so the same ⌃⌘S that enters Station Mode leaves it.
            Toggle("Station Mode", isOn: Binding(
                get: { recorder.stationMode },
                set: { on in
                    if on { WindowRouter.shared.show(WindowID.main, using: openWindow) }
                    recorder.stationMode = on
                }
            ))
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(!nav.introductionDone)
            Button("Play Chime") {
                recorder.previewAlert()
                Analytics.track("chime_played_manually")
            }
        }
    }

    /// Switch section and make sure a main window is there to show it.
    private func show(_ tab: AppTab) {
        nav.tab = tab
        WindowRouter.shared.show(WindowID.main, using: openWindow)
    }

    private func requestExport(_ kind: ExportFile.Kind) {
        WindowRouter.shared.show(WindowID.main, using: openWindow)
        nav.exportRequest = kind
    }

    private func openSettings() {
        #if targetEnvironment(macCatalyst)
        Analytics.track("settings_opened", ["via": "cmd_comma"])
        WindowRouter.shared.show(WindowID.settings, using: openWindow)
        #else
        if nav.tab != .settings { UsageAnalytics.shared.pendingSettingsVia = "cmd_comma" }
        show(.settings)
        #endif
    }
}

/// "Move Sensor To ▸" with the live list of places.
private struct PlaceCommands: View {
    let recorder: Recorder
    @Query(sort: \Place.sortIndex) private var places: [Place]

    var body: some View {
        Menu("Move Sensor To") {
            ForEach(places) { place in
                Toggle(place.name, isOn: Binding(
                    get: { recorder.currentPlaceID == place.id },
                    set: { if $0 { recorder.move(to: place) } }
                ))
            }
        }
    }
}
