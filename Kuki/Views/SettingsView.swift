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
        String(localized: "System Settings › Notifications",
               comment: "Path to the Mac's notification settings, used inside a sentence. Use the names macOS shows in your language.")
        #else
        String(localized: "Settings › Notifications",
               comment: "Path to the iPhone/iPad notification settings, used inside a sentence. Use the names iOS shows in your language.")
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
                        Group {
                            if recorder.useDemo {
                                Text("Using the demo sensor", comment: "Settings › Sensor: shown instead of a sensor picker while the built-in demo sensor is on")
                            } else {
                                Text("No air sensor found in Apple Home", comment: "Settings › Sensor: no sensor available")
                            }
                        }
                        .foregroundStyle(Ink.inkSoft)
                    } else {
                        Picker("Sensor", selection: Binding(
                            get: { recorder.activeSensor?.id },
                            set: { r.selectedSensorID = $0 }
                        )) {
                            ForEach(recorder.homeKit.sensors) { s in
                                Text(verbatim: s.room.isEmpty ? s.name : "\(s.name) · \(s.room)").tag(Optional(s.id))
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
                    if recorder.homeKitRequested {
                        Text("Kūki reads the sensor through Apple Home. Apple only gives apps the current value, so the history is what Kūki records while it's running.",
                             comment: "Settings › Sensor footer")
                    } else {
                        Text("Kūki reads the sensor through Apple Home. Apple only gives apps the current value, so the history is what Kūki records while it's running. Turning the demo off connects Kūki to Apple Home.",
                             comment: "Settings › Sensor footer, before Kūki has asked for Apple Home access (the demo sensor is on)")
                    }
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
                    if recorder.showInDock {
                        Text("With a Dock icon, Kūki is a normal app — and Apple Home only updates it while it's in front, so recording pauses in the background.",
                             comment: "Settings › Menu Bar footer (Mac) when Show in Dock is on")
                    } else {
                        Text("Kūki runs from the menu bar, so it keeps recording around the clock — even with its window closed. A small mark appears only when the air needs opening up: ◐ getting stale, ● stuffy.",
                             comment: "Settings › Menu Bar footer (Mac). Keep the ◐ and ● symbols. 'Getting stale' and 'stuffy' describe indoor air quality, as in the CO₂ level names.")
                    }
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
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Toggle(String(localized: "Wind-chime sound", comment: "Settings › Alert: toggle for the soft wind-bell (fūrin) sound when CO₂ reaches the limit"), isOn: Binding(
                        get: { recorder.soundOn },
                        set: { on in
                            r.soundOn = on
                            Analytics.track("chime_toggled", ["on": on])
                        }
                    ))
                    .tint(Ink.switchOn)
                    Toggle(String(localized: "Notification", comment: "Settings › Alert: toggle for a notification when CO₂ reaches the limit"), isOn: Binding(
                        get: { recorder.notifyOn },
                        set: { on in
                            r.notifyOn = on
                            reportNotificationsToggled(on)
                        }
                    ))
                    .tint(Ink.switchOn)
                    Button(String(localized: "Play Chime", comment: "Settings › Alert: button that plays the wind-chime (fūrin) sound once, as a preview")) {
                        recorder.previewAlert()
                        Analytics.track("chime_played_manually")
                    }
                } header: {
                    Text("Alert", comment: "Settings: section header for the CO₂ limit alert (noun)")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        if recorder.notificationsDenied {
                            Text("Notifications are turned off for Kūki. To get them, allow Kūki in \(Self.notificationSettingsPath), then turn Notification on again.",
                                 comment: "Settings › Alert footer. Placeholder is the settings path, e.g. 'Settings › Notifications'. 'Notification' is the toggle's name above.")
                                .foregroundStyle(Ink.ink)
                        }
                        Text("A soft fūrin rings once when CO₂ reaches the limit, then stays quiet until the air has clearly recovered. 1000 ppm is the usual \"open a window\" line.",
                             comment: "Settings › Alert footer. 'fūrin' = a Japanese wind chime; keep the word fūrin.")
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
                        ForEach([1, 2, 5, 10], id: \.self) { minutes in
                            Text("\(minutes) min", comment: "Settings › Recording: an interval option in minutes (abbreviated)").tag(minutes)
                        }
                    }
                    Picker(String(localized: "Settling after a move", comment: "Settings › Recording: how many minutes after moving the sensor to a new room are left out of comparisons, while its CO₂ cell adapts"), selection: $r.settleMinutes) {
                        ForEach([0, 5, 10, 15, 20], id: \.self) { minutes in
                            Group {
                                if minutes == 0 {
                                    Text("Off", comment: "Settings › Recording › Settling after a move: no settling period")
                                } else {
                                    Text("\(minutes) min", comment: "Settings › Recording: an interval option in minutes (abbreviated)")
                                }
                            }
                            .tag(minutes)
                        }
                    }
                } header: {
                    Text("Recording")
                }

                if CloudSync.isAvailable {
                    Section {
                        Toggle(String(localized: "iCloud Sync", comment: "Settings › iCloud: toggle. 'iCloud' is a proper name."), isOn: Binding(
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
        guard CloudSync.isAvailable else {
            return String(localized: "Places are kept. This can't be undone — export first if you want a copy.",
                          comment: "Settings: message of the 'Delete every recording?' confirmation (no iCloud)")
        }
        return HistorySync.shared.isRunning
            ? String(localized: "What this device recorded is also deleted from iCloud and your other devices. Readings from your other devices are removed here only. Places are kept. This can't be undone — export first if you want a copy.",
                     comment: "Settings: message of the 'Delete every recording?' confirmation, iCloud Sync on")
            : String(localized: "iCloud Sync is off: copies already in iCloud and on your other devices stay. Places are kept. This can't be undone — export first if you want a copy.",
                     comment: "Settings: message of the 'Delete every recording?' confirmation, iCloud Sync off")
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
        case .off: String(localized: "Off", comment: "Settings › iCloud footer: sync status when iCloud Sync is off")
        case .waiting: String(localized: "Waiting for iCloud", comment: "Settings › iCloud footer: sync status")
        case let .problem(message): message
        case let .synced(date):
            now.timeIntervalSince(date) < 60
                ? String(localized: "Synced just now", comment: "Settings › iCloud footer: sync status")
                : String(localized: "Synced \(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))",
                         comment: "Settings › iCloud footer: sync status. Placeholder is a relative time, e.g. '2 min ago'.")
        }
    }
}

/// 窓 The opt-in airing reminder: on/off and one to three daily times.
private struct AiringReminderSection: View {
    @Bindable var reminders: AiringReminders
    let notificationSettingsPath: String

    var body: some View {
        Section {
            Toggle(String(localized: "Airing reminder", comment: "Settings: toggle for a daily reminder to open a window and let fresh air in"), isOn: $reminders.isOn)
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
                            .accessibilityLabel(String(localized: "Remove \(time.date().formatted(date: .omitted, time: .shortened))",
                                                       comment: "Settings › Airing reminder: VoiceOver label for the button removing one reminder time. Placeholder is a time, e.g. 09:00."))
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
                    Text("Notifications are turned off for Kūki. To get reminders, allow Kūki in \(notificationSettingsPath), then turn the reminder on again.",
                         comment: "Settings › Airing reminder footer. Placeholder is the settings path, e.g. 'Settings › Notifications'.")
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
