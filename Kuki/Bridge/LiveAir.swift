#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation
import os

/// Starts, updates and ends the "Air" Live Activity on iPhone.
///
/// Updates come from two places: the app's own recording while it is open,
/// and iCloud wake-ups carrying the Mac's latest reading while it is not.
/// `staleDate` = measuredAt + 30 min, so the Lock Screen says "Last reading"
/// on its own when nothing new arrives.
@MainActor
final class LiveAir {
    static let shared = LiveAir()
    private let log = Logger(subsystem: "com.olshanskysoft.kuki", category: "live")
    /// Activities whose state is being watched (for `live_activity_ended`).
    private var watched: Set<String> = []
    /// Ended by the app itself: its end is reported where it happens.
    private var endedHere: Set<String> = []
    /// Already reported as ended (gone stale counts as ended).
    private var reported: Set<String> = []

    var isRunning: Bool { !Activity<AirActivityAttributes>.activities.isEmpty }
    var isAllowed: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    enum StartError: LocalizedError {
        case noReading, notAllowed
        var errorDescription: String? {
            switch self {
            case .noReading: String(localized: "There's no CO₂ reading yet. Wait for the first one, then try again.", comment: "Error when starting the Live Activity (Lock Screen reading) before any CO₂ reading exists.")
            case .notAllowed: String(localized: "Live Activities are off for Kūki. Turn them on in Settings › Kūki.", comment: "Error when Live Activities are disabled. 'Settings › Kūki' is the path in the iOS Settings app: use your language's name of the Settings app.")
            }
        }
    }

    func start() throws {
        guard isAllowed else { throw StartError.notAllowed }
        guard let snapshot = WidgetSnapshot.load(), let state = AirActivityAttributes.ContentState(snapshot) else {
            throw StartError.noReading
        }
        endAll(reported: true) // a fresh start replaces the old one: not an end
        let activity = try Activity.request(
            attributes: AirActivityAttributes(startedAt: .now),
            content: .init(state: state, staleDate: snapshot.measuredAt.addingTimeInterval(WidgetSnapshot.staleAfter)),
            pushType: nil)
        Analytics.track("live_activity_started")
        watch(activity)
        UsageAnalytics.shared.refreshProperties()
    }

    /// From the app's own recording, while it is in front.
    func update(with snapshot: WidgetSnapshot) {
        Task { await updateAndWait(with: snapshot) }
    }

    /// Returns once every activity has the new content — a background wake
    /// awaits this before telling iOS it's done, or the update may be lost.
    func updateAndWait(with snapshot: WidgetSnapshot) async {
        guard isRunning, let state = AirActivityAttributes.ContentState(snapshot) else { return }
        let content = ActivityContent(state: state,
                                      staleDate: snapshot.measuredAt.addingTimeInterval(WidgetSnapshot.staleAfter))
        for activity in Activity<AirActivityAttributes>.activities {
            await activity.update(content)
        }
    }

    /// "Remove from Lock Screen".
    func end() {
        let had = isRunning
        endAll(reported: true)
        if had { Analytics.track("live_activity_ended", ["via": "user"]) }
        UsageAnalytics.shared.refreshProperties()
    }

    private func endAll(reported alreadyReported: Bool) {
        for activity in Activity<AirActivityAttributes>.activities {
            if alreadyReported { endedHere.insert(activity.id) }
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Watch activities already running at launch (started in an earlier run).
    func observeExisting() {
        for activity in Activity<AirActivityAttributes>.activities { watch(activity) }
    }

    /// Report how an activity ends when the app didn't end it: it went
    /// stale (no reading for 30 minutes), or the system or the Lock Screen
    /// dismissed it ("system": ActivityKit can't tell those two apart).
    private func watch(_ activity: Activity<AirActivityAttributes>) {
        let id = activity.id
        guard watched.insert(id).inserted else { return }
        Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard let self else { return }
                let via: String? = switch state {
                case .stale: "stale"
                case .ended, .dismissed: "system"
                default: nil
                }
                guard let via else { continue }
                if !endedHere.contains(id), reported.insert(id).inserted {
                    Analytics.track("live_activity_ended", ["via": via])
                }
                UsageAnalytics.shared.refreshProperties()
                if state != .stale { break }
            }
        }
    }
}
#endif
