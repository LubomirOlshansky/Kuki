import SwiftData
import SwiftUI

@main
struct KukiApp: App {
    let container: ModelContainer
    @State private var recorder = Recorder()
    @State private var nav = AppNav()
    @UIApplicationDelegateAdaptor(KukiAppDelegate.self) private var appDelegate

    init() {
        do {
            // Our own folder and file name — never SwiftData's shared
            // `default.store`, which unsandboxed Mac builds put straight into
            // ~/Library/Application Support where other apps may use it too.
            let folder = URL.applicationSupportDirectory.appending(path: "Kuki", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // cloudKitDatabase: .none — the history stays on this device. With
            // the iCloud entitlement present, SwiftData would otherwise try to
            // mirror the whole store to CloudKit (and refuse our schema). Only
            // the latest reading syncs, via CloudSync.
            let config = ModelConfiguration("Kuki", url: folder.appending(path: "Kuki.store"),
                                            cloudKitDatabase: .none)
            container = try ModelContainer(for: Place.self, Reading.self, configurations: config)
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
                    recorder.start(container: container)
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
        #endif
    }
}

enum AppTab: Hashable { case now, history, export, settings }

/// Which section is showing, and what History is looking at — shared so
/// menu commands can switch it and File › Export can follow the chart.
@MainActor
@Observable
final class AppNav {
    var tab: AppTab = .now
    var historyRange: ChartRange = .day
    var historyMetric: Metric = .co2
    /// A File › Export request waiting for its save panel (Mac).
    var exportRequest: ExportFile.Kind?
}

struct RootView: View {
    @Environment(Recorder.self) private var recorder
    @Environment(AppNav.self) private var nav
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        @Bindable var recorder = recorder
        @Bindable var nav = nav
        // Symbols that all have filled forms, so the tab bar shows one family.
        // On the Mac, Export lives in the File menu and Settings in its own
        // window: the window keeps just Now and History.
        TabView(selection: $nav.tab) {
            Tab("Now", systemImage: "circle.dotted.circle", value: AppTab.now) { NowView() }
            Tab("History", systemImage: "chart.line.text.clipboard", value: AppTab.history) { HistoryView() }
            #if !targetEnvironment(macCatalyst)
            Tab("Export", systemImage: "square.and.arrow.up", value: AppTab.export) { ExportView() }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) { SettingsView() }
            #endif
        }
        // Three or four destinations don't need a sidebar (or its toggle).
        .tabViewStyle(.tabBarOnly)
        .tint(Ink.ink)
        // Hand the environment over explicitly: on Mac Catalyst a full-screen
        // cover is hosted outside this view tree and doesn't inherit it.
        #if targetEnvironment(macCatalyst)
        // Settings lives in the app menu (⌘,), but a quiet gear in the window
        // corner makes it findable without knowing that.
        .overlay(alignment: .topTrailing) {
            Button {
                WindowRouter.shared.show(WindowID.settings, using: openWindow)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Ink.inkSoft)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle())
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
            .padding(.top, 10)
            .padding(.trailing, 14)
        }
        #endif
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
                      defaultFilename: exportFile.map { Exporter.fileName($0.fileExtension) }) { _ in
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
        .onAppear { WindowRouter.shared.openWindow = openWindow }
        .onChange(of: scenePhase) { _, phase in
            DebugLog.write("scene", "phase → \(phase)")
            if phase == .active { recorder.appBecameActive() }
        }
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
                scene.title = "Kūki Settings"
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
            Button("Export CSV…") { requestExport(.csv) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Export for AI…") { requestExport(.markdown) }
                .keyboardShortcut("e", modifiers: [.command, .shift, .option])
        }
        #endif
        CommandMenu("Air") {
            Button("Now") { show(.now) }.keyboardShortcut("1")
            Button("History") { show(.history) }.keyboardShortcut("2")
            #if !targetEnvironment(macCatalyst)
            Button("Export") { show(.export) }.keyboardShortcut("3")
            #endif
            Divider()
            PlaceCommands(recorder: recorder).modelContainer(container)
            Divider()
            // A toggle, so the same ⌃⌘S that enters Station Mode leaves it.
            Toggle("Station Mode", isOn: Binding(
                get: { recorder.stationMode },
                set: { on in
                    if on { WindowRouter.shared.show(WindowID.main, using: openWindow) }
                    recorder.stationMode = on
                }
            ))
            .keyboardShortcut("s", modifiers: [.command, .control])
            Button("Play Chime") { recorder.previewAlert() }
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
        WindowRouter.shared.show(WindowID.settings, using: openWindow)
        #else
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
