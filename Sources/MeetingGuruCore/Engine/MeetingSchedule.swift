import Foundation

public enum TrayStatus: Equatable, Sendable {
    case dnd, alert, warning, ok, idle

    public func colorHex(for config: AppConfig) -> String {
        switch self {
        case .dnd: "#808080"
        case .alert: config.trayColorAlert
        case .warning: config.trayColorWarning
        case .ok: config.trayColorOk
        case .idle: config.trayColorDefault
        }
    }
}

/// Snapshot of the day as the tray and island see it: meetings in progress and those still ahead.
public struct MeetingSchedule: Sendable {
    public static let warningMinutes = 15

    public let current: [MeetingEvent]
    public let upcoming: [MeetingEvent]
    public let now: Date

    public init(events: [MeetingEvent], now: Date) {
        let timed = events.filter { !$0.allDay }
        current = timed.filter { $0.status(at: now) == .current }
        upcoming = timed.filter { $0.status(at: now) == .upcoming && $0.start > now }.sorted { $0.start < $1.start }
        self.now = now
    }

    /// The meeting a manual look should show: an ongoing one first, else the next one.
    public var featured: MeetingEvent? {
        current.max { $0.start < $1.start } ?? upcoming.first
    }

    public var nearest: MeetingEvent? { upcoming.first }

    public var next: MeetingEvent? { upcoming.dropFirst().first }

    public func trayStatus(dndActive: Bool) -> TrayStatus {
        if dndActive { return .dnd }
        if !current.isEmpty { return .alert }
        if let first = upcoming.first {
            return first.isWithin(minutes: Self.warningMinutes, at: now) ? .warning : .ok
        }
        return .idle
    }

    public func tooltip(syncError: String?, dnd: DNDState) -> String {
        var text: String
        if let meeting = current.first {
            text = "MeetingGuru - Current: \(meeting.title)"
        } else if let meeting = upcoming.first {
            text = "MeetingGuru - Next: \(meeting.title) (in \(Formatting.tooltipDuration(meeting.timeToStart(at: now))))"
        } else {
            text = "MeetingGuru - No upcoming meetings"
        }
        if let syncError {
            text += "\nSync error: \(syncError.prefix(120))"
        }
        if dnd.isActive(at: now) {
            if dnd.duration == .untilResume {
                if let elapsed = dnd.elapsed(at: now) {
                    text += "\nDND: Active for \(Formatting.shortDuration(elapsed))"
                } else {
                    text += "\nDND: Active (until resume)"
                }
            } else if let remaining = dnd.remaining(at: now) {
                text += "\nDND: \(Formatting.shortDuration(remaining)) remaining"
            } else {
                text += "\nDND: Active"
            }
        }
        return text
    }
}

public enum Formatting {
    /// "2h 5m", "2h", "12m" or "< 1m".
    public static func shortDuration(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        if total >= 3600 {
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if total >= 60 { return "\(total / 60)m" }
        return "< 1m"
    }

    public static func tooltipDuration(_ interval: TimeInterval) -> String {
        let days = Int((interval / 86400).rounded(.down))
        if days > 0 { return "\(days) days" }
        if interval > 3600 {
            return "\(Int(interval / 3600))h \(Int(interval.truncatingRemainder(dividingBy: 3600) / 60))m"
        }
        return "\(Int(interval / 60)) min"
    }

    /// Ticking countdown: "0:42", "14:05", then "2h 14m" past an hour.
    public static func countdown(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        if total >= 3600 { return shortDuration(Double(total)) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    public static func minutes(_ interval: TimeInterval) -> Int {
        Int((interval / 60).rounded(.down))
    }

    public static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    public static func timeRange(_ meeting: MeetingEvent, timeZone: TimeZone = .current) -> String {
        "\(clock(meeting.start, timeZone: timeZone)) – \(clock(meeting.end, timeZone: timeZone))"
    }

    /// "Today", "Tomorrow" or "Thu 25 Sep".
    public static func day(_ date: Date, now: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        var style = Date.FormatStyle(date: .omitted, time: .omitted).weekday(.abbreviated).day().month(.abbreviated)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// "Tomorrow · 14:00 – 15:00"; all-day events drop the times.
    public static func dayAndTime(_ meeting: MeetingEvent, now: Date, timeZone: TimeZone = .current) -> String {
        let label = day(meeting.start, now: now, timeZone: timeZone)
        return meeting.allDay ? "\(label) · all day" : "\(label) · \(timeRange(meeting, timeZone: timeZone))"
    }
}
