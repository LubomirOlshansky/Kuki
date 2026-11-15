import Foundation
import Observation
import UserNotifications

/// A time of day for the airing reminder, minute precision.
struct ReminderTime: Hashable, Comparable, Codable {
    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int = 0) {
        self.hour = min(23, max(0, hour))
        self.minute = min(59, max(0, minute))
    }

    static func < (a: ReminderTime, b: ReminderTime) -> Bool {
        (a.hour, a.minute) < (b.hour, b.minute)
    }

    /// "09:00" — the stored form.
    var raw: String { String(format: "%02d:%02d", hour, minute) }

    init?(raw: String) {
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        self.init(hour: h, minute: m)
    }

    /// Today at this time (for a DatePicker).
    func date(on day: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    init(date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: c.hour ?? 9, minute: c.minute ?? 0)
    }
}

/// 窓 The airing reminder: a plain, time-based local notification, a few
/// times a day. It can't know the air (a local notification can't read the
/// sensor), so it says "reminder" and nothing more. Pure, so it's tested.
enum AiringReminder {
    static let maxTimes = 3
    static let identifierPrefix = "airing-reminder-"
    /// Every identifier the reminder may use — all cancelled on each reschedule.
    static let allIdentifiers = (0..<maxTimes).map { "\(identifierPrefix)\($0)" }

    static let morning = ReminderTime(hour: 9)
    static let evening = ReminderTime(hour: 20)
    static let standardTimes = [morning, evening]

    /// The schedule offered for an airing habit, or nil when it isn't offered
    /// at all (a window that's usually open needs no reminder). Always off
    /// until the user turns it on.
    static func suggestedTimes(for habit: AiringHabit?) -> [ReminderTime]? {
        switch habit {
        // Twice a day: after getting up, and before bed.
        case .rarely, .onceADay, .severalTimes, nil: standardTimes
        case .windowUsuallyOpen: nil
        }
    }

    /// Whether the plan screen leads with the reminder ("Suggested for you")
    /// or only offers it.
    static func isSuggested(for habit: AiringHabit?) -> Bool {
        habit == .rarely || habit == .onceADay
    }

    /// Sorted, without duplicates, at most `maxTimes`; never empty.
    static func normalized(_ times: [ReminderTime]) -> [ReminderTime] {
        let clean = Array(Set(times)).sorted().prefix(maxTimes)
        return clean.isEmpty ? [morning] : Array(clean)
    }

    static func encode(_ times: [ReminderTime]) -> String {
        normalized(times).map(\.raw).joined(separator: ",")
    }

    static func decode(_ raw: String?) -> [ReminderTime] {
        normalized((raw ?? "").split(separator: ",").compactMap { ReminderTime(raw: String($0)) })
    }

    /// "Time to air the bedroom" — seeded names read as ordinary nouns,
    /// names the user typed stay exactly as typed.
    static func title(placeName: String?) -> String {
        guard let name = placeName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return String(localized: "Time to air the room", comment: "Airing reminder notification title when no room is known.")
        }
        // One sentence per seeded room, so each language can inflect it.
        switch Place.seededIndex(name) {
        case 0: return String(localized: "Time to air the living room", comment: "Airing reminder notification title for the default Living room.")
        case 1: return String(localized: "Time to air the bedroom", comment: "Airing reminder notification title for the default Bedroom.")
        case 2: return String(localized: "Time to air the study", comment: "Airing reminder notification title for the default Study (home office).")
        case 3: return String(localized: "Time to air the kitchen", comment: "Airing reminder notification title for the default Kitchen.")
        default:
            return String(localized: "Time to air \(name)", comment: "Airing reminder notification title. %@ = a room name the user typed, exactly as typed (e.g. \"Anna's room\", \"Office\").")
        }
    }

    static var body: String {
        String(localized: "Open a window wide for 5 minutes.", comment: "Airing reminder notification body.")
    }

    /// One repeating calendar request per time.
    static func requests(times: [ReminderTime], placeName: String?) -> [ReminderRequest] {
        normalized(times).enumerated().map { i, time in
            ReminderRequest(identifier: allIdentifiers[i], title: title(placeName: placeName), body: body, time: time)
        }
    }

    /// "09:00 and 20:00" — in the user's own clock format.
    static func describe(_ times: [ReminderTime]) -> String {
        let shown = normalized(times).map { $0.date().formatted(date: .omitted, time: .shortened) }
        return shown.formatted(.list(type: .and))
    }
}

