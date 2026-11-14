import SwiftUI

/// 設定 — the few things worth choosing.
struct SettingsView: View {
    #if targetEnvironment(macCatalyst)
    @State private var openAtLogin = MenuBarBridge.shared.openAtLogin
    #endif
    @State private var cloudSyncOn = CloudSync.userWantsSync
    @State private var shareUsage = Analytics.isEnabled
    @Environment(Recorder.self) private var recorder
    @Environment(AppNav.self) private var nav
    @Environment(\.openWindow) private var openWindow
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
                    Toggle("Demo sensor", isOn: Binding(
                        get: { recorder.useDemo },
                        set: { on in
                            r.useDemo = on
                            Analytics.track("demo_toggled", ["on": on])
                        }
                    ))
                    .tint(Ink.switchOn)
                } header: {
                    Text("Sensor")
                } footer: {
                    Text("Kūki reads the sensor through Apple Home. Apple only gives apps the current value, so the history is what Kūki records while it's running."
                         + (recorder.homeKitRequested ? "" : " Turning the demo off connects Kūki to Apple Home."))
                }

                #if targetEnvironment(macCatalyst)
                Section {
                    Toggle("Show in Dock", isOn: Binding(
                        get: { recorder.showInDock },
                        set: { on in
                            r.showInDock = on
                            Analytics.track("show_in_dock_toggled", ["on": on])
                        }
                    ))
                    .tint(Ink.switchOn)
                    Toggle("Open at Login", isOn: Binding(
                        get: { openAtLogin },
                        set: { on in
                            openAtLogin = MenuBarBridge.shared.setOpenAtLogin(on)
                            Analytics.track("open_at_login_toggled", ["on": openAtLogin])
                        }
                    ))
                    .tint(Ink.switchOn)
                    Toggle("Show in Menu Bar", isOn: $r.showInMenuBar)
                        .tint(Ink.switchOn)
                        .disabled(!recorder.showInDock) // without a Dock icon, the menu bar item is the way in
                    if recorder.showInMenuBar {
                        ForEach(Metric.allCases) { metric in
                            Toggle(isOn: Binding(
                                get: { recorder.menuBarMetrics.contains(metric) },
                                set: {
                                    recorder.setMenuBar(metric, shown: $0)
                                    Analytics.track("menu_bar_metric_changed",
                                                    ["metrics": recorder.menuBarMetrics.map(\.rawValue)])
                                }
                            )) {
                                Label(metric.longTitle, systemImage: metric.symbol)
                            }
                            .tint(Ink.switchOn)
                            .disabled(recorder.menuBarMetrics == [metric]) // keep at least one
                        }
                    }
                } header: {
                    Text("Menu Bar")
                } footer: {
                    Text(recorder.showInDock
                         ? "With a Dock icon, Kūki is a normal app — and Apple Home only updates it while it's in front, so recording pauses in the background."
                         : "Kūki runs from the menu bar, so it keeps recording around the clock — even with its window closed. A small mark appears only when the air needs opening up: ◐ getting stale, ● stuffy.")
                }
                #endif

                Section {
                    Stepper(value: Binding(
                        get: { recorder.co2Limit },
                        set: { limit in
                            r.co2Limit = limit
                            // A few taps on the stepper are one change.
                            Analytics.trackDebounced("co2_limit_changed", ["limit": Int(limit.rounded())])
                        }
                    ), in: 600...2000, step: 50) {
                        LabeledContent("CO₂ limit", value: "\(Metric.co2.format(recorder.co2Limit)) ppm")
                    }
                    Toggle("Wind-chime sound", isOn: Binding(
                        get: { recorder.soundOn },
                        set: { on in
                            r.soundOn = on
                            Analytics.track("chime_toggled", ["on": on])
                        }
                    ))
                    .tint(Ink.switchOn)
                    Toggle("Notification", isOn: Binding(
                        get: { recorder.notifyOn },
                        set: { on in
                            r.notifyOn = on
                            reportNotificationsToggled(on)
                        }
                    ))
                    .tint(Ink.switchOn)
                    Button("Play Chime") {
                        recorder.previewAlert()
                        Analytics.track("chime_played_manually")
                    }
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

                AiringReminderSection(reminders: recorder.reminders, notificationSettingsPath: Self.notificationSettingsPath)

                Section {
                    Picker("Record every", selection: Binding(
                        get: { recorder.intervalMinutes },
                        set: { minutes in
                            r.intervalMinutes = minutes
                            Analytics.track("record_interval_changed", ["minutes": minutes])
                        }
                    )) {
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
                                HistorySync.shared.refresh()
                                Analytics.track("sync_toggled", ["on": on])
                                UsageAnalytics.shared.refreshProperties()
                            }
                        ))
                        .tint(Ink.switchOn)
                    } header: {
                        Text("iCloud")
                    } footer: {
                        VStack(alignment: .leading, spacing: 8) {
                            SyncStatusLine(status: HistorySync.shared.status)
                            Text("Syncs the history each device records, your places and which room the sensor is in between your devices, through your private iCloud. The latest reading also reaches your iPhone's widget, Lock Screen and alerts, so they can follow a Mac that records around the clock.")
                        }
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

                Section {
                    Toggle("Share usage data", isOn: Binding(
                        get: { shareUsage },
                        set: { on in
                            // Off sends nothing more — not even a goodbye.
                            shareUsage = on
                            Analytics.isEnabled = on
                            if on { UsageAnalytics.shared.resendUserProperties() }
                        }
                    ))
                    .tint(Ink.switchOn)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Helps improve Kūki: which features are used, on what device and in which country, linked to a random identifier for this device. Never your readings, room or sensor names.")
                }

                Section {
                    Button("Replay introduction") { replayIntroduction() }
                } header: {
                    Text("Introduction")
                } footer: {
                    Text("Why air matters, how Kūki works, and your plan — a few minutes.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Ink.paper)
            .toolbar(.hidden, for: .navigationBar)
            .confirmationDialog("Delete every recording?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { recorder.deleteReadings(demoOnly: false) }
            } message: {
                Text(deleteMessage)
            }
        }
    }

    /// `notifications_toggled`, with the permission the system ended up
    /// with: the answer to the request when turning on, the current state
    /// when turning off.
    private func reportNotificationsToggled(_ on: Bool) {
        let request = on ? recorder.notificationRequest : nil
        Task {
            let permission: String
            if let request {
                permission = await request.value ? "granted" : "denied"
            } else {
                permission = await NotificationPermission.current()
            }
            Analytics.track("notifications_toggled", ["on": on, "permission": permission])
        }
    }

    private func replayIntroduction() {
        Analytics.track("onboarding_replayed")
        nav.replayingOnboarding = true
        #if targetEnvironment(macCatalyst)
        WindowRouter.shared.show(WindowID.main, using: openWindow)
        #else
        nav.tab = .now
        #endif
    }

    /// What "Delete all" really reaches, with sync on or off.
    private var deleteMessage: String {
        let last = "Places are kept. This can't be undone — export first if you want a copy."
        guard CloudSync.isAvailable else { return last }
        return HistorySync.shared.isRunning
            ? "What this device recorded is also deleted from iCloud and your other devices. Readings from your other devices are removed here only. \(last)"
            : "iCloud Sync is off: copies already in iCloud and on your other devices stay. \(last)"
    }
}

