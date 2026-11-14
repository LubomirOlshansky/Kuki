import SwiftUI

/// 設定 — the few things worth choosing.
struct SettingsView: View {
    @State private var cloudSyncOn = CloudSync.userWantsSync
    @Environment(Recorder.self) private var recorder
    @State private var confirmDelete = false

    private static var notificationSettingsPath: String {
        #if targetEnvironment(macCatalyst)
        "System Settings › Notifications"
        #else
        "Settings › Notifications"
        #endif
    }

    var body: some View {
        @Bindable var r = recorder
        NavigationStack {
            Form {
                #if !targetEnvironment(macCatalyst)
                // On the Mac the window's own title ("Kūki Settings") is the
                // title (HIG › Settings) — no second one inside it.
                Section {
                } header: {
                    PageTitle(kanji: "設定", title: "Settings")
                        .textCase(nil)
                        .padding(.top, 12)
                }
                #endif

                Section {
                    if recorder.homeKit.sensors.isEmpty {
                        Text(recorder.useDemo ? "Using the demo sensor" : "No air sensor found in Apple Home")
                            .foregroundStyle(Ink.inkSoft)
                    } else {
                        Picker("Sensor", selection: Binding(
                            get: { recorder.activeSensor?.id },
                            set: { r.selectedSensorID = $0 }
                        )) {
                            ForEach(recorder.homeKit.sensors) { s in
                                Text(s.room.isEmpty ? s.name : "\(s.name) · \(s.room)").tag(Optional(s.id))
                            }
                        }
                    }
                    Toggle("Demo sensor", isOn: $r.useDemo)
                } header: {
                    Text("Sensor")
                } footer: {
                    Text("Kūki reads the sensor through Apple Home. Apple only gives apps the current value, so the history is what Kūki records while it's running.")
                }

                #if targetEnvironment(macCatalyst)
                Section {
                    Toggle("Show in Menu Bar", isOn: $r.showInMenuBar)
                    if recorder.showInMenuBar {
                        ForEach(Metric.allCases) { metric in
                            Toggle(isOn: Binding(
                                get: { recorder.menuBarMetrics.contains(metric) },
                                set: { recorder.setMenuBar(metric, shown: $0) }
                            )) {
                                Label(metric.longTitle, systemImage: metric.symbol)
                            }
                            .disabled(recorder.menuBarMetrics == [metric]) // keep at least one
                        }
                    }
                } header: {
                    Text("Menu Bar")
                } footer: {
                    Text("Choose what sits next to the clock. A small mark appears only when the air needs opening up: ◐ getting stale, ● stuffy.")
                }
                #endif

                Section {
                    Stepper(value: $r.co2Limit, in: 600...2000, step: 50) {
                        LabeledContent("CO₂ limit", value: "\(Metric.co2.format(recorder.co2Limit)) ppm")
                    }
                    Toggle("Wind-chime sound", isOn: $r.soundOn)
                    Toggle("Notification", isOn: $r.notifyOn)
                    Button("Play the chime") { recorder.previewAlert() }
                } header: {
                    Text("Alert")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        if recorder.notificationsDenied {
                            Text("Notifications are turned off for Kūki. To get them, allow Kūki in \(Self.notificationSettingsPath), then turn Notification on again.")
                                .foregroundStyle(Ink.ink)
                        }
                        Text("A soft fūrin rings once when CO₂ reaches the limit, then stays quiet until the air has clearly recovered. 1000 ppm is the usual \"open a window\" line.")
                    }
                }

                Section {
                    Picker("Record every", selection: $r.intervalMinutes) {
                        ForEach([1, 2, 5, 10], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    Picker("Settling after a move", selection: $r.settleMinutes) {
                        ForEach([0, 5, 10, 15, 20], id: \.self) { Text($0 == 0 ? "Off" : "\($0) min").tag($0) }
                    }
                } header: {
                    Text("Recording")
                }

                if CloudSync.isAvailable {
                    Section {
                        Toggle("iCloud Sync", isOn: Binding(
                            get: { cloudSyncOn },
                            set: { on in
                                cloudSyncOn = on
                                CloudSync.userWantsSync = on
                                if on { Task { await CloudSync.ensureSubscription() } }
                            }
                        ))
                    } header: {
                        Text("iCloud")
                    } footer: {
                        Text("Shares only the latest reading, through your private iCloud, so your iPhone's widget, Lock Screen and alerts can follow a Mac that records around the clock. Your history stays on each device.")
                    }
                }

                Section {
                    if recorder.useDemo {
                        Button("Add 3 days of demo history") { recorder.seedDemoHistory() }
                        Button("Delete demo data", role: .destructive) { recorder.deleteReadings(demoOnly: true) }
                    }
                    Button("Delete all recordings", role: .destructive) { confirmDelete = true }
                } header: {
                    Text("Data")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Ink.paper)
            .toolbar(.hidden, for: .navigationBar)
            .confirmationDialog("Delete every recording?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { recorder.deleteReadings(demoOnly: false) }
            } message: {
                Text("Places are kept. This can't be undone — export first if you want a copy.")
            }
        }
    }
}