/// What gets scheduled — plain values, so tests can compare them.
struct ReminderRequest: Equatable {
    let identifier: String
    let title: String
    let body: String
    let time: ReminderTime

    var trigger: UNCalendarNotificationTrigger {
        UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: time.hour, minute: time.minute), repeats: true)
    }
}

/// The notification centre, narrowed to what the reminder needs. Tests use a fake.
@MainActor
protocol ReminderCenter: AnyObject {
    func requestPermission() async -> Bool
    func remove(identifiers: [String])
    func add(_ request: ReminderRequest)
}

@MainActor
final class SystemReminderCenter: ReminderCenter {
    func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func remove(identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func add(_ request: ReminderRequest) {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.threadIdentifier = "airing-reminder"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: request.identifier, content: content, trigger: request.trigger))
    }
}

/// The reminder's settings and its schedule. Owned by the recorder, which
/// reschedules it whenever the sensor's place changes.
@MainActor
@Observable
final class AiringReminders {
    static let onKey = "airingReminderOn"
    static let timesKey = "airingReminderTimes"

    /// Turning it on asks for notification permission (only then); a refusal
    /// turns it back off.
    var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            defaults.set(isOn, forKey: Self.onKey)
            if isOn { askThenSchedule() } else { reschedule() }
            Analytics.track("airing_reminder_changed", ["on": isOn, "times_count": times.count])
        }
    }
    var times: [ReminderTime] {
        didSet {
            let clean = AiringReminder.normalized(times)
            if clean != times { times = clean } // doesn't re-enter didSet
            guard times != oldValue else { return }
            defaults.set(AiringReminder.encode(times), forKey: Self.timesKey)
            reschedule()
            if isOn { Analytics.track("airing_reminder_changed", ["on": true, "times_count": times.count]) }
        }
    }
    /// The user turned it on but the system said no.
    private(set) var denied = false

    /// The current place's name, for the notification's words.
    @ObservationIgnored var placeName: () -> String? = { nil }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeCenter: @MainActor () -> ReminderCenter
    @ObservationIgnored private lazy var center: ReminderCenter = makeCenter()

    init(defaults: UserDefaults, center: @escaping @MainActor () -> ReminderCenter = { SystemReminderCenter() }) {
        self.defaults = defaults
        self.makeCenter = center
        isOn = defaults.bool(forKey: Self.onKey)
        times = AiringReminder.decode(defaults.string(forKey: Self.timesKey) ?? AiringReminder.encode(AiringReminder.standardTimes))
    }

    /// Turn it on with these times (the plan screen's suggestion).
    func enable(times new: [ReminderTime]) {
        times = new
        isOn = true
    }

    func add(_ time: ReminderTime) {
        guard times.count < AiringReminder.maxTimes else { return }
        times = times + [time]
    }

    func remove(_ time: ReminderTime) {
        guard times.count > 1 else { return }
        times = times.filter { $0 != time }
    }

    /// Cancel everything this reminder ever scheduled, then schedule the
    /// current times if it's on. Safe to call any time.
    func reschedule() {
        // Off and never on: don't touch the notification centre at all.
        guard isOn || defaults.object(forKey: Self.onKey) != nil else { return }
        center.remove(identifiers: AiringReminder.allIdentifiers)
        guard isOn else { return }
        for request in AiringReminder.requests(times: times, placeName: placeName()) {
            center.add(request)
        }
    }

    /// Awaitable for tests: the permission answer has been applied.
    @ObservationIgnored private(set) var pendingAsk: Task<Void, Never>?

    private func askThenSchedule() {
        pendingAsk = Task {
            let granted = await center.requestPermission()
            denied = !granted
            if granted { reschedule() } else { isOn = false }
        }
    }
}
