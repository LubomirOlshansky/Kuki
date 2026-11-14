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

    var isRunning: Bool { !Activity<AirActivityAttributes>.activities.isEmpty }
    var isAllowed: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    enum StartError: LocalizedError {
        case noReading, notAllowed
        var errorDescription: String? {
            switch self {
            case .noReading: "There's no CO₂ reading yet. Wait for the first one, then try again."
            case .notAllowed: "Live Activities are off for Kūki. Turn them on in Settings › Kūki."
            }
        }
    }

    func start() throws {
        guard isAllowed else { throw StartError.notAllowed }
        guard let snapshot = WidgetSnapshot.load(), let state = AirActivityAttributes.ContentState(snapshot) else {
            throw StartError.noReading
        }
        end()
        _ = try Activity.request(
            attributes: AirActivityAttributes(startedAt: .now),
            content: .init(state: state, staleDate: snapshot.measuredAt.addingTimeInterval(WidgetSnapshot.staleAfter)),
            pushType: nil)
    }

    func update(with snapshot: WidgetSnapshot) {
        guard isRunning, let state = AirActivityAttributes.ContentState(snapshot) else { return }
        let content = ActivityContent(state: state,
                                      staleDate: snapshot.measuredAt.addingTimeInterval(WidgetSnapshot.staleAfter))
        for activity in Activity<AirActivityAttributes>.activities {
            Task { await activity.update(content) }
        }
    }

    func end() {
        for activity in Activity<AirActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
#endif