/// "Synced 2 min ago" / "Waiting for iCloud" / "Off" — kept current by the
/// minute.
private struct SyncStatusLine: View {
    let status: HistorySync.Status

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(text(now: context.date))
                .foregroundStyle(Ink.ink)
        }
    }

    private func text(now: Date) -> String {
        switch status {
        case .off: "Off"
        case .waiting: "Waiting for iCloud"
        case let .problem(message): message
        case let .synced(date):
            now.timeIntervalSince(date) < 60
                ? "Synced just now"
                : "Synced \(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))"
        }
    }
}

/// 窓 The opt-in airing reminder: on/off and one to three daily times.
private struct AiringReminderSection: View {
    @Bindable var reminders: AiringReminders
    let notificationSettingsPath: String

    var body: some View {
        Section {
            Toggle("Airing reminder", isOn: $reminders.isOn)
                .tint(Ink.switchOn)
            if reminders.isOn {
                ForEach(reminders.times, id: \.self) { time in
                    HStack {
                        DatePicker("Remind at", selection: Binding(
                            get: { time.date() },
                            set: { new in
                                reminders.times = reminders.times.map { $0 == time ? ReminderTime(date: new) : $0 }
                            }), displayedComponents: .hourAndMinute)
                        if reminders.times.count > 1 {
                            Button {
                                reminders.remove(time)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(Ink.inkSoft)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(time.date().formatted(date: .omitted, time: .shortened))")
                        }
                    }
                }
                if reminders.times.count < AiringReminder.maxTimes {
                    Button("Add a time") { reminders.add(nextFreeTime) }
                }
            }
        } header: {
            Text("Airing reminder")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if reminders.denied {
                    Text("Notifications are turned off for Kūki. To get reminders, allow Kūki in \(notificationSettingsPath), then turn the reminder on again.")
                        .foregroundStyle(Ink.ink)
                }
                Text("A daily reminder to open a window wide for 5 minutes. It comes at the times you set: it can't read the air, so it may arrive when the room is already fresh.")
            }
        }
    }

    /// A sensible extra time: midday, else the first free hour after the last.
    private var nextFreeTime: ReminderTime {
        let noon = ReminderTime(hour: 13)
        if !reminders.times.contains(noon) { return noon }
        let last = reminders.times.max() ?? noon
        return ReminderTime(hour: (last.hour + 2) % 24, minute: last.minute)
    }
}
